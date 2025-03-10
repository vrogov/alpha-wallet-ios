//
//  TransactionConfirmationCoordinator.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 14.08.2020.
//

import UIKit
import BigInt
import PromiseKit
import Result

enum TransactionConfirmationConfiguration {
    case tokenScriptTransaction(confirmType: ConfirmType, contract: AlphaWallet.Address, keystore: Keystore, functionCallMetaData: DecodedFunctionCall)
    case dappTransaction(confirmType: ConfirmType, keystore: Keystore)
    case walletConnect(confirmType: ConfirmType, keystore: Keystore, dappRequesterViewModel: WalletConnectDappRequesterViewModel)
    case sendFungiblesTransaction(confirmType: ConfirmType, keystore: Keystore, assetDefinitionStore: AssetDefinitionStore, amount: FungiblesTransactionAmount)
    case sendNftTransaction(confirmType: ConfirmType, keystore: Keystore, tokenInstanceNames: [TokenId: String])
    case claimPaidErc875MagicLink(confirmType: ConfirmType, keystore: Keystore, price: BigUInt, numberOfTokens: UInt)
    case speedupTransaction(keystore: Keystore)
    case cancelTransaction(keystore: Keystore)

    var confirmType: ConfirmType {
        switch self {
        case .dappTransaction(let confirmType, _), .walletConnect(let confirmType, _, _ ), .sendFungiblesTransaction(let confirmType, _, _, _), .sendNftTransaction(let confirmType, _, _), .tokenScriptTransaction(let confirmType, _, _, _), .claimPaidErc875MagicLink(let confirmType, _, _, _):
            return confirmType
        case .speedupTransaction, .cancelTransaction:
            return .signThenSend
        }
    }

    var keystore: Keystore {
        switch self {
        case .dappTransaction(_, let keystore), .walletConnect(_, let keystore, _), .sendFungiblesTransaction(_, let keystore, _, _), .sendNftTransaction(_, let keystore, _), .tokenScriptTransaction(_, _, let keystore, _), .claimPaidErc875MagicLink(_, let keystore, _, _), .speedupTransaction(let keystore), .cancelTransaction(let keystore):
            return keystore
        }
    }
}

enum ConfirmType {
    case sign
    case signThenSend
}

enum ConfirmResult {
    case signedTransaction(Data)
    case sentTransaction(SentTransaction)
    case sentRawTransaction(id: String, original: String)
}

protocol TransactionConfirmationCoordinatorDelegate: CanOpenURL, SendTransactionDelegate, FiatOnRampDelegate {
    func didFinish(_ result: ConfirmResult, in coordinator: TransactionConfirmationCoordinator)
    func coordinator(_ coordinator: TransactionConfirmationCoordinator, didFailTransaction error: AnyError)
    func didClose(in coordinator: TransactionConfirmationCoordinator)
}

extension UIApplication {
    func presentedViewController(_ defaultViewControler: UIViewController) -> UIViewController {
        guard let keyWindow = UIApplication.shared.firstKeyWindow else { return defaultViewControler }

        if let controller = keyWindow.rootViewController?.presentedViewController {
            return controller
        } else {
            return defaultViewControler
        }
    }
}

class TransactionConfirmationCoordinator: Coordinator {
    private let configuration: TransactionConfirmationConfiguration
    private lazy var viewModel: TransactionConfirmationViewModel = .init(configurator: configurator, configuration: configuration)
    private lazy var rootViewController: TransactionConfirmationViewController = {
        let controller = TransactionConfirmationViewController(viewModel: viewModel, session: configurator.session)
        controller.delegate = self
        return controller
    }()
    private lazy var hostViewController: FloatingPanelController = {
        let panel = FloatingPanelController(isPanEnabled: false)
        panel.layout = SelfSizingPanelLayout(referenceGuide: .superview)
        panel.set(contentViewController: rootViewController)

        return panel
    }()
    private weak var configureTransactionViewController: ConfigureTransactionViewController?
    private let configurator: TransactionConfigurator
    private let analyticsCoordinator: AnalyticsCoordinator
    private var canBeDismissed = true
    private var server: RPCServer { configurator.session.server }
    private let navigationController: UIViewController

    var coordinators: [Coordinator] = []
    weak var delegate: TransactionConfirmationCoordinatorDelegate?

