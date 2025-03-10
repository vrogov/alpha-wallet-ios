import UIKit
import BigInt
import PromiseKit
import RealmSwift
import Result
import Combine

// swiftlint:disable file_length
protocol InCoordinatorDelegate: AnyObject {
    func didCancel(in coordinator: InCoordinator)
    func didShowWallet(in coordinator: InCoordinator)
    func assetDefinitionsOverrideViewController(for coordinator: InCoordinator) -> UIViewController?
    func handleUniversalLink(_ url: URL, forCoordinator coordinator: InCoordinator)
    func showWallets(in coordinator: InCoordinator)
    func didRestart(in coordinator: InCoordinator, reason: RestartReason, wallet: Wallet)
}

// swiftlint:disable type_body_length
class InCoordinator: NSObject, Coordinator, DappRequestHandlerDelegate {
    private var wallet: Wallet
    private let config: Config
    private let assetDefinitionStore: AssetDefinitionStore
    private let appTracker: AppTracker
    private let analyticsCoordinator: AnalyticsCoordinator
    private let restartQueue: RestartTaskQueue
    private let queue: DispatchQueue = DispatchQueue(label: "com.Background.updateQueue", qos: .userInitiated)
    lazy private var eventsDataStore: NonActivityEventsDataStore = NonActivityMultiChainEventsDataStore(realm: realm)
    lazy private var eventsActivityDataStore: EventsActivityDataStoreProtocol = EventsActivityDataStore(realm: realm)
    private lazy var eventSourceCoordinatorForActivities: EventSourceCoordinatorForActivities? = {
        guard Features.isActivityEnabled else { return nil }
        return EventSourceCoordinatorForActivities(wallet: wallet, config: config, tokensDataStore: tokensDataStore, assetDefinitionStore: assetDefinitionStore, eventsDataStore: eventsActivityDataStore)
    }()
    private let coinTickersFetcher: CoinTickersFetcherType

    lazy var tokensDataStore: TokensDataStore = {
        return MultipleChainsTokensDataStore(realm: realm, servers: config.enabledServers)
    }()

    private lazy var eventSourceCoordinator: EventSourceCoordinatorType = {
        EventSourceCoordinator(wallet: wallet, tokensDataStore: tokensDataStore, assetDefinitionStore: assetDefinitionStore, eventsDataStore: eventsDataStore, config: config)
    }()

    private lazy var transactionDataStore: TransactionDataStore = {
        return TransactionDataStore(realm: realm, delegate: self)
    }()

    private var claimOrderCoordinatorCompletionBlock: ((Bool) -> Void)?
    private let blockscanChatService: BlockscanChatService

    private var transactionCoordinator: TransactionCoordinator? {
        return coordinators.compactMap { $0 as? TransactionCoordinator }.first
    }
    private var tokensCoordinator: TokensCoordinator? {
        return coordinators.compactMap { $0 as? TokensCoordinator }.first
    }
    var dappBrowserCoordinator: DappBrowserCoordinator? {
        coordinators.compactMap { $0 as? DappBrowserCoordinator }.first
    }
    private var activityCoordinator: ActivitiesCoordinator? {
        return coordinators.compactMap { $0 as? ActivitiesCoordinator }.first
    }
    private var settingsCoordinator: SettingsCoordinator? {
        return coordinators.compactMap { $0 as? SettingsCoordinator }.first
    }
    private lazy var helpUsCoordinator: HelpUsCoordinator = {
        HelpUsCoordinator(hostViewController: navigationController, appTracker: appTracker, analyticsCoordinator: analyticsCoordinator)
    }()

    private lazy var whatsNewExperimentCoordinator: WhatsNewExperimentCoordinator = {
        let coordinator = WhatsNewExperimentCoordinator(navigationController: navigationController, userDefaults: UserDefaults.standardOrForTests, analyticsCoordinator: analyticsCoordinator)
        coordinator.delegate = self
        return coordinator
    }()

    private lazy var activitiesService: ActivitiesServiceType = {
        return ActivitiesService(config: config, sessions: sessionsSubject.value, assetDefinitionStore: assetDefinitionStore, eventsActivityDataStore: eventsActivityDataStore, eventsDataStore: eventsDataStore, transactionDataStore: transactionDataStore, queue: queue, tokensDataStore: tokensDataStore)
    }()
    let navigationController: UINavigationController
    var coordinators: [Coordinator] = []
    var keystore: Keystore
    var universalLinkCoordinator: UniversalLinkCoordinatorType

    weak var delegate: InCoordinatorDelegate?

    private let walletAddressesStore: WalletAddressesStore
    private let walletBalanceService: WalletBalanceService
    private lazy var realm = Wallet.functional.realm(forAccount: wallet)
    private var tokenActionsService: TokenActionsServiceType
    private let walletConnectCoordinator: WalletConnectCoordinator
    private let promptBackupCoordinator: PromptBackupCoordinator

    lazy var tabBarController: UITabBarController = {
        let tabBarController: UITabBarController = .withOverridenBarAppearence()
        tabBarController.delegate = self

        return tabBarController
    }()
    private let accountsCoordinator: AccountsCoordinator
    private var cancellable = Set<AnyCancellable>()
    private let sessionsSubject: CurrentValueSubject<ServerDictionary<WalletSession>, Never>

    var presentationNavigationController: UINavigationController {
        if let nc = tabBarController.viewControllers?.first as? UINavigationController {
            if let nc = nc.presentedViewController as? UINavigationController {
                return nc
            } else {
                return nc
            }
        } else {
            return navigationController
        }
    }

    private lazy var dappRequestHandler: DappRequestHandler = {
        let handler = DappRequestHandler(walletConnectCoordinator: walletConnectCoordinator, dappBrowserCoordinator: dappBrowserCoordinator!)
        handler.delegate = self
        
        return handler
    }()

