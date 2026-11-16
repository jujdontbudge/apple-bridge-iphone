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
        public let path: [PathElement]
        public let label: String
        public let value: Highlighted
    }

    public enum Container: Equatable, Sendable {
        case object(Int)
        case array(Int)
    }

    public struct EmptyFold: Equatable, Sendable {
        public let labels: [String]
        public let items: Bool
    }

    public struct ArgumentRow: Identifiable, Equatable, Sendable {
        public let id: Int
        public let depth: Int
        public let label: String?
        public let leaf: ArgumentValue?
        public let container: Container?
        public let highlighted: Bool
        public let picture: String?
        public let fold: EmptyFold?
        public let foldedInto: Int?
    }

    private struct Entry {
        let label: String?
        let key: String?
        let path: [PathElement]
        let value: ArgumentValue
    }

    public let request: ApprovalRequest
    public let highlights: [Highlight]
    public let arguments: [ArgumentRow]?
    public let warnings: [String]
    public let reasonPictures: [String]
    public let action: String?
    public let pictures: [String]

    public init(_ request: ApprovalRequest) {
        self.request = request
        var highlights: [Highlight] = []
        var money: [MoneyAmount] = []
        var unformattable = 0
        for (index, hint) in request.hints.enumerated() {
            let label = Review.label(hint.path)
            guard let value = request.value(at: hint.path) else {
                highlights.append(Highlight(id: index, path: hint.path, label: label, value: .missing))
                continue
            }
            switch hint.format {
            case .text:
                highlights.append(Highlight(id: index, path: hint.path, label: label, value: .text(value)))
            case .moneyMinor(let currency):
                if case .number(let token) = value, let amount = MoneyAmount.minor(token, currency: currency) {
                    money.append(amount)
                    highlights.append(Highlight(id: index, path: hint.path, label: label, value: .money(amount, token: token)))
                } else {
                    unformattable += 1
                    highlights.append(Highlight(id: index, path: hint.path, label: label, value: .unformattable(value, currency: currency)))
                }
            }
        }
        self.highlights = highlights
        self.warnings = MismatchRule.warnings(justification: request.justification, money: money, unformattable: unformattable)
        self.reasonPictures = Review.pictureLinks(in: request.justification ?? "")
        self.action = Review.action(request)
        var rows: [ArgumentRow] = []
        let marked = Set(request.hints.map(\.path))
        if let value = request.arguments {
            if let entries = Review.entries(value, key: nil, path: []), !entries.isEmpty {
                Review.place(entries, items: value.isArray, marked: marked, depth: 0, into: &rows)
            } else {
                Review.flatten(Entry(label: nil, key: nil, path: [], value: value), marked: marked, depth: 0, foldedInto: nil, into: &rows)
            }
        }
        self.arguments = request.arguments == nil ? nil : rows
        var pictures: [String] = []
        for link in rows.compactMap(\.picture) where !pictures.contains(link) { pictures.append(link) }
        self.pictures = pictures
    }

    private static func action(_ request: ApprovalRequest) -> String? {
        guard case .object(let members)? = request.arguments,
              case .string(let name)? = members.first(where: { $0.key.utf8.elementsEqual("name".utf8) })?.value,
              !name.isEmpty else { return nil }
        let leads = request.hints.first.map { $0.path == [.key("name")] && $0.format == .text } ?? false
        return request.tool.hasSuffix("_tool") || leads ? name : nil
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
        for match in text.matches(of: #/(?i)https?:\/\/[^\s<>"'`\u{201C}\u{201D}\u{2018}\u{2019}]+/#) {
            var link = String(match.output)
            while let last = link.last, ".,;:!?)]}".contains(last) { link.removeLast() }
            guard let path = URL(string: link, encodingInvalidCharacters: false)?.path().lowercased(),
                  [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".svg"].contains(where: { path.hasSuffix($0) }),
                  !links.contains(link) else { continue }
            links.append(link)
        }
        return links
    }

    private static func entries(_ value: ArgumentValue, key: String?, path: [PathElement]) -> [Entry]? {
        switch value {
        case .object(let members):
            return members.map { Entry(label: $0.key, key: $0.key, path: path + [.key($0.key)], value: $0.value) }
        case .array(let items):
            return items.enumerated().map { Entry(label: "[\($0.offset)]", key: key, path: path + [.index(UInt32($0.offset))], value: $0.element) }
        default:
            return nil
        }
    }

    private static func place(_ entries: [Entry], items: Bool, marked: Set<[PathElement]>, depth: Int, into rows: inout [ArgumentRow]) {
        let foldable = { (entry: Entry) in entry.value.isEmpty && !marked.contains(entry.path) }
        let empty = entries.filter(foldable)
        guard empty.count > 1 else {
            for entry in entries { flatten(entry, marked: marked, depth: depth, foldedInto: nil, into: &rows) }
            return
        }
        for entry in entries where !foldable(entry) { flatten(entry, marked: marked, depth: depth, foldedInto: nil, into: &rows) }
        let fold = rows.count
        rows.append(ArgumentRow(id: fold, depth: depth, label: nil, leaf: nil, container: nil, highlighted: false, picture: nil,
                                fold: EmptyFold(labels: empty.compactMap(\.label), items: items), foldedInto: nil))
        for entry in empty { flatten(entry, marked: marked, depth: depth, foldedInto: fold, into: &rows) }
    }

    private static func flatten(_ entry: Entry, marked: Set<[PathElement]>, depth: Int, foldedInto: Int?, into rows: inout [ArgumentRow]) {
        let highlighted = marked.contains(entry.path)
        func row(leaf: ArgumentValue?, container: Container?, picture: String?) -> ArgumentRow {
            ArgumentRow(id: rows.count, depth: depth, label: entry.label, leaf: leaf, container: container, highlighted: highlighted,
                        picture: picture, fold: nil, foldedInto: foldedInto)
        }
        switch entry.value {
        case .object(let members) where !members.isEmpty:
            rows.append(row(leaf: nil, container: .object(members.count), picture: nil))
            place(entries(entry.value, key: entry.key, path: entry.path) ?? [], items: false, marked: marked, depth: depth + 1, into: &rows)
        case .array(let items) where !items.isEmpty:
            rows.append(row(leaf: nil, container: .array(items.count), picture: nil))
            place(entries(entry.value, key: entry.key, path: entry.path) ?? [], items: true, marked: marked, depth: depth + 1, into: &rows)
        case .string(let text) where entry.key.map(isPictureKey) == true && isLink(text):
            rows.append(row(leaf: entry.value, container: nil, picture: text))
        default:
            rows.append(row(leaf: entry.value, container: nil, picture: nil))
        }
    }
}

extension ArgumentValue {
    public var isEmpty: Bool {
        switch self {
        case .null: return true
        case .string(let text): return text.isEmpty
        case .array(let items): return items.isEmpty
        case .object(let members): return members.isEmpty
        case .bool, .number: return false
        }
    }

    var isArray: Bool {
        if case .array = self { return true }
        return false
    }
}