    init(presentingViewController: UIViewController, session: WalletSession, transaction: UnconfirmedTransaction, configuration: TransactionConfirmationConfiguration, analyticsCoordinator: AnalyticsCoordinator) {
        configurator = TransactionConfigurator(session: session, transaction: transaction)
        self.configuration = configuration
        self.analyticsCoordinator = analyticsCoordinator
        self.navigationController = presentingViewController
    }

    func start(fromSource source: Analytics.TransactionConfirmationSource) {
        guard let keyWindow = UIApplication.shared.firstKeyWindow else { return }

        if let controller = keyWindow.rootViewController?.presentedViewController {
            controller.present(hostViewController, animated: true)
        } else {
            navigationController.present(hostViewController, animated: true)
        }

        configurator.delegate = self
        configurator.start()
        rootViewController.reloadView()

        logStartActionSheetForTransactionConfirmation(source: source)
    }

    func close(completion: @escaping () -> Void) {
        navigationController.dismiss(animated: true, completion: completion)
    }

    private func showFeedbackOnSuccess() {
        UINotificationFeedbackGenerator.show(feedbackType: .success)
    }

    private func rectifyTransactionError(error: SendTransactionNotRetryableError) {
        analyticsCoordinator.log(action: Analytics.Action.rectifySendTransactionErrorInActionSheet, properties: [Analytics.Properties.type.rawValue: error.analyticsName])
        switch error {
        case .insufficientFunds:
            delegate?.openFiatOnRamp(wallet: configurator.session.account, server: server, inCoordinator: self, viewController: rootViewController)
        case .nonceTooLow:
            showConfigureTransactionViewController(configurator, recoveryMode: .invalidNonce)
        case .gasPriceTooLow:
            showConfigureTransactionViewController(configurator)
        case .gasLimitTooLow:
            showConfigureTransactionViewController(configurator)
        case .gasLimitTooHigh:
            showConfigureTransactionViewController(configurator)
        case .possibleChainIdMismatch:
            break
        case .executionReverted:
            break
        }
    }
}

extension TransactionConfirmationCoordinator: TransactionConfirmationViewControllerDelegate {

    func didInvalidateLayout(in controller: TransactionConfirmationViewController) {
        hostViewController.invalidateLayout()
    }

    func didClose(in controller: TransactionConfirmationViewController) {
        guard canBeDismissed else { return }

        analyticsCoordinator.log(action: Analytics.Action.cancelsTransactionInActionSheet)
        rootViewController.dismiss(animated: true) {
            self.delegate?.didClose(in: self)
        }
    }

