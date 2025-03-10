// Copyright © 2018 Stormbird PTE. LTD.

import Foundation
import UIKit
import APIKit
import BigInt
import JSONRPCKit
import Moya
import PromiseKit

class EtherscanSingleChainTransactionProvider: SingleChainTransactionProvider {
    private let transactionDataStore: TransactionDataStore
    private let session: WalletSession
    private let tokensDataStore: TokensDataStore
    private let fetchLatestTransactionsQueue: OperationQueue
    private let queue = DispatchQueue(label: "com.SingleChainTransaction.updateQueue")
    private var timer: Timer?
    private var updateTransactionsTimer: Timer?
    private lazy var transactionsTracker: TransactionsTracker = {
        return TransactionsTracker(sessionID: session.sessionID)
    }()
    private let alphaWalletProvider = AlphaWalletProviderFactory.makeProvider()

    private var isAutoDetectingERC20Transactions: Bool = false
    private var isAutoDetectingErc721Transactions: Bool = false
    private var isFetchingLatestTransactions = false

    lazy var tokenProvider: TokenProviderType = TokenProvider(account: session.account, server: session.server)

    required init(
            session: WalletSession,
            transactionDataStore: TransactionDataStore,
            tokensDataStore: TokensDataStore,
            fetchLatestTransactionsQueue: OperationQueue
    ) {
        self.session = session
        self.transactionDataStore = transactionDataStore
        self.tokensDataStore = tokensDataStore
        self.fetchLatestTransactionsQueue = fetchLatestTransactionsQueue
    }

    func start() {
        runScheduledTimers()
        if transactionsTracker.fetchingState != .done {
            fetchOlderTransactions(for: session.account.address)
            autoDetectERC20Transactions()
            autoDetectErc721Transactions()
        }
    }

    func stopTimers() {
        timer?.invalidate()
        timer = nil
        updateTransactionsTimer?.invalidate()
        updateTransactionsTimer = nil
    }