    private lazy var transactionNotificationService = TransactionNotificationSourceService(transactionDataStore: transactionDataStore, promptBackupCoordinator: promptBackupCoordinator, config: config)
    private let notificationService: NotificationService

    init(
            navigationController: UINavigationController = UINavigationController(),
            walletAddressesStore: WalletAddressesStore,
            wallet: Wallet,
            keystore: Keystore,
            assetDefinitionStore: AssetDefinitionStore,
            config: Config,
            appTracker: AppTracker = AppTracker(),
            analyticsCoordinator: AnalyticsCoordinator,
            restartQueue: RestartTaskQueue,
            universalLinkCoordinator: UniversalLinkCoordinatorType,
            promptBackupCoordinator: PromptBackupCoordinator,
            accountsCoordinator: AccountsCoordinator,
            walletBalanceService: WalletBalanceService,
            coinTickersFetcher: CoinTickersFetcherType,
            tokenActionsService: TokenActionsServiceType,
            walletConnectCoordinator: WalletConnectCoordinator,
            sessionsSubject: CurrentValueSubject<ServerDictionary<WalletSession>, Never> = .init(.init()),
            notificationService: NotificationService
    ) {
        self.sessionsSubject = sessionsSubject
        self.walletConnectCoordinator = walletConnectCoordinator
        self.navigationController = navigationController
        self.walletAddressesStore = walletAddressesStore
        self.wallet = wallet
        self.keystore = keystore
        self.config = config
        self.appTracker = appTracker
        self.analyticsCoordinator = analyticsCoordinator
        self.restartQueue = restartQueue
        self.assetDefinitionStore = assetDefinitionStore
        self.universalLinkCoordinator = universalLinkCoordinator
        self.promptBackupCoordinator = promptBackupCoordinator
        self.accountsCoordinator = accountsCoordinator
        self.walletBalanceService = walletBalanceService
        self.coinTickersFetcher = coinTickersFetcher
        self.tokenActionsService = tokenActionsService
        self.blockscanChatService = BlockscanChatService(walletAddressesStore: walletAddressesStore, account: wallet, analyticsCoordinator: analyticsCoordinator)
        self.notificationService = notificationService
        //Disabled for now. Refer to function's comment
        //self.assetDefinitionStore.enableFetchXMLForContractInPasteboard()
        super.init()
        blockscanChatService.delegate = self

        notificationService.register(source: transactionNotificationService)
    }

    deinit {
        //NOTE: Clear all smart contract calls
        clearSmartContractCallsCache()
        notificationService.unregister(source: transactionNotificationService)
    }

    func start(animated: Bool) {
        donateWalletShortcut()

        showTabBar(for: wallet, animated: animated)
        checkDevice()

        showHelpUs()
        fetchXMLAssetDefinitions()
        listOfBadTokenScriptFilesChanged(fileNames: assetDefinitionStore.listOfBadTokenScriptFiles + assetDefinitionStore.conflictingTokenScriptFileNames.all)
        setupWatchingTokenScriptFileChangesToFetchEvents()

        RestartQueueHandler(config: config).processRestartQueueAfterRestart(provider: self, restartQueue: restartQueue)

        showWhatsNew()
        notificationService.start(wallet: wallet)
    }

    private func showHelpUs() {
        helpUsCoordinator.start()
        addCoordinator(helpUsCoordinator)
    }

    private func showWhatsNew() {
        whatsNewExperimentCoordinator.start()
        addCoordinator(whatsNewExperimentCoordinator)
    }

    private func donateWalletShortcut() {
        WalletQrCodeDonation(address: wallet.address).donate()
    }

    func launchUniversalScanner() {
        tokensCoordinator?.launchUniversalScanner(fromSource: .quickAction)
    }

    private func setupWatchingTokenScriptFileChangesToFetchEvents() {
        //TODO this is firing twice for each contract. We can be more efficient
        assetDefinitionStore.subscribeToBodyChanges { [weak self] contract in
            guard let strongSelf = self else { return }
            strongSelf.tokensDataStore.tokenObjectPromise(forContract: contract).done { tokenObject in
                //Assume same contract don't exist in multiple chains
                guard let token = tokenObject else { return }
                let xmlHandler = XMLHandler(token: token, assetDefinitionStore: strongSelf.assetDefinitionStore)
                guard xmlHandler.hasAssetDefinition, let server = xmlHandler.server else { return }
                switch server {
                case .any:
                    for each in strongSelf.config.enabledServers {
                        strongSelf.fetchEvents(forTokenContract: contract, server: each)
                    }
                case .server(let server):
                    strongSelf.fetchEvents(forTokenContract: contract, server: server)
                }
            }.cauterize()
        }
    }

    private func fetchEvents(forTokenContract contract: AlphaWallet.Address, server: RPCServer) {
        guard let token = tokensDataStore.token(forContract: contract, server: server) else { return }
        eventsDataStore.deleteEvents(forTokenContract: contract)
        let _ = eventSourceCoordinator.fetchEventsByTokenId(forToken: token)
        let _ = eventSourceCoordinatorForActivities?.fetchEvents(forToken: token)
    }

    private func oneTimeCreationOfOneDatabaseToHoldAllChains() {
        let migration = MigrationInitializer(account: wallet)
        migration.oneTimeCreationOfOneDatabaseToHoldAllChains(assetDefinitionStore: assetDefinitionStore)
    }

    private func removeUnknownTransactions() {
        //TODO why do we remove such transactions? especially `.failed` and `.unknown`?
        transactionDataStore.removeTransactions(for: [.unknown], servers: config.enabledServers)
    }

    private func setupWalletSessions() {
        var walletSessions: ServerDictionary<WalletSession> = .init()
        for each in config.enabledServers {
            let tokenBalanceService = SingleChainTokenBalanceService(wallet: wallet, server: each, tokenBalanceProvider: walletBalanceService)
            let session = WalletSession(account: wallet, server: each, config: config, tokenBalanceService: tokenBalanceService)

            walletSessions[each] = session
        }

        sessionsSubject.send(walletSessions)
    }

