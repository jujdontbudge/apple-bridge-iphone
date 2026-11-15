import Foundation

public struct Review: Sendable {
    public enum Highlighted: Equatable, Sendable {
        case money(MoneyAmount, token: String)
        case unformattable(ArgumentValue, currency: String)
        case text(ArgumentValue)
        case missing
    }

    public struct Highlight: Identifiable, Equatable, Sendable {
        public let id: Int
        public let label: String
        public let value: Highlighted
    }

    public enum Container: Equatable, Sendable {
        case object(Int)
        case array(Int)
    }

    public struct ArgumentRow: Identifiable, Equatable, Sendable {
        public let id: Int
        public let depth: Int
        public let label: String?
        public let leaf: ArgumentValue?
        public let container: Container?
        public let highlighted: Bool
    }

    public let request: ApprovalRequest
    public let highlights: [Highlight]
    public let arguments: [ArgumentRow]?
    public let warnings: [String]

    public init(_ request: ApprovalRequest) {
        self.request = request
        var highlights: [Highlight] = []
        var money: [MoneyAmount] = []
        var unformattable = 0
        for (index, hint) in request.hints.enumerated() {
            let label = Review.label(hint.path)
            guard let value = request.value(at: hint.path) else {
                highlights.append(Highlight(id: index, label: label, value: .missing))
                continue
            }
            switch hint.format {
            case .text:
                highlights.append(Highlight(id: index, label: label, value: .text(value)))
            case .moneyMinor(let currency):
                if case .number(let token) = value, let amount = MoneyAmount.minor(token, currency: currency) {
                    money.append(amount)
                    highlights.append(Highlight(id: index, label: label, value: .money(amount, token: token)))
                } else {
                    unformattable += 1
                    highlights.append(Highlight(id: index, label: label, value: .unformattable(value, currency: currency)))
                }
            }
        }
        self.highlights = highlights
        self.warnings = MismatchRule.warnings(justification: request.justification, money: money, unformattable: unformattable)
        var rows: [ArgumentRow] = []
        let marked = Set(request.hints.map(\.path))
        switch request.arguments {
        case .object(let members)? where !members.isEmpty:
            for member in members { Review.flatten(member.value, label: member.key, path: [.key(member.key)], marked: marked, depth: 0, into: &rows) }
        case .array(let items)? where !items.isEmpty:
            for (index, item) in items.enumerated() { Review.flatten(item, label: "[\(index)]", path: [.index(UInt32(index))], marked: marked, depth: 0, into: &rows) }
        case let value?:
            Review.flatten(value, label: nil, path: [], marked: marked, depth: 0, into: &rows)
        case nil:
            break
        }
        self.arguments = request.arguments == nil ? nil : rows
    }

    public static func label(_ path: [PathElement]) -> String {
        var text = ""
        for element in path {
            switch element {
            case .key(let key): text += text.isEmpty ? key : "." + key
            case .index(let index): text += "[\(index)]"
            }
        }
        return text.isEmpty ? "arguments" : text
    }

    private static func flatten(_ value: ArgumentValue, label: String?, path: [PathElement], marked: Set<[PathElement]>, depth: Int, into rows: inout [ArgumentRow]) {
        let highlighted = marked.contains(path)
        switch value {
        case .object(let members) where !members.isEmpty:
            rows.append(ArgumentRow(id: rows.count, depth: depth, label: label, leaf: nil, container: .object(members.count), highlighted: highlighted))
            for member in members { flatten(member.value, label: member.key, path: path + [.key(member.key)], marked: marked, depth: depth + 1, into: &rows) }
        case .array(let items) where !items.isEmpty:
            rows.append(ArgumentRow(id: rows.count, depth: depth, label: label, leaf: nil, container: .array(items.count), highlighted: highlighted))
            for (index, item) in items.enumerated() { flatten(item, label: "[\(index)]", path: path + [.index(UInt32(index))], marked: marked, depth: depth + 1, into: &rows) }
        default:
            rows.append(ArgumentRow(id: rows.count, depth: depth, label: label, leaf: value, container: nil, highlighted: highlighted))
        }
    }
}
