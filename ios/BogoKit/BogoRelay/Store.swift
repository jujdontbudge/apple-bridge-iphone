import BogoModel
import Foundation
import Security
import SQLite3

public enum StoreError: Error {
    case sqlite(String)
}

public struct OutboxRow: Equatable, Sendable {
    public let msgID: Data
    public let bogoID: Data
    public let message: PhoneMessage
    public let createdMs: UInt64
    public let sentMs: UInt64?
    public let envelope: Data?
}

@MainActor
public final class Store {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL) throws {
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        try? FileManager.default.setAttributes(protection, ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("bogo.sqlite")
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION, nil) == SQLITE_OK else {
            throw StoreError.sqlite("open")
        }
        try FileManager.default.setAttributes(protection, ofItemAtPath: file.path)
        try execute("PRAGMA journal_mode=DELETE")
        try execute("PRAGMA synchronous=FULL")
        try execute("""
        CREATE TABLE IF NOT EXISTS macs (bogo_id BLOB PRIMARY KEY, name TEXT NOT NULL, key_account TEXT NOT NULL, public_key BLOB NOT NULL,
          approver_id BLOB, biometry BLOB, state TEXT NOT NULL, added_ms INTEGER NOT NULL, boot_seq INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS records (bogo_id BLOB NOT NULL, req_id BLOB NOT NULL, bytes BLOB NOT NULL, boot_seq INTEGER NOT NULL,
          pause_epoch INTEGER NOT NULL, arm_delay_ms INTEGER NOT NULL, received_ms INTEGER NOT NULL, phase TEXT NOT NULL, decision TEXT,
          note TEXT, detail TEXT, changed_ms INTEGER NOT NULL, PRIMARY KEY (bogo_id, req_id));
        CREATE TABLE IF NOT EXISTS outbox (msg_id BLOB PRIMARY KEY, bogo_id BLOB NOT NULL, kind TEXT NOT NULL, req_id BLOB, body BLOB NOT NULL,
          created_ms INTEGER NOT NULL, sent_ms INTEGER);
        CREATE TABLE IF NOT EXISTS pauses (bogo_id BLOB NOT NULL, agent_id BLOB NOT NULL, epoch INTEGER NOT NULL, paused_ms INTEGER NOT NULL,
          PRIMARY KEY (bogo_id, agent_id));
        CREATE TABLE IF NOT EXISTS inbound (bogo_id BLOB NOT NULL, msg_id BLOB NOT NULL, applied_ms INTEGER NOT NULL, PRIMARY KEY (bogo_id, msg_id));
        """)
        try addColumns("macs", ["mac_e2e BLOB", "mac_mailbox TEXT", "tx_id BLOB", "channel_account TEXT", "push_token BLOB"])
        try addColumns("outbox", ["envelope BLOB"])
    }

    private func addColumns(_ table: String, _ columns: [String]) throws {
        let existing = Set(try query("PRAGMA table_info(\(table))") { $0.text(1) })
        for column in columns where !existing.contains(String(column.split(separator: " ")[0])) {
            try execute("ALTER TABLE \(table) ADD COLUMN \(column)")
        }
    }

    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func macs() throws -> [MacRecord] {
        try query("""
        SELECT bogo_id, name, key_account, public_key, approver_id, biometry, state, added_ms, boot_seq, mac_e2e, mac_mailbox, tx_id, channel_account, push_token
        FROM macs ORDER BY added_ms
        """) { row in
            var route: MacRoute?
            if let macE2E = row.optionalData(9), let mailbox = row.optionalText(10), let txID = row.optionalData(11), let account = row.optionalText(12) {
                route = MacRoute(macE2E: macE2E, macMailbox: mailbox, txID: txID, channelAccount: account)
            }
            return MacRecord(bogoID: row.data(0), name: row.text(1), keyAccount: row.text(2), approvalPublicKey: row.data(3), approverID: row.optionalData(4),
                             biometryState: row.optionalData(5), state: MacState(rawValue: row.text(6)) ?? .removed, addedMs: row.u64(7), bootSeq: row.u64(8),
                             route: route, pushToken: row.optionalData(13))
        }
    }

    public func save(_ mac: MacRecord) throws {
        try run("""
        INSERT OR REPLACE INTO macs (bogo_id, name, key_account, public_key, approver_id, biometry, state, added_ms, boot_seq,
          mac_e2e, mac_mailbox, tx_id, channel_account, push_token) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [.data(mac.bogoID), .text(mac.name), .text(mac.keyAccount), .data(mac.approvalPublicKey),
            mac.approverID.map(Value.data) ?? .null, mac.biometryState.map(Value.data) ?? .null, .text(mac.state.rawValue), .int(mac.addedMs), .int(mac.bootSeq),
            mac.route.map { .data($0.macE2E) } ?? .null, mac.route.map { .text($0.macMailbox) } ?? .null, mac.route.map { .data($0.txID) } ?? .null,
            mac.route.map { .text($0.channelAccount) } ?? .null, mac.pushToken.map(Value.data) ?? .null])
    }

    public func applied(bogoID: Data, msgID: Data) -> Bool {
        ((try? query("SELECT 1 FROM inbound WHERE bogo_id = ? AND msg_id = ?", [.data(bogoID), .data(msgID)]) { _ in true }) ?? []).isEmpty == false
    }

    public func markApplied(bogoID: Data, msgID: Data, nowMs: UInt64) throws {
        try run("INSERT OR IGNORE INTO inbound VALUES (?, ?, ?)", [.data(bogoID), .data(msgID), .int(nowMs)])
    }

    public func deleteMac(_ bogoID: Data) throws {
        try run("DELETE FROM inbound WHERE bogo_id = ?", [.data(bogoID)])
        try run("DELETE FROM macs WHERE bogo_id = ?", [.data(bogoID)])
        try run("DELETE FROM pauses WHERE bogo_id = ?", [.data(bogoID)])
        try run("DELETE FROM records WHERE bogo_id = ?", [.data(bogoID)])
        try run("DELETE FROM outbox WHERE bogo_id = ?", [.data(bogoID)])
    }

    public func records() throws -> [RequestRecord] {
        try query("SELECT bogo_id, req_id, bytes, boot_seq, pause_epoch, arm_delay_ms, received_ms, phase, decision, note, detail, changed_ms FROM records") { row in
            RequestRecord(bogoID: row.data(0), reqID: row.data(1), bytes: row.data(2), bootSeq: row.u64(3), pauseEpoch: row.u64(4), armDelayMs: row.u64(5),
                          receivedMs: row.u64(6), phase: Store.phase(row.text(7), decision: row.optionalText(8), note: row.optionalText(9), detail: row.optionalText(10)),
                          changedMs: row.u64(11))
        }
    }

    public func save(_ record: RequestRecord) throws {
        let (phase, decision, note, detail) = Store.columns(record.phase)
        try run("INSERT OR REPLACE INTO records VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [.data(record.bogoID), .data(record.reqID), .data(record.bytes),
            .int(record.bootSeq), .int(record.pauseEpoch), .int(record.armDelayMs), .int(record.receivedMs), .text(phase), decision.map(Value.text) ?? .null,
            note.map(Value.text) ?? .null, detail.map(Value.text) ?? .null, .int(record.changedMs)])
    }

    public func enqueue(_ message: PhoneMessage, to bogoID: Data, nowMs: UInt64) throws {
        if case .regResend = message,
           !((try? query("SELECT 1 FROM outbox WHERE bogo_id = ? AND kind = 'regResend' AND sent_ms IS NULL", [.data(bogoID)]) { _ in true }) ?? []).isEmpty {
            return
        }
        if case .sync = message {
            try run("DELETE FROM outbox WHERE bogo_id = ? AND kind = 'sync' AND body = ? AND sent_ms IS NULL", [.data(bogoID), .data(message.body)])
        }
        var msgID = Data(count: 16)
        _ = msgID.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        try run("INSERT INTO outbox (msg_id, bogo_id, kind, req_id, body, created_ms, sent_ms) VALUES (?, ?, ?, ?, ?, ?, NULL)", [.data(msgID), .data(bogoID), .text(message.kind), message.reqID.map(Value.data) ?? .null,
            .data(message.body), .int(nowMs)])
    }

    public func outbox() throws -> [OutboxRow] {
        try query("SELECT msg_id, bogo_id, body, created_ms, sent_ms, envelope FROM outbox ORDER BY created_ms, rowid") { row in
            OutboxRow(msgID: row.data(0), bogoID: row.data(1), message: PhoneMessage(body: row.data(2)) ?? .removed, createdMs: row.u64(3), sentMs: row.optionalU64(4),
                      envelope: row.optionalData(5))
        }
    }

    public func saveEnvelope(_ msgID: Data, _ envelope: Data) throws {
        try run("UPDATE outbox SET envelope = ? WHERE msg_id = ? AND envelope IS NULL", [.data(envelope), .data(msgID)])
    }

    public func markSent(_ msgID: Data, nowMs: UInt64) throws {
        try run("UPDATE outbox SET sent_ms = ? WHERE msg_id = ?", [.int(nowMs), .data(msgID)])
    }

    public func markUnsent(reqID: Data) throws {
        try run("UPDATE outbox SET sent_ms = NULL WHERE req_id = ? AND kind IN ('approval', 'denial')", [.data(reqID)])
    }

    public func pauses() throws -> [Data: UInt64] {
        var result: [Data: UInt64] = [:]
        let rows = try query("SELECT bogo_id, agent_id, epoch FROM pauses", []) { ($0.data(0) + $0.data(1), $0.u64(2)) }
        for (key, epoch) in rows { result[key] = epoch }
        return result
    }

    public func savePause(bogoID: Data, agentID: Data, epoch: UInt64, nowMs: UInt64) throws {
        try run("INSERT OR REPLACE INTO pauses VALUES (?, ?, ?, ?)", [.data(bogoID), .data(agentID), .int(epoch), .int(nowMs)])
    }

    static func columns(_ phase: RequestPhase) -> (String, String?, String?, String?) {
        func decision(_ value: Decision?) -> (String?, String?) {
            switch value {
            case .approved?: return ("approved", nil)
            case .denied(let note)?: return ("denied", note)
            case nil: return (nil, nil)
            }
        }
        switch phase {
        case .pending: return ("pending", nil, nil, nil)
        case .sent(let value): let (d, n) = decision(value); return ("sent", d, n, nil)
        case .settled(let value): let (d, n) = decision(value); return ("settled", d, n, nil)
        case .ended(let value, let why): let (d, n) = decision(value); return ("ended", d, n, why.rawValue)
        case .finished(let value, let outcome): let (d, n) = decision(value); return ("finished", d, n, outcome.rawValue)
        }
    }

    static func phase(_ phase: String, decision: String?, note: String?, detail: String?) -> RequestPhase {
        let value: Decision? = decision == "approved" ? .approved : decision == "denied" ? .denied(note: note) : nil
        switch phase {
        case "pending": return .pending
        case "sent": return value.map(RequestPhase.sent) ?? .pending
        case "settled": return .settled(value)
        case "ended": return .ended(value, EndReason(rawValue: detail ?? "") ?? .unknown)
        default: return .finished(value, Outcome(rawValue: detail ?? "") ?? .unknown)
        }
    }

    enum Value {
        case data(Data)
        case text(String)
        case int(UInt64)
        case null
    }

    struct Row {
        let statement: OpaquePointer

        func data(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }

        func optionalData(_ column: Int32) -> Data? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : data(column)
        }

        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        func optionalText(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(column)
        }

        func u64(_ column: Int32) -> UInt64 {
            UInt64(bitPattern: sqlite3_column_int64(statement, column))
        }

        func optionalU64(_ column: Int32) -> UInt64? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : u64(column)
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .data(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(data.count), transient) }
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            case .int(let number): sqlite3_bind_int64(statement, position, Int64(bitPattern: number))
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func query<T>(_ sql: String, _ values: [Value] = [], _ map: (Row) -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            result.append(map(Row(statement: statement)))
        }
        return result
    }
}