    //Setup functions has to be called in the right order as they may rely on eg. wallet sessions being available. Wrong order should be immediately apparent with crash on startup. So don't worry
    private func setupResourcesOnMultiChain() {
        oneTimeCreationOfOneDatabaseToHoldAllChains()
        setupWalletSessions()
        removeUnknownTransactions()
    }

    //Internal for test purposes
    func showTabBar(for account: Wallet, animated: Bool) {
        keystore.recentlyUsedWallet = account

        if let service = tokenActionsService.service(ofType: Ramp.self) as? Ramp {
            service.configure(account: account)
        }

        wallet = account
        setupResourcesOnMultiChain()
        walletConnectCoordinator.delegate = self
        setupTabBarController()

        showTabBar(animated: animated)
    }

    func showTabBar(animated: Bool) {
        navigationController.setViewControllers([accountsCoordinator.accountsViewController], animated: false)
        navigationController.pushViewController(tabBarController, animated: animated)

        navigationController.setNavigationBarHidden(true, animated: false)

        let inCoordinatorViewModel = InCoordinatorViewModel()
        showTab(inCoordinatorViewModel.initialTab)

        logEnabledChains()
        logWallets()
        logDynamicTypeSetting()
        promptBackupCoordinator.start()

        universalLinkCoordinator.handlePendingUniversalLink(in: self)
    }

    private func createTokensCoordinator(promptBackupCoordinator: PromptBackupCoordinator, activitiesService: ActivitiesServiceType) -> TokensCoordinator {
        promptBackupCoordinator.listenToNativeCryptoCurrencyBalance(withWalletSessions: sessionsSubject.value)

        let coordinator = TokensCoordinator(
                sessions: sessionsSubject.value,
                keystore: keystore,
                config: config,
                tokensDataStore: tokensDataStore,
                assetDefinitionStore: assetDefinitionStore,
                eventsDataStore: eventsDataStore,
                promptBackupCoordinator: promptBackupCoordinator,
                analyticsCoordinator: analyticsCoordinator,
                tokenActionsService: tokenActionsService,
                walletConnectCoordinator: walletConnectCoordinator,
                coinTickersFetcher: coinTickersFetcher,
                activitiesService: activitiesService,
                walletBalanceService: walletBalanceService
        )
        coordinator.rootViewController.tabBarItem = UITabBarController.Tabs.tokens.tabBarItem
        coordinator.delegate = self
        coordinator.start()

        addCoordinator(coordinator)
        return coordinator
    }

    private func createTransactionCoordinator(transactionDataStore: TransactionDataStore) -> TransactionCoordinator {
        let transactionsService = TransactionsService(
            sessions: sessionsSubject.value,
            transactionDataStore: transactionDataStore,
            tokensDataStore: tokensDataStore
        )

        let coordinator = TransactionCoordinator(
                analyticsCoordinator: analyticsCoordinator,
                sessions: sessionsSubject.value,
                transactionsService: transactionsService
        )
        coordinator.rootViewController.tabBarItem = UITabBarController.Tabs.transactions.tabBarItem
        coordinator.navigationController.configureForLargeTitles()
        coordinator.delegate = self
        coordinator.start()
        addCoordinator(coordinator)
        return coordinator
    }

    private func createActivityCoordinator(activitiesService: ActivitiesServiceType) -> ActivitiesCoordinator {
        let coordinator = ActivitiesCoordinator(analyticsCoordinator: analyticsCoordinator, sessions: sessionsSubject.value, activitiesService: activitiesService, keystore: keystore, wallet: wallet)
        coordinator.delegate = self
        coordinator.start()
        coordinator.rootViewController.tabBarItem = UITabBarController.Tabs.activities.tabBarItem
        coordinator.navigationController.configureForLargeTitles()
        addCoordinator(coordinator)
        return coordinator
    }

    private func createBrowserCoordinator(sessions: ServerDictionary<WalletSession>, browserOnly: Bool, analyticsCoordinator: AnalyticsCoordinator) -> DappBrowserCoordinator {
        let coordinator = DappBrowserCoordinator(sessions: sessions, keystore: keystore, config: config, sharedRealm: realm, browserOnly: browserOnly, restartQueue: restartQueue, analyticsCoordinator: analyticsCoordinator)
        coordinator.delegate = self
        coordinator.start()
        coordinator.rootViewController.tabBarItem = UITabBarController.Tabs.browser.tabBarItem
        addCoordinator(coordinator)
        return coordinator
    }

    private func createSettingsCoordinator(keystore: Keystore, promptBackupCoordinator: PromptBackupCoordinator) -> SettingsCoordinator {
        let coordinator = SettingsCoordinator(
                keystore: keystore,
                config: config,
                sessions: sessionsSubject.value,
                restartQueue: restartQueue,
                promptBackupCoordinator: promptBackupCoordinator,
                analyticsCoordinator: analyticsCoordinator,
                walletConnectCoordinator: walletConnectCoordinator,
                walletBalanceService: walletBalanceService,
                blockscanChatService: blockscanChatService
        )
        coordinator.rootViewController.tabBarItem = UITabBarController.Tabs.settings.tabBarItem
        coordinator.navigationController.configureForLargeTitles()
        coordinator.delegate = self
        coordinator.start()
        addCoordinator(coordinator)
        return coordinator
    }

