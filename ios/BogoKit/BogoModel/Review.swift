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
        public let picture: String?
    }

    public let request: ApprovalRequest
    public let highlights: [Highlight]
    public let arguments: [ArgumentRow]?
    public let warnings: [String]
    public let reasonPictures: [String]

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
        self.reasonPictures = Review.pictureLinks(in: request.justification ?? "")
        var rows: [ArgumentRow] = []
        let marked = Set(request.hints.map(\.path))
        switch request.arguments {
        case .object(let members)? where !members.isEmpty:
            for member in members { Review.flatten(member.value, label: member.key, key: member.key, path: [.key(member.key)], marked: marked, depth: 0, into: &rows) }
        case .array(let items)? where !items.isEmpty:
            for (index, item) in items.enumerated() { Review.flatten(item, label: "[\(index)]", key: nil, path: [.index(UInt32(index))], marked: marked, depth: 0, into: &rows) }
        case let value?:
            Review.flatten(value, label: nil, key: nil, path: [], marked: marked, depth: 0, into: &rows)
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

    private static func isPictureKey(_ key: String) -> Bool {
        var name = key.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
        if name.hasSuffix("s") { name.removeLast() }
        return ["image", "imageurl", "imageuri", "picture", "pictureurl", "photo", "photourl"].contains { name.hasSuffix($0) }
    }

    private static func isLink(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://")
    }

    private static func pictureLinks(in text: String) -> [String] {
        var links: [String] = []
        for match in text.matches(of: #/(?i)https?:\/\/[^\s<>"'\u{201C}\u{201D}\u{2018}\u{2019}]+/#) {
            var link = String(match.output)
            while let last = link.last, ".,;:!?)]}".contains(last) { link.removeLast() }
            guard let path = URL(string: link, encodingInvalidCharacters: false)?.path().lowercased(),
                  [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".svg"].contains(where: { path.hasSuffix($0) }),
                  !links.contains(link) else { continue }
            links.append(link)
        }
        return links
    }

    private static func flatten(_ value: ArgumentValue, label: String?, key: String?, path: [PathElement], marked: Set<[PathElement]>, depth: Int, into rows: inout [ArgumentRow]) {
        let highlighted = marked.contains(path)
        switch value {
        case .object(let members) where !members.isEmpty:
            rows.append(ArgumentRow(id: rows.count, depth: depth, label: label, leaf: nil, container: .object(members.count), highlighted: highlighted, picture: nil))
            for member in members { flatten(member.value, label: member.key, key: member.key, path: path + [.key(member.key)], marked: marked, depth: depth + 1, into: &rows) }
        case .array(let items) where !items.isEmpty:
            rows.append(ArgumentRow(id: rows.count, depth: depth, label: label, leaf: nil, container: .array(items.count), highlighted: highlighted, picture: nil))
            for (index, item) in items.enumerated() { flatten(item, label: "[\(index)]", key: key, path: path + [.index(UInt32(index))], marked: marked, depth: depth + 1, into: &rows) }
        case .string(let text) where key.map(isPictureKey) == true && isLink(text):
            rows.append(ArgumentRow(id: rows.count, depth: depth, label: label, leaf: value, container: nil, highlighted: highlighted, picture: text))
        default:
            rows.append(ArgumentRow(id: rows.count, depth: depth, label: label, leaf: value, container: nil, highlighted: highlighted, picture: nil))
        }
    }
}
