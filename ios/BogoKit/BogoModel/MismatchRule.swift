import Foundation

public struct MoneyMention: Equatable, Sendable {
    public let text: String
    public let whole: String
    public let fraction: String
}

public enum MismatchRule {
    private static let amount = #"(?<![\d.,])(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?(?![\d]|[.,]\d)"#
    private static let codes = Currency.common.sorted().joined(separator: "|")
    nonisolated(unsafe) private static let patterns: [NSRegularExpression] = [
        #"(?:US)?\$\s?"# + amount,
        #"[€£¥]\s?"# + amount,
        amount + #"\s?[$€£¥]"#,
        #"\b(?:"# + codes + #")\s?"# + amount,
        amount + #"\s?(?:"# + codes + #")\b"#,
        amount + #"\s?(?:dollars?|euros?|pounds?|bucks)\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    public static func mentions(_ justification: String) -> [MoneyMention] {
        let text = justification as NSString
        var found: [(NSRange, MoneyMention)] = []
        for pattern in patterns {
            for match in pattern.matches(in: justification, range: NSRange(location: 0, length: text.length)) {
                guard !found.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { continue }
                let whole = text.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
                let fractionRange = match.range(at: 2)
                let fraction = fractionRange.location == NSNotFound ? "" : text.substring(with: fractionRange)
                found.append((match.range, MoneyMention(text: text.substring(with: match.range), whole: whole, fraction: fraction)))
            }
        }
        return found.sorted { $0.0.location < $1.0.location }.map(\.1)
    }

    public static func warnings(justification: String?, money: [MoneyAmount], unformattable: Int = 0) -> [String] {
        guard let justification else { return [] }
        return mentions(justification).compactMap { mention in
            if money.contains(where: { $0.equalsMajor(whole: mention.whole, fraction: mention.fraction) }) { return nil }
            if money.isEmpty && unformattable > 0 { return "Reason says \(mention.text), but the amount here can’t be shown as money" }
            if money.isEmpty { return "Reason says \(mention.text), but nothing here is shown as money" }
            let amounts = money.map(\.formatted)
            if amounts.count == 1 { return "Reason says \(mention.text), but this will charge \(amounts[0])" }
            return "Reason says \(mention.text), but the amounts here are \(amounts.joined(separator: " and "))"
        }
    }
}