    //TODO do we need 2 separate MultipleChainsTokensDataStore instances? Is it because they have different delegates?
    private func setupTabBarController() {
        var viewControllers = [UIViewController]()

        let tokensCoordinator = createTokensCoordinator(promptBackupCoordinator: promptBackupCoordinator, activitiesService: activitiesService)

        viewControllers.append(tokensCoordinator.navigationController)

        let transactionCoordinator = createTransactionCoordinator(transactionDataStore: transactionDataStore)

        if Features.isActivityEnabled {
            let activityCoordinator = createActivityCoordinator(activitiesService: activitiesService)
            viewControllers.append(activityCoordinator.navigationController)
        } else {
            viewControllers.append(transactionCoordinator.navigationController)
        }

        let browserCoordinator = createBrowserCoordinator(sessions: sessionsSubject.value, browserOnly: false, analyticsCoordinator: analyticsCoordinator)
        viewControllers.append(browserCoordinator.navigationController)

        let settingsCoordinator = createSettingsCoordinator(keystore: keystore, promptBackupCoordinator: promptBackupCoordinator)
        viewControllers.append(settingsCoordinator.navigationController)

        tabBarController.viewControllers = viewControllers
    }

    func showTab(_ selectTab: UITabBarController.Tabs) {
        guard let viewControllers = tabBarController.viewControllers else {
            return
        }

        for controller in viewControllers {
            if let nav = controller as? UINavigationController, nav.viewControllers[0].className == selectTab.className {
                tabBarController.selectedViewController = nav
                loadHomePageIfEmpty()
            }
        }
    }

    private func checkDevice() {
        let deviceChecker = CheckDeviceCoordinator(navigationController: navigationController, jailbreakChecker: DeviceChecker())
        deviceChecker.start()
        addCoordinator(deviceChecker)
    }

    func showPaymentFlow(for type: PaymentFlow, server: RPCServer, navigationController: UINavigationController) {
        switch (type, sessionsSubject.value[server].account.type) {
        case (.send, .real), (.request, _):
            let coordinator = PaymentCoordinator(
                    navigationController: navigationController,
                    flow: type,
                    session: sessionsSubject.value[server],
                    keystore: keystore,
                    tokensDataStore: tokensDataStore,
                    assetDefinitionStore: assetDefinitionStore,
                    analyticsCoordinator: analyticsCoordinator,
                    eventsDataStore: eventsDataStore
            )
            coordinator.delegate = self
            coordinator.start()

            addCoordinator(coordinator)
        case (_, _):
            if let topVC = navigationController.presentedViewController {
                topVC.displayError(error: InCoordinatorError.onlyWatchAccount)
            } else {
                navigationController.displayError(error: InCoordinatorError.onlyWatchAccount)
            }
        }
    }

    private func handlePendingTransaction(transaction: SentTransaction) {
        transactionCoordinator?.addSentTransaction(transaction)
    }

    private func showTransactionSent(transaction: SentTransaction) {
        UIAlertController.showTransactionSent(transaction: transaction, on: presentationViewController)
    }

    private func fetchXMLAssetDefinitions() {
        let coordinator = FetchAssetDefinitionsCoordinator(assetDefinitionStore: assetDefinitionStore, tokensDataStore: tokensDataStore, config: config)
        coordinator.start()
        addCoordinator(coordinator)
    }

    func importPaidSignedOrder(signedOrder: SignedOrder, tokenObject: TokenObject, inViewController viewController: ImportMagicTokenViewController, completion: @escaping (Bool) -> Void) {
        guard let navigationController = viewController.navigationController else { return }
        let session = sessionsSubject.value[tokenObject.server]
        claimOrderCoordinatorCompletionBlock = completion
        let coordinator = ClaimPaidOrderCoordinator(navigationController: navigationController, keystore: keystore, session: session, tokenObject: tokenObject, signedOrder: signedOrder, analyticsCoordinator: analyticsCoordinator)
        coordinator.delegate = self
        addCoordinator(coordinator)
        coordinator.start()
    }

    func addImported(contract: AlphaWallet.Address, forServer server: RPCServer) {
        //Useful to check because we are/might action-only TokenScripts for native crypto currency
        guard !contract.sameContract(as: Constants.nativeCryptoAddressInDatabase) else { return }
        let tokensCoordinator = coordinators.first { $0 is TokensCoordinator } as? TokensCoordinator
        tokensCoordinator?.addImportedToken(forContract: contract, server: server)
    }

    private func isViewControllerDappBrowserTab(_ viewController: UIViewController) -> Bool {
        guard let dappBrowserCoordinator = dappBrowserCoordinator else { return false }
        return dappBrowserCoordinator.rootViewController.navigationController == viewController
    }

    func show(error: Error) {
        //TODO Not comprehensive. Example, if we are showing a token instance view and tap on unverified to open browser, this wouldn't owrk
        if let topVC = navigationController.presentedViewController {
            topVC.displayError(error: error)
        } else {
            navigationController.displayError(error: error)
        }
    }

    func show(openedURL filename: String) {
        let controller = UIAlertController(title: nil, message: R.string.localizable.tokenscriptImportOk(filename), preferredStyle: .alert)
        controller.popoverPresentationController?.sourceView = presentationViewController.view
        controller.addAction(.init(title: R.string.localizable.oK(), style: .default))

        presentationViewController.present(controller, animated: true)
    }

    private var presentationViewController: UIViewController {
        if let controller = navigationController.presentedViewController {
            return controller
        } else {
            return navigationController
        }
    }

    func listOfBadTokenScriptFilesChanged(fileNames: [TokenScriptFileIndices.FileName]) {
        tokensCoordinator?.listOfBadTokenScriptFilesChanged(fileNames: fileNames)
    }

    func openWalletConnectSession(url: AlphaWallet.WalletConnect.ConnectionUrl) {
        walletConnectCoordinator.openSession(url: url)
    }

    func processRestartQueueAndRestartUI() {
        RestartQueueHandler(config: config).processRestartQueueBeforeRestart(restartQueue: restartQueue)
        restartUI(withReason: .serverChange, account: wallet)
    }

