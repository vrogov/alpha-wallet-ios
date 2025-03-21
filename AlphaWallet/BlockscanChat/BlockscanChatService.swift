// Copyright © 2022 Stormbird PTE. LTD.

import Combine
import Foundation
import PromiseKit

protocol BlockscanChatServiceDelegate: class {
    func openBlockscanChat(url: URL, for: BlockscanChatService)
    func showBlockscanUnreadCount(_ count: Int?, for: BlockscanChatService)
}

class BlockscanChatService {
    private let account: Wallet
    private var blockscanChatsForRealWallets: [BlockscanChat]
    private let walletAddressesStore: WalletAddressesStore
    private let analyticsCoordinator: AnalyticsCoordinator
    private var cancelable = Set<AnyCancellable>()
    private var periodicRefreshTimer: Timer?
    private var realWalletAddresses: [AlphaWallet.Address] {
        walletAddressesStore.wallets.compactMap {
            switch $0.type {
            case .real(let address):
                return address
            case .watch:
                return nil
            }
        }
    }

    weak var delegate: BlockscanChatServiceDelegate?

    init(walletAddressesStore: WalletAddressesStore, account: Wallet, analyticsCoordinator: AnalyticsCoordinator) {
        self.blockscanChatsForRealWallets = []
        self.walletAddressesStore = walletAddressesStore
        self.account = account
        self.analyticsCoordinator = analyticsCoordinator

        watchForWalletChanges()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        self.periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.periodicallyRefreshUnreadCountsForAllWallets()
        }
    }
    deinit {
        debugLog("[BlockscanChat] BlockscanChatService deinit")
        periodicRefreshTimer?.invalidate()
    }

    private func configureBlockscanChats() {
        blockscanChatsForRealWallets = realWalletAddresses.map { BlockscanChat(address: $0) }
    }

    private func refreshUnreadCount(forBlockscanChat blockscanChat: BlockscanChat) {
        let isCurrentRealAccount = account.address == blockscanChat.address

        guard Features.isBlockscanChatEnabled else { return }
        guard !Constants.Credentials.blockscanChatProxyKey.isEmpty else { return }
        firstly {
            blockscanChat.fetchUnreadCount()
        }.done { [weak self] unreadCount in
           guard let strongSelf = self else { return }
            if unreadCount > 0 {
                strongSelf.logUnreadAnalytics(resultType: Analytics.BlockscanChatResultType.nonZero)
            } else {
                strongSelf.logUnreadAnalytics(resultType: Analytics.BlockscanChatResultType.zero)
            }
            if isCurrentRealAccount {
                strongSelf.delegate?.showBlockscanUnreadCount(unreadCount, for: strongSelf)
            }
        }.catch { [weak self] error in
            guard let strongSelf = self else { return }
            if let error = error as? AFError, let code = error.responseCode, code == 429 {
                strongSelf.logUnreadAnalytics(resultType: Analytics.BlockscanChatResultType.error429)
            } else {
                strongSelf.logUnreadAnalytics(resultType: Analytics.BlockscanChatResultType.errorOthers)
            }
            if isCurrentRealAccount {
                strongSelf.delegate?.showBlockscanUnreadCount(nil, for: strongSelf)
            }
        }
    }

    func openBlockscanChat(forAddress address: AlphaWallet.Address) {
        let isCurrentRealAccount = account.address == address
        guard isCurrentRealAccount else { return }
        delegate?.openBlockscanChat(url: Constants.BlockscanChat.blockscanChatWebUrl.appendingPathComponent(address.eip55String), for: self)
    }

    private func watchForWalletChanges() {
        walletAddressesStore
                .walletsPublisher
                .receive(on: RunLoop.main)
                .sink { [weak self] wallets in
                    guard let strongSelf = self else { return }
                    strongSelf.configureBlockscanChats()
                    strongSelf.refreshUnreadCountsForAllWallets()
                }.store(in: &cancelable)
    }

    private func refreshUnreadCountsForAllWallets() {
        for each in realWalletAddresses {
            getBlockscanChat(forAddress: each).flatMap { refreshUnreadCount(forBlockscanChat: $0) }
        }
    }

    private func periodicallyRefreshUnreadCountsForAllWallets() {
        infoLog("[BlockscanChat] periodicallyRefreshUnreadCountsForAllWallets")
        //TODO refresh for all wallets (maybe less often as the current wallet). Not doing it yet because we don't have a way to show the unread count for inactive wallets
        getBlockscanChat(forAddress: account.address).flatMap { refreshUnreadCount(forBlockscanChat: $0) }
    }

    private func getBlockscanChat(forAddress: AlphaWallet.Address) -> BlockscanChat? {
        blockscanChatsForRealWallets.first { $0.address == forAddress }
    }
}

//MARK: Application State
extension BlockscanChatService {
    @objc private func applicationWillEnterForeground(_ notification: Notification) {
        refreshUnreadCountsForAllWallets()
    }
}

//MARK: Analytics
extension BlockscanChatService {
    private func logUnreadAnalytics(resultType: Analytics.BlockscanChatResultType) {
        analyticsCoordinator.log(stat: Analytics.Stat.blockscanChatFetchUnread, properties: [Analytics.Properties.resultType.rawValue: resultType.rawValue])
    }
}