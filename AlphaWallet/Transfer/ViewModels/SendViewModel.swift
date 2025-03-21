// Copyright © 2018 Stormbird PTE. LTD.

import Foundation
import UIKit
import BigInt

struct SendViewModel {
    private let session: WalletSession
    private let tokensDataStore: TokensDataStore

    let transactionType: TransactionType

    init(transactionType: TransactionType, session: WalletSession, tokensDataStore: TokensDataStore) {
        self.transactionType = transactionType
        self.session = session
        self.tokensDataStore = tokensDataStore
    }

    let amountViewModel = SendViewSectionHeaderViewModel(
        text: R.string.localizable.sendAmount().uppercased(),
        showTopSeparatorLine: true
    )
    let recipientViewModel = SendViewSectionHeaderViewModel(
        text: R.string.localizable.sendRecipient().uppercased()
    )

    var destinationAddress: AlphaWallet.Address {
        return transactionType.contract
    }

    var backgroundColor: UIColor {
        return Colors.appBackground
    }

    var token: TokenObject? {
        switch transactionType {
        case .nativeCryptocurrency:
            return nil
        case .erc20Token(let token, _, _):
            return token
        case .erc875Token(let token, _):
            return token
        case .erc875TokenOrder(let token, _):
            return token
        case .erc721Token(let token, _):
            return token
        case .erc721ForTicketToken(let token, _):
            return token
        case .erc1155Token(let token, _, _):
            return token
        case .dapp, .tokenScript, .claimPaidErc875MagicLink, .prebuilt:
            return nil
        }
    }

    var textFieldsLabelTextColor: UIColor {
        return Colors.appGrayLabel
    }
    var textFieldsLabelFont: UIFont {
        return Fonts.regular(size: 10)
    }

    var recipientLabelFont: UIFont {
        return Fonts.regular(size: 13)
    }

    var recepientLabelTextColor: UIColor {
        return R.color.dove()!
    }

    var recipientsAddress: String {
        return R.string.localizable.sendRecipientsAddress()
    }

    var selectCurrencyButtonHidden: Bool {
        switch transactionType {
        case .nativeCryptocurrency:
            guard let ticker = session.tokenBalanceService.coinTicker(transactionType.addressAndRPCServer), ticker.price_usd > 0 else {
                return true
            }
            return false
        case .erc20Token, .erc875Token, .erc875TokenOrder, .erc721Token, .erc721ForTicketToken, .erc1155Token, .dapp, .tokenScript, .claimPaidErc875MagicLink, .prebuilt:
            return true
        }
    }

    var currencyButtonHidden: Bool {
        switch transactionType {
        case .nativeCryptocurrency, .erc20Token:
            return false
        case .erc875Token, .erc875TokenOrder, .erc721Token, .erc721ForTicketToken, .erc1155Token, .dapp, .tokenScript, .claimPaidErc875MagicLink, .prebuilt:
            return true
        }
    }

    var availableLabelText: String? {
        switch transactionType {
        case .nativeCryptocurrency:
            return R.string.localizable.sendAvailable(session.tokenBalanceService.ethBalanceViewModel.amountShort)
        case .erc20Token(let token, _, _):
            let value = EtherNumberFormatter.short.string(from: token.valueBigInt, decimals: token.decimals)
            return R.string.localizable.sendAvailable("\(value) \(transactionType.symbol)")
        case .dapp, .erc721ForTicketToken, .erc721Token, .erc875Token, .erc875TokenOrder, .erc1155Token, .tokenScript, .claimPaidErc875MagicLink, .prebuilt:
            break
        }

        return nil
    }

    var availableTextHidden: Bool {
        switch transactionType {
        case .nativeCryptocurrency:
            return false
        case .erc20Token(let token, _, _):
            let tokenBalance = tokensDataStore.token(forContract: token.contractAddress, server: session.server)?.valueBigInt
            return tokenBalance == nil
        case .dapp, .erc721ForTicketToken, .erc721Token, .erc875Token, .erc1155Token, .erc875TokenOrder, .tokenScript, .claimPaidErc875MagicLink, .prebuilt:
            break
        }
        return true
    }

    var checkIfGreaterThanZero: Bool {
        switch transactionType {
        case .nativeCryptocurrency, .dapp, .tokenScript, .claimPaidErc875MagicLink, .prebuilt:
            return false
        case .erc20Token, .erc875Token, .erc875TokenOrder, .erc721Token, .erc721ForTicketToken, .erc1155Token:
            return true
        }
    }

    var allFundsFormattedValues: (allFundsFullValue: NSDecimalNumber?, allFundsShortValue: String)? {
        switch transactionType {
        case .nativeCryptocurrency:
            let balance = session.tokenBalanceService.ethBalanceViewModel
            let fullValue = EtherNumberFormatter.plain.string(from: balance.value, units: .ether).droppedTrailingZeros
            let shortValue = EtherNumberFormatter.shortPlain.string(from: balance.value, units: .ether).droppedTrailingZeros

            return (fullValue.optionalDecimalValue, shortValue)
        case .erc20Token(let token, _, _):
            let fullValue = EtherNumberFormatter.plain.string(from: token.valueBigInt, decimals: token.decimals).droppedTrailingZeros
            let shortValue = EtherNumberFormatter.shortPlain.string(from: token.valueBigInt, decimals: token.decimals).droppedTrailingZeros

            return (fullValue.optionalDecimalValue, shortValue)
        case .dapp, .erc721ForTicketToken, .erc721Token, .erc875Token, .erc1155Token, .erc875TokenOrder, .tokenScript, .claimPaidErc875MagicLink, .prebuilt:
            return nil
        }
    }

    func validatedAmount(value amountString: String, checkIfGreaterThanZero: Bool = true) -> BigInt? {
        let parsedValue: BigInt? = {
            switch transactionType {
            case .nativeCryptocurrency, .dapp, .tokenScript, .claimPaidErc875MagicLink, .prebuilt:
                return EtherNumberFormatter.full.number(from: amountString, units: .ether)
            case .erc20Token(let token, _, _):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            case .erc875Token(let token, _):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            case .erc875TokenOrder(let token, _):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            case .erc721Token(let token, _):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            case .erc721ForTicketToken(let token, _):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            case .erc1155Token(let token, _, _):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            }
        }()

        guard let value = parsedValue, checkIfGreaterThanZero ? value > 0 : true else {
            return nil
        }

        switch transactionType {
        case .nativeCryptocurrency:
            if session.tokenBalanceService.ethBalanceViewModel.value < value {
                return nil
            }
        case .erc20Token(let token, _, _):
            if let tokenBalance = tokensDataStore.token(forContract: token.contractAddress, server: session.server)?.valueBigInt, tokenBalance < value {
                return nil
            }
        case .dapp, .erc721ForTicketToken, .erc721Token, .erc875Token, .erc1155Token, .erc875TokenOrder, .tokenScript, .claimPaidErc875MagicLink, .prebuilt:
            break
        }

        return value
    }


    //This function is required because BigInt.init(String) doesn't handle scientific notation
    func convertMaybeScientificAmountToBigInt(_ maybeScientificAmountString: String) -> BigInt? {
        let numberFormatter = Formatter.scientificAmount
        let amountString = numberFormatter.number(from: maybeScientificAmountString).flatMap { numberFormatter.string(from: $0) }
        return amountString.flatMap { BigInt($0) }
    }
}