    private func restartUI(withReason reason: RestartReason, account: Wallet) {
        delegate?.didRestart(in: self, reason: reason, wallet: account)
    }

    func showWalletQrCode() {
        showTab(.tokens)
        if let nc = tabBarController.viewControllers?.first as? UINavigationController, nc.visibleViewController is RequestViewController {
            //no-op
        } else if navigationController.visibleViewController is RequestViewController {
            //no-op
        } else {
            showPaymentFlow(for: .request, server: config.anyEnabledServer(), navigationController: navigationController)
        }
    }

    private func openFiatOnRamp(wallet: Wallet, server: RPCServer, inViewController viewController: UIViewController, source: Analytics.FiatOnRampSource) {
        let coordinator = FiatOnRampCoordinator(wallet: wallet, server: server, viewController: viewController, source: source, analyticsCoordinator: analyticsCoordinator)
        coordinator.delegate = self
        coordinator.start()
    }
}

extension InCoordinator {
    func requestSwitchChain(server: RPCServer, currentUrl: URL?, callbackID: SwitchCustomChainCallbackId, targetChain: WalletSwitchEthereumChainObject) {
        let coordinator = DappRequestSwitchExistingChainCoordinator(config: config, server: server, callbackId: callbackID, targetChain: targetChain, restartQueue: restartQueue, analyticsCoordinator: analyticsCoordinator, currentUrl: currentUrl, inViewController: presentationViewController)
        coordinator.delegate = dappRequestHandler
        dappRequestHandler.addCoordinator(coordinator)
        coordinator.start()
    }

    func requestAddCustomChain(server: RPCServer, callbackId: SwitchCustomChainCallbackId, customChain: WalletAddEthereumChainObject) {
        let coordinator = DappRequestSwitchCustomChainCoordinator(config: config, server: server, callbackId: callbackId, customChain: customChain, restartQueue: restartQueue, analyticsCoordinator: analyticsCoordinator, currentUrl: nil, inViewController: presentationViewController)
        coordinator.delegate = dappRequestHandler
        dappRequestHandler.addCoordinator(coordinator)
        coordinator.start()
    }
}

// swiftlint:enable type_body_length
extension InCoordinator: WalletConnectCoordinatorDelegate {

    func didSendTransaction(_ transaction: SentTransaction, inCoordinator coordinator: TransactionConfirmationCoordinator) {
        handlePendingTransaction(transaction: transaction)
    }

    func universalScannerSelected(in coordinator: WalletConnectCoordinator) {
        tokensCoordinator?.launchUniversalScanner(fromSource: .walletScreen)
    }

    func openFiatOnRamp(wallet: Wallet, server: RPCServer, inCoordinator coordinator: TransactionConfirmationCoordinator, viewController: UIViewController) {
        openFiatOnRamp(wallet: wallet, server: server, inViewController: viewController, source: .transactionActionSheetInsufficientFunds)
    }
}

extension InCoordinator: CanOpenURL {
    private func open(url: URL, in viewController: UIViewController) {
        //TODO duplication of code to set up a BrowserCoordinator when creating the application's tabbar
        let browserCoordinator = createBrowserCoordinator(sessions: sessionsSubject.value, browserOnly: true, analyticsCoordinator: analyticsCoordinator)
        let controller = browserCoordinator.navigationController
        browserCoordinator.open(url: url, animated: false)
        controller.makePresentationFullScreenForiOS13Migration()
        viewController.present(controller, animated: true)
    }

    func didPressViewContractWebPage(forContract contract: AlphaWallet.Address, server: RPCServer, in viewController: UIViewController) {
        if contract.sameContract(as: Constants.nativeCryptoAddressInDatabase) {
            guard let url = server.etherscanContractDetailsWebPageURL(for: wallet.address) else { return }
            logExplorerUse(type: .wallet)
            open(url: url, in: viewController)
        } else {
            guard let url = server.etherscanTokenDetailsWebPageURL(for: contract) else { return }
            logExplorerUse(type: .token)
            open(url: url, in: viewController)
        }
    }

    func didPressOpenWebPage(_ url: URL, in viewController: UIViewController) {
        open(url: url, in: viewController)
    }

    func didPressViewContractWebPage(_ url: URL, in viewController: UIViewController) {
        open(url: url, in: viewController)
    }
}

extension InCoordinator: TransactionCoordinatorDelegate {
}

extension InCoordinator: ConsoleCoordinatorDelegate {
    func didCancel(in coordinator: ConsoleCoordinator) {
        removeCoordinator(coordinator)
    }
}

extension InCoordinator: SettingsCoordinatorDelegate {

    private func showConsole(navigationController: UINavigationController) {
        let coordinator = ConsoleCoordinator(assetDefinitionStore: assetDefinitionStore, navigationController: navigationController)
        coordinator.delegate = self
        addCoordinator(coordinator)
        coordinator.start()
    }

    func showConsole(in coordinator: SettingsCoordinator) {
        showConsole(navigationController: coordinator.navigationController)
    }

    func didCancel(in coordinator: SettingsCoordinator) {
        removeCoordinator(coordinator)

        coordinator.navigationController.dismiss(animated: true)
        delegate?.didCancel(in: self)
    }

    func didRestart(with account: Wallet, in coordinator: SettingsCoordinator, reason: RestartReason) {
        restartUI(withReason: reason, account: account)
    }

    func didPressShowWallet(in coordinator: SettingsCoordinator) {
        //We are only showing the QR code and some text for this address. Maybe have to rework graphic design so that server isn't necessary
        showPaymentFlow(for: .request, server: config.anyEnabledServer(), navigationController: coordinator.navigationController)
        delegate?.didShowWallet(in: self)
    }

    func assetDefinitionsOverrideViewController(for: SettingsCoordinator) -> UIViewController? {
        return delegate?.assetDefinitionsOverrideViewController(for: self)
    }