    func runScheduledTimers() {
        guard timer == nil, updateTransactionsTimer == nil else {
            return
        }

        timer = Timer.scheduledTimer(timeInterval: 5, target: BlockOperation { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.fetchPendingTransactions()
        }, selector: #selector(Operation.main), userInfo: nil, repeats: true)

        updateTransactionsTimer = Timer.scheduledTimer(timeInterval: 15, target: BlockOperation { [weak self] in
            guard let strongSelf = self else { return }

            strongSelf.fetchLatestTransactions()
            strongSelf.queue.async {
                strongSelf.autoDetectERC20Transactions()
                strongSelf.autoDetectErc721Transactions()
            }
        }, selector: #selector(Operation.main), userInfo: nil, repeats: true)
    }

    //TODO should this be added to the queue?
    //TODO when blockscout-compatible, this includes ERC721 too. Maybe rename?
    private func autoDetectERC20Transactions() {
        guard !isAutoDetectingERC20Transactions else { return }
        isAutoDetectingERC20Transactions = true
        let server = session.server
        let wallet = session.account.address
        let startBlock = Config.getLastFetchedErc20InteractionBlockNumber(session.server, wallet: wallet).flatMap { $0 + 1 }
        firstly {
            GetContractInteractions(queue: queue).getErc20Interactions(address: wallet, server: server, startBlock: startBlock)
        }.map(on: queue, { result -> (transactions: [TransactionInstance], min: Int, max: Int) in
            return functional.extractBoundingBlockNumbers(fromTransactions: result)
        }).then(on: queue, { [weak self] result, minBlockNumber, maxBlockNumber -> Promise<([TransactionInstance], Int)> in
            guard let strongSelf = self else { return .init(error: PMKError.cancelled) }

            return functional.backFillTransactionGroup(result, startBlock: minBlockNumber, endBlock: maxBlockNumber, session: strongSelf.session, alphaWalletProvider: strongSelf.alphaWalletProvider, tokensDataStore: strongSelf.tokensDataStore, tokenProvider: strongSelf.tokenProvider, queue: strongSelf.queue).map { ($0, maxBlockNumber) }
        }).done(on: queue) { [weak self] backFilledTransactions, maxBlockNumber in
            guard let strongSelf = self else { return }
            //Just to be sure, we don't want any kind of strange errors to clear our progress by resetting blockNumber = 0
            if maxBlockNumber > 0 {
                Config.setLastFetchedErc20InteractionBlockNumber(maxBlockNumber, server: server, wallet: wallet)
            }
            strongSelf.update(transaction: backFilledTransactions)
        }.catch({ e in
            error(value: e, function: #function, rpcServer: server, address: wallet)
        })
        .finally { [weak self] in
            self?.isAutoDetectingERC20Transactions = false
        }
    }

    private func autoDetectErc721Transactions() {
        guard !isAutoDetectingErc721Transactions else { return }
        isAutoDetectingErc721Transactions = true
        let server = session.server
        let wallet = session.account.address
        let startBlock = Config.getLastFetchedErc721InteractionBlockNumber(session.server, wallet: wallet).flatMap { $0 + 1 }
        firstly {
            GetContractInteractions(queue: queue).getErc721Interactions(address: wallet, server: server, startBlock: startBlock)
        }.map(on: queue, { result in
            functional.extractBoundingBlockNumbers(fromTransactions: result)
        }).then(on: queue, { [weak self] result, minBlockNumber, maxBlockNumber -> Promise<([TransactionInstance], Int)> in
            guard let strongSelf = self else { return .init(error: PMKError.cancelled) }
            return functional.backFillTransactionGroup(result, startBlock: minBlockNumber, endBlock: maxBlockNumber, session: strongSelf.session, alphaWalletProvider: strongSelf.alphaWalletProvider, tokensDataStore: strongSelf.tokensDataStore, tokenProvider: strongSelf.tokenProvider, queue: strongSelf.queue).map { ($0, maxBlockNumber) }
        }).done(on: queue) { [weak self] backFilledTransactions, maxBlockNumber in
            guard let strongSelf = self else { return }
            //Just to be sure, we don't want any kind of strange errors to clear our progress by resetting blockNumber = 0
            if maxBlockNumber > 0 {
                Config.setLastFetchedErc721InteractionBlockNumber(maxBlockNumber, server: server, wallet: wallet)
            }
            strongSelf.update(transaction: backFilledTransactions)
        }.catch({ e in
            error(value: e, rpcServer: server, address: wallet)
        })
        .finally { [weak self] in
            self?.isAutoDetectingErc721Transactions = false
        }
    }

    func fetch() {
        session.refresh(.balance)
        fetchLatestTransactions()
        fetchPendingTransactions()
    }

    private func update(transaction: [TransactionInstance]) {
        guard !transaction.isEmpty else { return }

        filterTransactionsToPullContractsFrom(transaction).done(on: .main, { [weak self] transactionsToPullContractsFrom, contractsAndTokenTypes in
            guard let strongSelf = self else { return }
            strongSelf.transactionDataStore.add(transactions: transaction, transactionsToPullContractsFrom: transactionsToPullContractsFrom, contractsAndTokenTypes: contractsAndTokenTypes)
        }).cauterize()
    }

    private func detectContractsToAvoid(for tokensStorage: TokensDataStore, forServer server: RPCServer) -> Promise<[AlphaWallet.Address]> {
        return Promise { seal in
            DispatchQueue.main.async {
                let deletedContracts = tokensStorage.deletedContracts(forServer: server).map { $0.contractAddress }
                let hiddenContracts = tokensStorage.hiddenContracts(forServer: server).map { $0.contractAddress }
                let delegateContracts = tokensStorage.delegateContracts(forServer: server).map { $0.contractAddress }
                let alreadyAddedContracts = tokensStorage.enabledTokenObjects(forServers: [server]).map { $0.contractAddress }

                seal.fulfill(alreadyAddedContracts + deletedContracts + hiddenContracts + delegateContracts)
            }
        }
    }

    private func filterTransactionsToPullContractsFrom(_ transactions: [TransactionInstance]) -> Promise<(transactions: [TransactionInstance], contractTypes: [AlphaWallet.Address: TokenType])> {
        return detectContractsToAvoid(for: tokensDataStore, forServer: session.server).then(on: queue, { [weak self] contractsToAvoid -> Promise<(transactions: [TransactionInstance], contractTypes: [AlphaWallet.Address: TokenType])> in
            guard let strongSelf = self else { return .init(error: PMKError.cancelled) }

            let filteredTransactions = transactions.filter {
                if let toAddressToCheck = AlphaWallet.Address(string: $0.to), contractsToAvoid.contains(toAddressToCheck) {
                    return false
                }
                if let contractAddressToCheck = $0.operation?.contractAddress, contractsToAvoid.contains(contractAddressToCheck) {
                    return false
                }
                return true
            }

            //The fetch ERC20 transactions endpoint from Etherscan returns only ERC20 token transactions but the Blockscout version also includes ERC721 transactions too (so it's likely other types that it can detect will be returned too); thus we check the token type rather than assume that they are all ERC20
            let contracts = Array(Set(filteredTransactions.compactMap { $0.localizedOperations.first?.contractAddress }))
            let tokenTypePromises = contracts.map { strongSelf.tokenProvider.getTokenType(for: $0) }

            return when(fulfilled: tokenTypePromises).map(on: strongSelf.queue, { tokenTypes in
                let contractsToTokenTypes = Dictionary(uniqueKeysWithValues: zip(contracts, tokenTypes))
                return (transactions: filteredTransactions, contractTypes: contractsToTokenTypes)
            })
        })
    }

    private func fetchPendingTransactions() {
        for each in transactionDataStore.transactions(forServer: session.server, withTransactionState: .pending) {
            updatePendingTransaction(each )
        }
    }

    private func updatePendingTransaction(_ transaction: TransactionInstance) {
        let request = GetTransactionRequest(hash: transaction.id)

        firstly {
            Session.send(EtherServiceRequest(server: session.server, batch: BatchFactory().create(request)))
        }.done { [weak self] pendingTransaction in
            guard let strongSelf = self else { return }

            if let blockNumber = Int(pendingTransaction.blockNumber), blockNumber > 0 {
                //NOTE: We dont want to call function handleUpdateItems: twice because it will be updated in update(items:
                strongSelf.update(state: .completed, for: transaction, withPendingTransaction: pendingTransaction, shouldUpdateItems: false)
                strongSelf.update(transaction: [transaction])
            }
        }.catch { [weak self] error in
            guard let strongSelf = self else { return }

            switch error as? SessionTaskError {
            case .responseError(let error):
                // TODO: Think about the logic to handle pending transactions.
                //TODO we need to detect when a transaction is marked as failed by the node?
                switch error as? JSONRPCError {
                case .responseError:
                    strongSelf.delete(transactions: [transaction])
                case .resultObjectParseError:
                    guard strongSelf.transactionDataStore.hasCompletedTransaction(withNonce: transaction.nonce, forServer: strongSelf.session.server) else { return }
                    strongSelf.delete(transactions: [transaction])
                    //The transaction might not be posted to this node yet (ie. it doesn't even think that this transaction is pending). Especially common if we post a transaction to Ethermine and fetch pending status through Etherscan
                case .responseNotFound, .errorObjectParseError, .unsupportedVersion, .unexpectedTypeObject, .missingBothResultAndError, .nonArrayResponse, .none:
                    break
                }
            case .connectionError, .requestError, .none:
                break
            }
        }
    }

    private func delete(transactions: [TransactionInstance]) {
        transactionDataStore.delete(transactions: transactions)
    }

    private func update(state: TransactionState, for transaction: TransactionInstance, withPendingTransaction pendingTransaction: PendingTransaction?, shouldUpdateItems: Bool = true) {
        transactionDataStore.update(state: state, for: transaction.primaryKey, withPendingTransaction: pendingTransaction)
    }

    ///Fetching transactions might take a long time, we use a flag to make sure we only pull the latest transactions 1 "page" at a time, otherwise we'd end up pulling the same "page" multiple times
    private func fetchLatestTransactions() {
        guard !isFetchingLatestTransactions else { return }
        isFetchingLatestTransactions = true

        let startBlock: Int
        let sortOrder: AlphaWalletService.SortOrder

        if let newestCachedTransaction = transactionDataStore.transactionObjectsThatDoNotComeFromEventLogs(forServer: session.server) {
            startBlock = newestCachedTransaction.blockNumber + 1
            sortOrder = .asc
        } else {
            startBlock = 1
            sortOrder = .desc
        }

        let operation = FetchLatestTransactionsOperation(forSession: session, coordinator: self, startBlock: startBlock, sortOrder: sortOrder, queue: queue)
        fetchLatestTransactionsQueue.addOperation(operation)
    }

    private func fetchOlderTransactions(for address: AlphaWallet.Address) {
        guard let oldestCachedTransaction = transactionDataStore.lastTransaction(forServer: session.server, withTransactionState: .completed) else { return }

        let promise = functional.fetchTransactions(for: address, startBlock: 1, endBlock: oldestCachedTransaction.blockNumber - 1, sortOrder: .desc, session: session, alphaWalletProvider: alphaWalletProvider, tokensDataStore: tokensDataStore, tokenProvider: tokenProvider, queue: queue)
        promise.done(on: queue, { [weak self] transactions in
            guard let strongSelf = self else { return }

            strongSelf.update(transaction: transactions)

            if transactions.isEmpty {
                strongSelf.transactionsTracker.fetchingState = .done
            } else {
                let timeout = DispatchTime.now() + .milliseconds(300)
                DispatchQueue.main.asyncAfter(deadline: timeout) {
                    strongSelf.fetchOlderTransactions(for: address)
                }
            }
        }).catch(on: queue, { [weak self] _ in
            guard let strongSelf = self else { return }

            strongSelf.transactionsTracker.fetchingState = .failed
        })
    }

    func stop() {
        timer?.invalidate()
        timer = nil

        updateTransactionsTimer?.invalidate()
        updateTransactionsTimer = nil
    }

    func isServer(_ server: RPCServer) -> Bool {
        return session.server == server
    }

    //This inner class reaches into the internals of its outer coordinator class to call some methods. It exists so we can wrap operations into an Operation class and feed it into a queue, so we don't put much logic into it
    class FetchLatestTransactionsOperation: Operation {
        private let session: WalletSession
        weak private var coordinator: EtherscanSingleChainTransactionProvider?
        private let startBlock: Int
        private let sortOrder: AlphaWalletService.SortOrder
        override var isExecuting: Bool {
            return coordinator?.isFetchingLatestTransactions ?? false
        }
        override var isFinished: Bool {
            return !isExecuting
        }
        override var isAsynchronous: Bool {
            return true
        }
        private let queue: DispatchQueue

        init(forSession session: WalletSession, coordinator: EtherscanSingleChainTransactionProvider, startBlock: Int, sortOrder: AlphaWalletService.SortOrder, queue: DispatchQueue) {
            self.session = session
            self.coordinator = coordinator
            self.startBlock = startBlock
            self.sortOrder = sortOrder
            self.queue = queue
            super.init()
            self.queuePriority = session.server.networkRequestsQueuePriority
        }

        override func main() {
            guard let coordinator = self.coordinator else { return }

            firstly {
                EtherscanSingleChainTransactionProvider.functional.fetchTransactions(for: session.account.address, startBlock: startBlock, sortOrder: sortOrder, session: coordinator.session, alphaWalletProvider: coordinator.alphaWalletProvider, tokensDataStore: coordinator.tokensDataStore, tokenProvider: coordinator.tokenProvider, queue: coordinator.queue)
            }.done(on: queue, { transactions in
                coordinator.update(transaction: transactions)
            }).catch { e in
                error(value: e, rpcServer: coordinator.session.server, address: self.session.account.address)
            }.finally { [weak self] in
                guard let strongSelf = self else { return }

                strongSelf.willChangeValue(forKey: "isExecuting")
                strongSelf.willChangeValue(forKey: "isFinished")

                coordinator.isFetchingLatestTransactions = false

                strongSelf.didChangeValue(forKey: "isExecuting")
                strongSelf.didChangeValue(forKey: "isFinished")
            }
        }
    }
}

extension EtherscanSingleChainTransactionProvider {
    class functional {}
}

extension EtherscanSingleChainTransactionProvider.functional {
    static func extractBoundingBlockNumbers(fromTransactions transactions: [TransactionInstance]) -> (transactions: [TransactionInstance], min: Int, max: Int) {
        let blockNumbers = transactions.map(\.blockNumber)
        if let minBlockNumber = blockNumbers.min(), let maxBlockNumber = blockNumbers.max() {
            return (transactions: transactions, min: minBlockNumber, max: maxBlockNumber)
        } else {
            return (transactions: [], min: 0, max: 0)
        }
    }

    static func fetchTransactions(for address: AlphaWallet.Address, startBlock: Int, endBlock: Int = 999_999_999, sortOrder: AlphaWalletService.SortOrder, session: WalletSession, alphaWalletProvider: MoyaProvider<AlphaWalletService>, tokensDataStore: TokensDataStore, tokenProvider: TokenProviderType, queue: DispatchQueue) -> Promise<[TransactionInstance]> {
        let target: AlphaWalletService = .getTransactions(config: session.config, server: session.server, address: address, startBlock: startBlock, endBlock: endBlock, sortOrder: sortOrder)
        return firstly {
            alphaWalletProvider.request(target)
        }.map(on: queue) { response -> [Promise<TransactionInstance?>] in
            if response.statusCode == 404 {
                //Clearer than a JSON deserialization error when it's a 404
                enum E: Error {
                    case statusCode404
                }
                throw E.statusCode404
            }
            return try response.map(ArrayResponse<RawTransaction>.self).result.map {
                TransactionInstance.from(transaction: $0, tokensDataStore: tokensDataStore, tokenProvider: tokenProvider, server: session.server)
            }
        }.then(on: queue) {
            when(fulfilled: $0).compactMap(on: queue) {
                $0.compactMap { $0 }
            }
        }
    }

    static func backFillTransactionGroup(_ transactionsToFill: [TransactionInstance], startBlock: Int, endBlock: Int, session: WalletSession, alphaWalletProvider: MoyaProvider<AlphaWalletService>, tokensDataStore: TokensDataStore, tokenProvider: TokenProviderType, queue: DispatchQueue) -> Promise<[TransactionInstance]> {
        guard !transactionsToFill.isEmpty else { return .value([]) }
        return firstly {
            fetchTransactions(for: session.account.address, startBlock: startBlock, endBlock: endBlock, sortOrder: .asc, session: session, alphaWalletProvider: alphaWalletProvider, tokensDataStore: tokensDataStore, tokenProvider: tokenProvider, queue: queue)
        }.map(on: queue) { fillerTransactions -> [TransactionInstance] in
            var results: [TransactionInstance] = .init()
            for each in transactionsToFill {
                //ERC20 transactions are expected to have operations because of the API we use to retrieve them from
                guard !each.localizedOperations.isEmpty else { continue }
                if var transaction = fillerTransactions.first(where: { $0.blockNumber == each.blockNumber }) {
                    transaction.isERC20Interaction = true
                    transaction.localizedOperations = each.localizedOperations
                    results.append(transaction)
                } else {
                    results.append(each)
                }
            }
            return results
        }
    }
}

func error(value e: Error, pref: String = "", function f: String = #function, rpcServer: RPCServer? = nil, address: AlphaWallet.Address? = nil) {
    var description = pref
    description += rpcServer.flatMap { " server: \($0)" } ?? ""
    description += address.flatMap { " address: \($0.eip55String)" } ?? ""
    description += " \(e)"
    errorLog(description, callerFunctionName: f)
}
