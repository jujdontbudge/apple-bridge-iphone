import Foundation

public enum ArgumentValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([ArgumentValue])
    case object([ArgumentMember])
}

public struct ArgumentMember: Equatable, Sendable {
    public let key: String
    public let value: ArgumentValue
}

public enum PathElement: Equatable, Hashable, Sendable {
    case key(String)
    case index(UInt32)
}

public enum DisplayFormat: Equatable, Sendable {
    case text
    case moneyMinor(String)
}

public struct DisplayHint: Equatable, Sendable {
    public let path: [PathElement]
    public let format: DisplayFormat
}

public struct ApprovalRequest: Equatable, Sendable {
    public let bogoID: Data
    public let upstream: String
    public let tool: String
    public let arguments: ArgumentValue?
    public let justification: String?
    public let hints: [DisplayHint]
    public let agentID: Data
    public let agentName: String
    public let clientName: String?
    public let session: Data
    public let nonce: Data
    public let createdMs: UInt64
    public let expiresMs: UInt64?
    public let groupKey: Data

    public var sessionTag: String {
        let random = session.count > 32 ? session.dropFirst(32) : session[...]
        return Hex.string(Data(random.prefix(4)))
    }

    public var expires: Date? {
        expiresMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    public var created: Date {
        Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000)
    }

    public func value(at path: [PathElement]) -> ArgumentValue? {
        var current = arguments
        for element in path {
            switch (element, current) {
            case (.key(let key), .object(let members)?):
                current = members.first { $0.key == key }?.value
            case (.index(let index), .array(let items)?):
                current = Int(index) < items.count ? items[Int(index)] : nil
            default:
                return nil
            }
        }
        return current
    }
}

public enum Hex {
    public static func string(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func data(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var result = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 97...102: return byte - 87
        case 65...70: return byte - 55
        default: return nil
        }
    }
}