    func restartToReloadServersQueued(in coordinator: SettingsCoordinator) {
        processRestartQueueAndRestartUI()
    }
}

extension InCoordinator: UrlSchemeResolver {
    var sessions: ServerDictionary<WalletSession> {
        sessionsSubject.value
    }

    func openURLInBrowser(url: URL) {
        openURLInBrowser(url: url, forceReload: false)
    }

    func openURLInBrowser(url: URL, forceReload: Bool) {
        guard let dappBrowserCoordinator = dappBrowserCoordinator else { return }
        showTab(.browser)
        dappBrowserCoordinator.open(url: url, animated: true, forceReload: forceReload)
    }
}

extension InCoordinator: ActivityViewControllerDelegate {
    func reinject(viewController: ActivityViewController) {
        activitiesService.reinject(activity: viewController.viewModel.activity)
    }

    func goToToken(viewController: ActivityViewController) {
        let token = viewController.viewModel.activity.tokenObject
        guard let tokenObject = tokensDataStore.token(forContract: token.contractAddress, server: token.server) else { return }
        guard let tokensCoordinator = tokensCoordinator, let navigationController = viewController.navigationController else { return }

        tokensCoordinator.showSingleChainToken(token: tokenObject, in: navigationController)
    }

    func speedupTransaction(transactionId: String, server: RPCServer, viewController: ActivityViewController) {
        guard let transaction = transactionDataStore.transaction(withTransactionId: transactionId, forServer: server) else { return }
        let session = sessionsSubject.value[transaction.server]
        guard let coordinator = ReplaceTransactionCoordinator(analyticsCoordinator: analyticsCoordinator, keystore: keystore, presentingViewController: viewController, session: session, transaction: transaction, mode: .speedup) else { return }
        coordinator.delegate = self
        coordinator.start()
        addCoordinator(coordinator)
    }

    func cancelTransaction(transactionId: String, server: RPCServer, viewController: ActivityViewController) {
        guard let transaction = transactionDataStore.transaction(withTransactionId: transactionId, forServer: server) else { return }
        let session = sessionsSubject.value[transaction.server]
        guard let coordinator = ReplaceTransactionCoordinator(analyticsCoordinator: analyticsCoordinator, keystore: keystore, presentingViewController: viewController, session: session, transaction: transaction, mode: .cancel) else { return }
        coordinator.delegate = self
        coordinator.start()
        addCoordinator(coordinator)
    }

    func goToTransaction(viewController: ActivityViewController) {
        transactionCoordinator?.showTransaction(withId: viewController.viewModel.activity.transactionId, server: viewController.viewModel.activity.server, inViewController: viewController)
    }

    func didPressViewContractWebPage(_ contract: AlphaWallet.Address, server: RPCServer, viewController: ActivityViewController) {
        didPressViewContractWebPage(forContract: contract, server: server, in: viewController)
    }
}

extension InCoordinator: UITabBarControllerDelegate {
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if isViewControllerDappBrowserTab(viewController) && viewController == tabBarController.selectedViewController {
            loadHomePageIfNeeded()
            return false
        }
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        if isViewControllerDappBrowserTab(viewController) {
            loadHomePageIfEmpty()
        }
    }

    private func loadHomePageIfNeeded() {
        // NOTE: open home web page if tap on browser tab bar icon, should we only when browser opened
        guard let coordinator = dappBrowserCoordinator else { return }

        if let url = config.homePageURL {
            coordinator.open(url: url, animated: false)
        } else {
            coordinator.showDappsHome()
        }
    }

    private func loadHomePageIfEmpty() {
        guard let coordinator = dappBrowserCoordinator, !coordinator.hasWebPageLoaded else { return }

        if let url = config.homePageURL {
            coordinator.open(url: url, animated: false)
        } else {
            coordinator.showDappsHome()
        }
    }
}

extension InCoordinator: WhereAreMyTokensCoordinatorDelegate {

    func switchToMainnetSelected(in coordinator: WhereAreMyTokensCoordinator) {
        restartQueue.add(.reloadServers(Constants.defaultEnabledServers))
        processRestartQueueAndRestartUI()
    }

    func didDismiss(in coordinator: WhereAreMyTokensCoordinator) {
        //no-op
    }
}

extension InCoordinator: TokensCoordinatorDelegate {

    func viewWillAppearOnce(in coordinator: TokensCoordinator) {
        eventSourceCoordinator.start()
        eventSourceCoordinatorForActivities?.start()
        walletBalanceService.refreshBalance(for: wallet).done { _ in
            //no-op
        }.cauterize()
    }

    func whereAreMyTokensSelected(in coordinator: TokensCoordinator) {
        let coordinator = WhereAreMyTokensCoordinator(navigationController: navigationController)
        coordinator.delegate = self
        addCoordinator(coordinator)

        coordinator.start()
    }

    func blockieSelected(in coordinator: TokensCoordinator) {
        delegate?.showWallets(in: self)
    }

    private func showActivity(_ activity: Activity, navigationController: UINavigationController) {
        let controller = ActivityViewController(analyticsCoordinator: analyticsCoordinator, wallet: wallet, assetDefinitionStore: assetDefinitionStore, viewModel: .init(activity: activity), service: activitiesService, keystore: keystore)
        controller.delegate = self

        controller.hidesBottomBarWhenPushed = true
        controller.navigationItem.largeTitleDisplayMode = .never

        navigationController.pushViewController(controller, animated: true)
    }

    func didTap(activity: Activity, inViewController viewController: UIViewController, in coordinator: TokensCoordinator) {
        guard let navigationController = viewController.navigationController else { return }

        showActivity(activity, navigationController: navigationController)
    }

