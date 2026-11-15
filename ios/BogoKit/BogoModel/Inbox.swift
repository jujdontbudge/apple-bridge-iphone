import Foundation

public enum Decision: Equatable, Sendable {
    case approved
    case denied(note: String?)
}

public enum EndReason: String, Sendable, CaseIterable {
    case callEnded, sessionClosed, ownerCancel, expired, agentRevoked, approverRevoked, agentPaused, otherBoot, unknown
}

public enum Outcome: String, Sendable, CaseIterable {
    case executed, notSent, denied, ended, unknown, noRecord
}

public enum RequestPhase: Equatable, Sendable {
    case pending
    case sent(Decision)
    case settled(Decision?)
    case ended(Decision?, EndReason)
    case finished(Decision?, Outcome)

    public var decision: Decision? {
        switch self {
        case .pending: return nil
        case .sent(let decision): return decision
        case .settled(let decision), .ended(let decision, _), .finished(let decision, _): return decision
        }
    }

    public var isPending: Bool { self == .pending }
}

public enum RequestEvent: Equatable, Sendable {
    case decided(Decision)
    case settled
    case ended(EndReason)
    case outcome(Outcome)
}

extension RequestPhase {
    public func applying(_ event: RequestEvent) -> RequestPhase {
        switch (self, event) {
        case (.pending, .decided(let decision)): return .sent(decision)
        case (.pending, .settled): return .settled(nil)
        case (.sent(let decision), .settled): return .settled(decision)
        case (.pending, .ended(let why)): return .ended(nil, why)
        case (.sent(let decision), .ended(let why)): return .ended(decision, why)
        case (.settled(let decision), .ended(let why)): return .ended(decision, why)
        case (.finished, _): return self
        case (_, .outcome(let outcome)): return .finished(decision, outcome)
        default: return self
        }
    }
}

public struct RequestRecord: Identifiable, Equatable, Sendable {
    public let bogoID: Data
    public let reqID: Data
    public let bytes: Data
    public let bootSeq: UInt64
    public let pauseEpoch: UInt64
    public let armDelayMs: UInt64
    public let receivedMs: UInt64
    public var phase: RequestPhase
    public var changedMs: UInt64
    public let request: ApprovalRequest?

    public init(bogoID: Data, reqID: Data, bytes: Data, bootSeq: UInt64, pauseEpoch: UInt64, armDelayMs: UInt64, receivedMs: UInt64, phase: RequestPhase, changedMs: UInt64) {
        self.bogoID = bogoID
        self.reqID = reqID
        self.bytes = bytes
        self.bootSeq = bootSeq
        self.pauseEpoch = pauseEpoch
        self.armDelayMs = armDelayMs
        self.receivedMs = receivedMs
        self.phase = phase
        self.changedMs = changedMs
        let decoded = RequestBytes.decode(bytes)
        self.request = decoded?.bogoID == bogoID && decoded?.nonce == reqID ? decoded : nil
    }

    public var id: String { Hex.string(bogoID) + ":" + Hex.string(reqID) }

    public func expired(at nowMs: UInt64) -> Bool {
        guard let expiresMs = request?.expiresMs else { return false }
        return nowMs >= expiresMs
    }

    public func approvable(at nowMs: UInt64) -> Bool {
        phase.isPending && request != nil && !expired(at: nowMs)
    }

    public func deniable(at nowMs: UInt64) -> Bool {
        phase.isPending && !expired(at: nowMs)
    }
}

public struct InboxEntry: Identifiable, Equatable, Sendable {
    public let records: [RequestRecord]
    public let live: Bool

    public var primary: RequestRecord { records[0] }
    public var count: Int { records.count }
    public var id: String { primary.id }
}

public enum Inbox {
    public static let endedShownMs: UInt64 = 86_400_000

    public static func entries(_ records: [RequestRecord], now nowMs: UInt64) -> [InboxEntry] {
        var groups: [Data: [RequestRecord]] = [:]
        var order: [Data] = []
        var single: [InboxEntry] = []
        var greyed: [InboxEntry] = []
        for record in records where record.phase.decision == nil {
            if record.deniable(at: nowMs) {
                if let request = record.request {
                    let key = record.bogoID + request.groupKey
                    if groups[key] == nil { order.append(key) }
                    groups[key, default: []].append(record)
                } else {
                    single.append(InboxEntry(records: [record], live: true))
                }
            } else if record.changedMs + endedShownMs > nowMs || record.phase.isPending {
                greyed.append(InboxEntry(records: [record], live: false))
            }
        }
        let live = order.compactMap { groups[$0] }.map { members in
            InboxEntry(records: members.sorted { $0.receivedMs < $1.receivedMs }, live: true)
        } + single
        return live.sorted { newest($0) > newest($1) } + greyed.sorted { $0.primary.changedMs > $1.primary.changedMs }
    }

    public static func history(_ records: [RequestRecord]) -> [RequestRecord] {
        records.filter { record in
            if record.phase.decision != nil { return true }
            if case .ended(nil, .agentPaused) = record.phase { return true }
            return false
        }.sorted { $0.changedMs > $1.changedMs }
    }

    private static func newest(_ entry: InboxEntry) -> UInt64 {
        entry.records.map(\.receivedMs).max() ?? 0
    }
}
