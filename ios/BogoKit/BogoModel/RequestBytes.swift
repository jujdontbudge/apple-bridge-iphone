import Foundation

public enum RequestBytes {
    public static let magic: [UInt8] = Array("BOGOREQ".utf8) + [0]
    public static let version = 1
    public static let approvalDomain = Data("BOGO-APPROVAL".utf8) + Data([0]) + Data("v1".utf8)
    public static let depthLimit = 128

    public static func signedMessage(_ bytes: Data) -> Data {
        approvalDomain + bytes
    }

    public static func decode(_ bytes: Data) -> ApprovalRequest? {
        var reader = RequestReader(Array(bytes))
        return try? reader.request()
    }

    public static func decodeValue(_ bytes: Data) -> ArgumentValue? {
        var reader = RequestReader(Array(bytes))
        guard let value = try? reader.value(depth: 0), reader.atEnd else { return nil }
        return value
    }
}

struct Unreadable: Error {}

struct RequestReader {
    private let input: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.input = bytes
    }

    var atEnd: Bool { offset == input.count }

    mutating func request() throws -> ApprovalRequest {
        guard try take(8) == RequestBytes.magic[...], try u16() == RequestBytes.version else { throw Unreadable() }
        let identity = offset
        let bogoID = try field(1) { try $0.bytes() }
        let callStart = offset
        let upstream = try field(2) { try $0.string() }
        let tool = try field(3) { try $0.string() }
        let arguments = try field(4) { try $0.optional { try $0.value(depth: 0) } }
        let justification = try field(5) { try $0.optional { try $0.string() } }
        let callEnd = offset
        let hints = try field(6) { try $0.list { try $0.hint() } }
        let agentStart = offset
        let agentID = try field(7) { try $0.bytes() }
        let agentEnd = offset
        let agentName = try field(8) { try $0.string() }
        let clientName = try field(9) { try $0.optional { try $0.string() } }
        let session = try field(10) { try $0.bytes() }
        let nonce = try field(11) { try $0.bytes() }
        let createdMs = try field(12) { try $0.u64() }
        let expiresMs = try field(13) { try $0.optional { try $0.u64() } }
        guard atEnd else { throw Unreadable() }
        let groupKey = Data(input[identity..<callStart]) + Data(input[agentStart..<agentEnd]) + Data(input[callStart..<callEnd])
        return ApprovalRequest(bogoID: bogoID, upstream: upstream, tool: tool, arguments: arguments, justification: justification,
                               hints: hints, agentID: agentID, agentName: agentName, clientName: clientName, session: session,
                               nonce: nonce, createdMs: createdMs, expiresMs: expiresMs, groupKey: groupKey)
    }

    mutating func value(depth: Int) throws -> ArgumentValue {
        guard depth < RequestBytes.depthLimit else { throw Unreadable() }
        switch try u8() {
        case 0: return .null
        case 1: return .bool(false)
        case 2: return .bool(true)
        case 3:
            let text = try string()
            guard JSONNumber.isValid(Array(text.utf8)) else { throw Unreadable() }
            return .number(text)
        case 4: return .string(try string())
        case 5:
            let count = try u32()
            var items: [ArgumentValue] = []
            for _ in 0..<count { items.append(try value(depth: depth + 1)) }
            return .array(items)
        case 6:
            let count = try u32()
            var members: [ArgumentMember] = []
            for _ in 0..<count {
                let key = try string()
                if let previous = members.last, !previous.key.utf8.lexicographicallyPrecedes(key.utf8) { throw Unreadable() }
                members.append(ArgumentMember(key: key, value: try value(depth: depth + 1)))
            }
            return .object(members)
        default:
            throw Unreadable()
        }
    }

    private mutating func hint() throws -> DisplayHint {
        let path: [PathElement] = try list {
            switch try $0.u8() {
            case 0: return .key(try $0.string())
            case 1: return .index(try $0.u32())
            default: throw Unreadable()
            }
        }
        switch try u8() {
        case 0: return DisplayHint(path: path, format: .text)
        case 1: return DisplayHint(path: path, format: .moneyMinor(try string()))
        default: throw Unreadable()
        }
    }

    private mutating func field<T>(_ tag: UInt8, _ read: (inout RequestReader) throws -> T) throws -> T {
        guard try u8() == tag else { throw Unreadable() }
        return try read(&self)
    }

    private mutating func optional<T>(_ read: (inout RequestReader) throws -> T) throws -> T? {
        switch try u8() {
        case 0: return nil
        case 1: return try read(&self)
        default: throw Unreadable()
        }
    }

    private mutating func list<T>(_ read: (inout RequestReader) throws -> T) throws -> [T] {
        let count = try u32()
        var items: [T] = []
        for _ in 0..<count { items.append(try read(&self)) }
        return items
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count <= input.count - offset else { throw Unreadable() }
        defer { offset += count }
        return input[offset..<offset + count]
    }

    private mutating func u8() throws -> UInt8 {
        try take(1).first!
    }

    private mutating func u16() throws -> Int {
        try take(2).reduce(0) { $0 << 8 | Int($1) }
    }

    private mutating func u32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private mutating func u64() throws -> UInt64 {
        try take(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    private mutating func bytes() throws -> Data {
        Data(try take(Int(try u32())))
    }

    private mutating func string() throws -> String {
        let raw = try take(Int(try u32()))
        guard let text = String(validating: raw, as: UTF8.self) else { throw Unreadable() }
        return text
    }
}

enum JSONNumber {
    static func isValid(_ text: [UInt8]) -> Bool {
        var index = 0
        func digits() -> Int {
            let start = index
            while index < text.count, (48...57).contains(text[index]) { index += 1 }
            return index - start
        }
        if index < text.count, text[index] == 45 { index += 1 }
        guard index < text.count else { return false }
        if text[index] == 48 { index += 1 }
        else if (49...57).contains(text[index]) { _ = digits() }
        else { return false }
        if index < text.count, text[index] == 46 {
            index += 1
            guard digits() > 0 else { return false }
        }
        if index < text.count, text[index] == 101 || text[index] == 69 {
            index += 1
            if index < text.count, text[index] == 43 || text[index] == 45 { index += 1 }
            guard digits() > 0 else { return false }
        }
        return index == text.count
    }
}