    func didTapSwap(forTransactionType transactionType: TransactionType, service: SwapTokenURLProviderType, in coordinator: TokensCoordinator) {
        logTappedSwap(service: service)
        guard let token = transactionType.swapServiceInputToken, let url = service.url(token: token) else { return }

        if let server = service.rpcServer(forToken: token) {
            open(url: url, onServer: server)
        } else {
            open(for: url)
        }
    }

    func shouldOpen(url: URL, shouldSwitchServer: Bool, forTransactionType transactionType: TransactionType, in coordinator: TokensCoordinator) {
        switch transactionType {
        case .nativeCryptocurrency(let token, _, _), .erc20Token(let token, _, _), .erc875Token(let token, _), .erc721Token(let token, _), .erc1155Token(let token, _, _):
            if shouldSwitchServer {
                open(url: url, onServer: token.server)
            } else {
                open(for: url)
            }
        case .erc875TokenOrder, .erc721ForTicketToken, .dapp, .tokenScript, .claimPaidErc875MagicLink, .prebuilt:
            break
        }
    }

    private func open(for url: URL) {
        guard let dappBrowserCoordinator = dappBrowserCoordinator else { return }
        showTab(.browser)
        dappBrowserCoordinator.open(url: url, animated: true, forceReload: true)
    }

    private func open(url: URL, onServer server: RPCServer) {
        //Server shouldn't be disabled since the action is selected
        guard let dappBrowserCoordinator = dappBrowserCoordinator, config.enabledServers.contains(server) else { return }
        showTab(.browser)
        dappBrowserCoordinator.switch(toServer: server, url: url)
    }

    func didPress(for type: PaymentFlow, server: RPCServer, inViewController viewController: UIViewController?, in coordinator: TokensCoordinator) {
        let navigationController: UINavigationController
        if let nvc = viewController?.navigationController {
            navigationController = nvc
        } else {
            navigationController = coordinator.navigationController
        }

        showPaymentFlow(for: type, server: server, navigationController: navigationController)
    }

    func didTap(transaction: TransactionInstance, inViewController viewController: UIViewController, in coordinator: TokensCoordinator) {
        if transaction.localizedOperations.count > 1 {
            transactionCoordinator?.showTransaction(.group(transaction), inViewController: viewController)
        } else {
            transactionCoordinator?.showTransaction(.standalone(transaction), inViewController: viewController)
        }
    }

    func openConsole(inCoordinator coordinator: TokensCoordinator) {
        showConsole(navigationController: coordinator.navigationController)
    }

    func didPostTokenScriptTransaction(_ transaction: SentTransaction, in coordinator: TokensCoordinator) {
        handlePendingTransaction(transaction: transaction)
    }

    func openFiatOnRamp(wallet: Wallet, server: RPCServer, inCoordinator coordinator: TokensCoordinator, viewController: UIViewController, source: Analytics.FiatOnRampSource) {
        openFiatOnRamp(wallet: wallet, server: server, inViewController: viewController, source: source)
    }

    func didSelectAccount(account: Wallet, in coordinator: TokensCoordinator) {
        guard keystore.currentWallet != account else { return }
        restartUI(withReason: .walletChange, account: account)
    }
}

extension InCoordinator: PaymentCoordinatorDelegate {
    func didSelectTokenHolder(tokenHolder: TokenHolder, in coordinator: PaymentCoordinator) {
        guard let coordinator = coordinatorOfType(type: TokensCardCollectionCoordinator.self) else { return }

        coordinator.showTokenInstance(tokenHolder: tokenHolder, mode: .preview)
    }

    func didSendTransaction(_ transaction: SentTransaction, inCoordinator coordinator: PaymentCoordinator) {
        handlePendingTransaction(transaction: transaction)
    }

    func didFinish(_ result: ConfirmResult, in coordinator: PaymentCoordinator) {
        removeCoordinator(coordinator)
        askUserToRateAppOrSubscribeToNewsletter()
    }

    //NOTE: askUserToRateAppOrSubscribeToNewsletter can't be called ringht in confirmation coordinator as after successfully sent transaction coordinator dismissed
    private func askUserToRateAppOrSubscribeToNewsletter() {
        guard let keyWindow = UIApplication.shared.firstKeyWindow else { return }

        let hostViewController: UIViewController
        if let controller = keyWindow.rootViewController?.presentedViewController {
            hostViewController = controller
        } else {
            hostViewController = navigationController
        }

        let coordinator = HelpUsCoordinator(hostViewController: hostViewController, appTracker: AppTracker(), analyticsCoordinator: analyticsCoordinator)
        coordinator.rateUsOrSubscribeToNewsletter()
    }

    func didCancel(in coordinator: PaymentCoordinator) {
        coordinator.dismiss(animated: true)

        removeCoordinator(coordinator)
    }

    func openFiatOnRamp(wallet: Wallet, server: RPCServer, inCoordinator coordinator: PaymentCoordinator, viewController: UIViewController, source: Analytics.FiatOnRampSource) {
        openFiatOnRamp(wallet: wallet, server: server, inViewController: viewController, source: source)
    }
}

extension InCoordinator: FiatOnRampCoordinatorDelegate {
}

extension InCoordinator: DappBrowserCoordinatorDelegate {
    func didSentTransaction(transaction: SentTransaction, inCoordinator coordinator: DappBrowserCoordinator) {
        handlePendingTransaction(transaction: transaction)
    }

    func handleUniversalLink(_ url: URL, forCoordinator coordinator: DappBrowserCoordinator) {
        delegate?.handleUniversalLink(url, forCoordinator: self)
    }

    func restartToAddEnableAndSwitchBrowserToServer(inCoordinator coordinator: DappBrowserCoordinator) {
        processRestartQueueAndRestartUI()
    }

    func restartToEnableAndSwitchBrowserToServer(inCoordinator coordinator: DappBrowserCoordinator) {
        processRestartQueueAndRestartUI()
    }

