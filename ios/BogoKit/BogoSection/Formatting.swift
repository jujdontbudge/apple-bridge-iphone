import BogoModel
import BogoRelay
import Foundation
import SwiftUI

enum Formatting {
    static func visible(_ value: String, quoted: Bool = false) -> AttributedString {
        var result = AttributedString()
        if quoted { result += mark("“") }
        for segment in VisibleText.segments(value) {
            switch segment {
            case .text(let text):
                result += AttributedString(text)
            case .escape(let label):
                var escape = AttributedString(label)
                escape.foregroundColor = .orange
                escape.font = .caption.monospaced().weight(.semibold)
                result += escape
            }
        }
        if quoted { result += mark("”") }
        return result
    }

    static func value(_ value: ArgumentValue) -> AttributedString {
        switch value {
        case .null: return keyword("null")
        case .bool(let flag): return keyword(flag ? "true" : "false")
        case .number(let text):
            var number = AttributedString(text)
            number.font = .body.monospacedDigit()
            return number
        case .string(let text): return visible(text, quoted: true)
        case .array(let items): return items.isEmpty ? keyword("[ ]") : mark(items.count == 1 ? "1 item" : "\(items.count) items")
        case .object(let members): return members.isEmpty ? keyword("{ }") : mark(members.count == 1 ? "1 field" : "\(members.count) fields")
        }
    }

    static func plain(_ value: ArgumentValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let text): return text
        case .string(let text): return text
        case .array(let items): return "\(items.count) items"
        case .object(let members): return "\(members.count) fields"
        }
    }

    static func asks(_ agent: String) -> AttributedString {
        var name = visible(agent)
        name.foregroundColor = .primary
        name.font = .subheadline.weight(.semibold)
        return name + AttributedString(" wants to run")
    }

    static func via(_ review: Review) -> AttributedString {
        let request = review.request
        guard review.action != nil else { return AttributedString("on ") + visible(request.upstream) }
        return visible(request.tool) + AttributedString(" on ") + visible(request.upstream)
    }

    static func title(_ review: Review) -> String {
        review.action ?? review.request.tool
    }

    static func summary(_ value: ArgumentValue) -> AttributedString {
        switch value {
        case .string(let text) where !text.isEmpty: return visible(text)
        case .bool(let flag): return AttributedString(flag ? "true" : "false")
        case .number(let text): return AttributedString(text)
        default: return self.value(value)
        }
    }

    static func list(_ labels: [String]) -> AttributedString {
        var result = AttributedString()
        for (index, label) in labels.enumerated() {
            if index > 0 { result += AttributedString(", ") }
            result += visible(label)
        }
        return result
    }

    static func fieldNames(_ highlights: [Review.Highlight]) -> [Int: String] {
        let names = highlights.map { highlight -> (Int, String) in
            guard case .key(let key)? = highlight.path.last else { return (highlight.id, highlight.label) }
            return (highlight.id, words(key))
        }
        let counts = Dictionary(grouping: names, by: { $0.1.lowercased() }).mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: names.map { id, name in
            (id, counts[name.lowercased()] == 1 ? name : highlights.first { $0.id == id }?.label ?? name)
        })
    }

    static func words(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in key {
            if character == "_" || character == "-" || character == " " || character == "." {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if character.isUppercase, let previous, previous.isLowercase || previous.isNumber {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return key }
        let joined = words.map { $0.count > 1 && $0 == $0.uppercased() ? $0 : $0.lowercased() }.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    static func row(_ review: Review) -> (headline: AttributedString, detail: AttributedString) {
        let request = review.request
        let agent = visible(request.agentName) + AttributedString(" · ")
        if let money = headline(review) { return (AttributedString(money), agent + visible(title(review))) }
        return (visible(title(review)), agent + visible(review.action == nil ? request.upstream : request.tool))
    }

    static func headline(_ review: Review) -> String? {
        for highlight in review.highlights {
            if case .money(let amount, _) = highlight.value { return amount.formatted }
        }
        return nil
    }

    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func remaining(_ until: Date, now: Date) -> String {
        let seconds = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func ended(_ why: EndReason) -> String {
        switch why {
        case .callEnded: return "The agent stopped waiting"
        case .sessionClosed: return "The agent disconnected"
        case .ownerCancel: return "Cancelled on the Mac"
        case .expired: return "Expired"
        case .agentRevoked: return "The agent was revoked"
        case .approverRevoked: return "This iPhone was revoked"
        case .agentPaused: return "Refused · agent paused"
        case .otherBoot: return "BOGO restarted"
        case .unknown: return "Ended"
        }
    }

    static func outcome(_ outcome: Outcome) -> String {
        switch outcome {
        case .executed: return "Ran on the Mac"
        case .notSent: return "Not sent to the upstream"
        case .denied: return "Denied on the Mac"
        case .ended: return "Ended before it ran"
        case .unknown: return "Outcome unknown"
        case .noRecord: return "No record on the Mac"
        }
    }

    static func status(_ record: RequestRecord, now: UInt64) -> String? {
        switch record.phase {
        case .pending: return record.expired(at: now) ? "Expired" : nil
        case .sent(.approved): return "Approved · sent to the Mac"
        case .sent(.denied): return "Denied"
        case .settled(.approved?): return "Approved"
        case .settled: return "Decided on another approver"
        case .ended(.approved?, let why): return "Ended · " + ended(why)
        case .ended(.denied?, _): return "Denied"
        case .ended(nil, let why): return ended(why)
        case .finished(.approved?, let result) where !approvalStood(result):
            return outcome(result)
        case .finished(let decision, let result):
            let prefix = decision == .approved ? "Approved · " : decision == nil ? "" : "Denied · "
            return prefix + (prefix.isEmpty ? outcome(result) : outcome(result).lowercasedFirst)
        }
    }

    static func approvalStood(_ result: Outcome) -> Bool {
        result == .executed || result == .unknown
    }

    enum Mark {
        case approved, denied, ended, paused
    }

    static func history(_ record: RequestRecord) -> (text: String, mark: Mark) {
        switch record.phase {
        case .pending: return ("Waiting", .ended)
        case .sent(.approved): return ("Approved · sending to the Mac", .approved)
        case .settled(.approved?): return ("Approved", .approved)
        case .finished(.approved?, let result):
            return approvalStood(result) ? ("Approved · " + outcome(result).lowercasedFirst, .approved) : (outcome(result), .ended)
        case .ended(.approved?, let why): return ("Ended · " + ended(why), .ended)
        case .sent(.denied(let note)), .settled(.denied(let note)?), .ended(.denied(let note)?, _), .finished(.denied(let note)?, _):
            return (note.map { "Denied · “\($0)”" } ?? "Denied", .denied)
        case .ended(nil, .agentPaused): return ("Refused while paused", .paused)
        case .ended(nil, let why): return (ended(why), .ended)
        case .settled(nil): return ("Decided on another approver", .ended)
        case .finished(nil, let result): return (outcome(result), .ended)
        }
    }

    private static func keyword(_ text: String) -> AttributedString {
        var word = AttributedString(text)
        word.font = .body.monospaced()
        word.foregroundColor = .secondary
        return word
    }

    private static func mark(_ text: String) -> AttributedString {
        var word = AttributedString(text)
        word.foregroundColor = .secondary
        return word
    }
}

extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

enum BogoPage: String, CaseIterable, Identifiable {
    case inbox, history, macs

    var id: String { rawValue }
    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .history: return "History"
        case .macs: return "Macs"
        }
    }
}
