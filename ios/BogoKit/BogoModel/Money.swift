import Foundation

public struct MoneyAmount: Equatable, Sendable {
    public let currency: String
    public let minorUnits: String
    public let negative: Bool

    public var exponent: Int { Currency.exponent(currency) }

    public var formatted: String {
        let padded = String(repeating: "0", count: max(0, exponent + 1 - minorUnits.count)) + minorUnits
        let whole = String(padded.dropLast(exponent))
        let fraction = String(padded.suffix(exponent))
        var grouped = ""
        for (offset, digit) in whole.reversed().enumerated() {
            if offset > 0 && offset % 3 == 0 { grouped.insert(",", at: grouped.startIndex) }
            grouped.insert(digit, at: grouped.startIndex)
        }
        let number = exponent > 0 ? grouped + "." + fraction : grouped
        let sign = negative ? "−" : ""
        if let symbol = Currency.symbol(currency) { return sign + symbol + number }
        return sign + currency + " " + number
    }

    public static func minor(_ text: String, currency: String) -> MoneyAmount? {
        guard Currency.known(currency) else { return nil }
        var digits = Substring(text)
        let negative = digits.first == "-"
        if negative { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.count <= 15, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard digits == "0" ? !negative : digits.first != "0" else { return nil }
        return MoneyAmount(currency: currency, minorUnits: String(digits), negative: negative)
    }

    func equalsMajor(whole: String, fraction: String) -> Bool {
        guard !negative else { return false }
        let significant = fraction.reversed().drop { $0 == "0" }.count
        guard significant <= exponent else { return false }
        let scaled = whole + fraction.prefix(exponent) + String(repeating: "0", count: max(0, exponent - fraction.count))
        let trimmed = scaled.drop { $0 == "0" }
        return trimmed == minorUnits.drop { $0 == "0" }
    }
}

enum Currency {
    static let zeroDecimal: Set<String> = ["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF"]
    static let threeDecimal: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]
    static let symbols: [String: String] = ["USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥"]
    static let common: Set<String> = ["USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "NZD", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF", "MXN", "BRL", "INR", "CNY", "HKD", "SGD", "ZAR", "KRW", "TRY", "ILS", "AED", "SAR", "THB", "IDR", "MYR", "PHP", "VND", "CLP", "ISK"]

    static func known(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    static func exponent(_ code: String) -> Int {
        if zeroDecimal.contains(code) { return 0 }
        if threeDecimal.contains(code) { return 3 }
        return 2
    }

    static func symbol(_ code: String) -> String? {
        symbols[code]
    }
}