    func openFiatOnRamp(wallet: Wallet, server: RPCServer, inCoordinator coordinator: DappBrowserCoordinator, viewController: UIViewController, source: Analytics.FiatOnRampSource) {
        openFiatOnRamp(wallet: wallet, server: server, inViewController: viewController, source: source)
    }
}

extension InCoordinator: StaticHTMLViewControllerDelegate {
}

extension InCoordinator: TransactionDataStoreDelegate {
    func didAddTokensWith(contracts: [AlphaWallet.Address], in transactionsStorage: TransactionDataStore) {
        for each in contracts {
            assetDefinitionStore.fetchXML(forContract: each)
        }
    }
}

extension InCoordinator: ActivitiesCoordinatorDelegate {

    func didPressActivity(activity: Activity, in viewController: ActivitiesViewController) {
        guard let navigationController = viewController.navigationController else { return }

        showActivity(activity, navigationController: navigationController)
    }

    func didPressTransaction(transaction: TransactionInstance, in viewController: ActivitiesViewController) {
        if transaction.localizedOperations.count > 1 {
            transactionCoordinator?.showTransaction(.group(transaction), inViewController: viewController)
        } else {
            transactionCoordinator?.showTransaction(.standalone(transaction), inViewController: viewController)
        }
    }
}

extension InCoordinator: ClaimOrderCoordinatorDelegate {
    func coordinator(_ coordinator: ClaimPaidOrderCoordinator, didFailTransaction error: AnyError) {
        claimOrderCoordinatorCompletionBlock?(false)
    }

    func didClose(in coordinator: ClaimPaidOrderCoordinator) {
        claimOrderCoordinatorCompletionBlock = nil
        removeCoordinator(coordinator)
    }

    func coordinator(_ coordinator: ClaimPaidOrderCoordinator, didCompleteTransaction result: ConfirmResult) {
        claimOrderCoordinatorCompletionBlock?(true)
        claimOrderCoordinatorCompletionBlock = nil
        removeCoordinator(coordinator)
    }

    func openFiatOnRamp(wallet: Wallet, server: RPCServer, inCoordinator coordinator: ClaimPaidOrderCoordinator, viewController: UIViewController, source: Analytics.FiatOnRampSource) {
        openFiatOnRamp(wallet: wallet, server: server, inViewController: viewController, source: source)
    }
}

// MARK: Analytics
extension InCoordinator {
    private func logEnabledChains() {
        let list = config.enabledServers.map(\.chainID).sorted()
        analyticsCoordinator.setUser(property: Analytics.UserProperties.enabledChains, value: list)
    }

    private func logWallets() {
        let totalCount = keystore.wallets.count
        let hdWalletsCount = keystore.wallets.filter { keystore.isHdWallet(wallet: $0) }.count
        let keystoreWalletsCount = keystore.wallets.filter { keystore.isKeystore(wallet: $0) }.count
        let watchedWalletsCount = keystore.wallets.filter { keystore.isWatched(wallet: $0) }.count
        analyticsCoordinator.setUser(property: Analytics.UserProperties.walletsCount, value: totalCount)
        analyticsCoordinator.setUser(property: Analytics.UserProperties.hdWalletsCount, value: hdWalletsCount)
        analyticsCoordinator.setUser(property: Analytics.UserProperties.keystoreWalletsCount, value: keystoreWalletsCount)
        analyticsCoordinator.setUser(property: Analytics.UserProperties.watchedWalletsCount, value: watchedWalletsCount)
    }

    private func logDynamicTypeSetting() {
        let setting = UIApplication.shared.preferredContentSizeCategory.rawValue
        analyticsCoordinator.setUser(property: Analytics.UserProperties.dynamicTypeSetting, value: setting)
    }

    private func logTappedSwap(service: SwapTokenURLProviderType) {
        analyticsCoordinator.log(navigation: Analytics.Navigation.tokenSwap, properties: [Analytics.Properties.name.rawValue: service.analyticsName])
    }

    private func logExplorerUse(type: Analytics.ExplorerType) {
        analyticsCoordinator.log(navigation: Analytics.Navigation.explorer, properties: [Analytics.Properties.type.rawValue: type.rawValue])
    }
}

extension InCoordinator: ReplaceTransactionCoordinatorDelegate {
    func didSendTransaction(_ transaction: SentTransaction, inCoordinator coordinator: ReplaceTransactionCoordinator) {
        handlePendingTransaction(transaction: transaction)
    }

    func didFinish(_ result: ConfirmResult, in coordinator: ReplaceTransactionCoordinator) {
        removeCoordinator(coordinator)
        askUserToRateAppOrSubscribeToNewsletter()
    }

    func openFiatOnRamp(wallet: Wallet, server: RPCServer, inCoordinator coordinator: ReplaceTransactionCoordinator, viewController: UIViewController, source: Analytics.FiatOnRampSource) {
        openFiatOnRamp(wallet: wallet, server: server, inViewController: viewController, source: source)
    }
}

extension InCoordinator: WhatsNewExperimentCoordinatorDelegate {
    func didEnd(in coordinator: WhatsNewExperimentCoordinator) {
        removeCoordinator(coordinator)
    }
}

extension InCoordinator: LoadUrlInDappBrowserProvider {
    func didLoadUrlInDappBrowser(url: URL, in handler: RestartQueueHandler) {
        showTab(.browser)
        dappBrowserCoordinator?.open(url: url, animated: false)
    }
}

extension InCoordinator: BlockscanChatServiceDelegate {
    func openBlockscanChat(url: URL, for: BlockscanChatService) {
        analyticsCoordinator.log(navigation: Analytics.Navigation.blockscanChat)
        open(for: url)
    }

    func showBlockscanUnreadCount(_ count: Int?, for: BlockscanChatService) {
        settingsCoordinator?.showBlockscanChatUnreadCount(count)
    }
}

// swiftlint:enable file_length