    func controller(_ controller: TransactionConfirmationViewController, continueButtonTapped sender: UIButton) {
        sender.isEnabled = false
        canBeDismissed = false
        rootViewController.set(state: .pending)

        firstly { () -> Promise<ConfirmResult> in
            return sendTransaction()
        }.done { result in
            self.handleSendTransactionSuccessfully(result: result)
            self.logCompleteActionSheetForTransactionConfirmationSuccessfully()
        }.catch { error in
            self.logActionSheetForTransactionConfirmationFailed()
            //TODO remove delay which is currently needed because the starting animation may not have completed and internal state (whether animation is running) is in correct
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.rootViewController.set(state: .done(withError: true)) {
                    self.handleSendTransactionError(error)
                }
            }
        }.finally {
            sender.isEnabled = true
            self.canBeDismissed = true
        }
    }

    private func sendTransaction() -> Promise<ConfirmResult> {
        let coordinator = SendTransactionCoordinator(session: configurator.session, keystore: configuration.keystore, confirmType: configuration.confirmType, config: configurator.session.config, analyticsCoordinator: analyticsCoordinator)
        let transaction = configurator.formUnsignedTransaction()
        return coordinator.send(transaction: transaction)
    }

    private func handleSendTransactionSuccessfully(result: ConfirmResult) {
        switch result {
        case .sentTransaction(let tx):
            delegate?.didSendTransaction(tx, inCoordinator: self)
        case .sentRawTransaction, .signedTransaction:
            break
        }

        rootViewController.set(state: .done(withError: false)) {
            self.showFeedbackOnSuccess()
            self.delegate?.didFinish(result, in: self)
        }
    }

    private func handleSendTransactionError(_ error: Error) {
        switch error {
        case let e as SendTransactionNotRetryableError:
            let errorViewController = SendTransactionErrorViewController(server: server, analyticsCoordinator: analyticsCoordinator, error: e)
            errorViewController.delegate = self

            let panel = FloatingPanelController(isPanEnabled: false)
            panel.layout = SelfSizingPanelLayout(referenceGuide: .superview)
            panel.set(contentViewController: errorViewController)

            rootViewController.present(panel, animated: true)
        default:
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        delegate?.coordinator(self, didFailTransaction: AnyError(error))
    }

    func controllerDidTapEdit(_ controller: TransactionConfirmationViewController) {
        showConfigureTransactionViewController(configurator)
    }

    private func showConfigureTransactionViewController(_ configurator: TransactionConfigurator, recoveryMode: ConfigureTransactionViewModel.RecoveryMode = .none) {
        let controller = ConfigureTransactionViewController(viewModel: .init(configurator: configurator, recoveryMode: recoveryMode))
        controller.delegate = self

        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.makePresentationFullScreenForiOS13Migration()
        controller.navigationItem.leftBarButtonItem = .closeBarButton(self, selector: #selector(configureTransactionDidDismiss))
        
        hostViewController.present(navigationController, animated: true)

        configureTransactionViewController = controller
    }

    @objc func configureTransactionDidDismiss() {
        configureTransactionViewController?.navigationController?.dismiss(animated: true)
    }
}

extension TransactionConfirmationCoordinator: ConfigureTransactionViewControllerDelegate {
    func didSavedToUseDefaultConfigurationType(_ configurationType: TransactionConfigurationType, in viewController: ConfigureTransactionViewController) {
        configurator.chooseDefaultConfigurationType(configurationType)
        viewController.navigationController?.dismiss(animated: true)
    }

    func didSaved(customConfiguration: TransactionConfiguration, in viewController: ConfigureTransactionViewController) {
        configurator.chooseCustomConfiguration(customConfiguration)
        viewController.navigationController?.dismiss(animated: true)
    }
}

extension TransactionConfirmationCoordinator: TransactionConfiguratorDelegate {
    func configurationChanged(in configurator: TransactionConfigurator) {
        rootViewController.reloadView()
        rootViewController.reloadViewWithCurrentBalanceValue()
    }

    func gasLimitEstimateUpdated(to estimate: BigInt, in configurator: TransactionConfigurator) {
        configureTransactionViewController?.configure(withEstimatedGasLimit: estimate)
        rootViewController.reloadViewWithGasChanges()
        rootViewController.reloadViewWithCurrentBalanceValue()
    }

    func gasPriceEstimateUpdated(to estimate: BigInt, in configurator: TransactionConfigurator) {
        configureTransactionViewController?.configure(withEstimatedGasPrice: estimate, configurator: configurator)
        rootViewController.reloadViewWithGasChanges()
        rootViewController.reloadViewWithCurrentBalanceValue()
    }

    func updateNonce(to nonce: Int, in configurator: TransactionConfigurator) {
        configureTransactionViewController?.configure(nonce: nonce, configurator: configurator)
    }
}

// MARK: Analytics
extension TransactionConfirmationCoordinator {
    private func logCompleteActionSheetForTransactionConfirmationSuccessfully() {
        let speedType: Analytics.TransactionConfirmationSpeedType
        switch configurator.selectedConfigurationType {
        case .slow:
            speedType = .slow
        case .standard:
            speedType = .standard
        case .fast:
            speedType = .fast
        case .rapid:
            speedType = .rapid
        case .custom:
            speedType = .custom
        }

        let transactionType: Analytics.TransactionType
        if let functionCallMetaData = DecodedFunctionCall(data: configurator.currentConfiguration.data) {
            switch functionCallMetaData.type {
            case .erc1155SafeTransfer:
                transactionType = .unknown
            case .erc1155SafeBatchTransfer:
                transactionType = .unknown
            case .erc20Approve:
                transactionType = .erc20Approve
            case .erc20Transfer:
                transactionType = .erc20Transfer
            case .nativeCryptoTransfer:
                transactionType = .nativeCryptoTransfer
            case .others:
                transactionType = .unknown
            }
        } else if configurator.currentConfiguration.data.isEmpty {
            transactionType = .nativeCryptoTransfer
        } else {
            transactionType = .unknown
        }

        let overridingRpcUrl: URL? = configurator.session.config.sendPrivateTransactionsProvider?.rpcUrl(forServer: configurator.session.server)
        let privateNetworkProvider: SendPrivateTransactionsProvider?
        if overridingRpcUrl == nil {
            privateNetworkProvider = nil
        } else {
            privateNetworkProvider = configurator.session.config.sendPrivateTransactionsProvider
        }
        var analyticsProperties: [String: AnalyticsEventPropertyValue] = [
            Analytics.Properties.speedType.rawValue: speedType.rawValue,
            Analytics.Properties.chain.rawValue: server.chainID,
            Analytics.Properties.transactionType.rawValue: transactionType.rawValue,
            //This is around for legacy reasons as we already send the provider if it's used
            Analytics.Properties.isPrivateNetworkEnabled.rawValue: privateNetworkProvider != nil,
        ]
        if let provider = privateNetworkProvider {
            analyticsProperties[Analytics.Properties.sendPrivateTransactionsProvider.rawValue] = provider.rawValue
            infoLog("Sent transaction with send private transactions provider: \(provider.rawValue)")
        } else {
            //no-op
            infoLog("Sent transaction publicly")
        }
        switch configuration {
        case .sendFungiblesTransaction(_, _, _, amount: let amount):
            analyticsProperties[Analytics.Properties.isAllFunds.rawValue] = amount.isAllFunds
        case .tokenScriptTransaction, .dappTransaction, .walletConnect, .sendNftTransaction, .claimPaidErc875MagicLink, .speedupTransaction, .cancelTransaction:
            break
        }

        analyticsCoordinator.log(navigation: Analytics.Navigation.actionSheetForTransactionConfirmationSuccessful, properties: analyticsProperties)
        if server.isTestnet {
            analyticsCoordinator.incrementUser(property: Analytics.UserProperties.testnetTransactionCount, by: 1)
        } else {
            analyticsCoordinator.incrementUser(property: Analytics.UserProperties.transactionCount, by: 1)
        }
    }

    //TODO log a finite list of error types
    private func logActionSheetForTransactionConfirmationFailed() {
        analyticsCoordinator.log(navigation: Analytics.Navigation.actionSheetForTransactionConfirmationFailed)
    }

    private func logStartActionSheetForTransactionConfirmation(source: Analytics.TransactionConfirmationSource) {
        var analyticsProperties: [String: AnalyticsEventPropertyValue] = [Analytics.Properties.source.rawValue: source.rawValue]
        switch configuration {
        case .sendFungiblesTransaction(_, _, _, amount: let amount):
            analyticsProperties[Analytics.Properties.isAllFunds.rawValue] = amount.isAllFunds
        case .tokenScriptTransaction, .dappTransaction, .walletConnect, .sendNftTransaction, .claimPaidErc875MagicLink, .speedupTransaction, .cancelTransaction:
            break
        }
        analyticsCoordinator.log(navigation: Analytics.Navigation.actionSheetForTransactionConfirmation, properties: analyticsProperties)
    }
}

extension TransactionConfirmationCoordinator: SendTransactionErrorViewControllerDelegate {
    func rectifyErrorButtonTapped(error: SendTransactionNotRetryableError, inController controller: SendTransactionErrorViewController) {
        controller.dismiss(animated: true) {
            self.rectifyTransactionError(error: error)
        }
    }

    func linkTapped(_ url: URL, forError error: SendTransactionNotRetryableError, inController controller: SendTransactionErrorViewController) {
        controller.dismiss(animated: true) {
            self.delegate?.didPressOpenWebPage(url, in: self.rootViewController)
        }
    }

    func controllerDismiss(_ controller: SendTransactionErrorViewController) {
        controller.dismiss(animated: true)
    }
}

extension SendTransactionNotRetryableError {
    var analyticsName: String {
        switch self {
        case .insufficientFunds:
            return "insufficientFunds"
        case .nonceTooLow:
            return "nonceTooLow"
        case .gasPriceTooLow:
            return "gasPriceTooLow"
        case .gasLimitTooLow:
            return "gasLimitTooLow"
        case .gasLimitTooHigh:
            return "gasLimitTooHigh"
        case .possibleChainIdMismatch:
            return "possibleChainIdMismatch"
        case .executionReverted:
            return "executionReverted"
        }
    }
}
