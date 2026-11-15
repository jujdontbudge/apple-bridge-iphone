import BogoCrypto
import BogoModel
import CryptoKit
import Foundation
import Observation

public enum DecisionResult: Equatable, Sendable {
    case decided
    case nothingSigned(String?)
}

@MainActor
@Observable
public final class PhoneApprover {
    public private(set) var macs: [MacRecord] = []
    public private(set) var records: [RequestRecord] = []
    public private(set) var pauses: [Data: UInt64] = [:]
    public private(set) var storeFailure = false
    public var pushToken: Data? {
        didSet { if pushToken != oldValue { sendPushToken() } }
    }
    public var pushEnvironment = "production"

    @ObservationIgnored private let store: Store?
    @ObservationIgnored public let link: MacLink
    @ObservationIgnored private let clock: () -> UInt64
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var flushAgain = false
    @ObservationIgnored private var retry: Task<Void, Never>?

    public init(directory: URL, link: MacLink, clock: @escaping () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }) {
        self.store = try? Store(directory: directory)
        self.link = link
        self.clock = clock
        storeFailure = store == nil
        reload()
        link.receive = { [weak self] bogoID, msgID, message in self?.receive(bogoID, msgID: msgID, message) ?? false }
        link.applied = { [weak self] bogoID, msgID in self?.store?.applied(bogoID: bogoID, msgID: msgID) ?? false }
        link.start(macs: macs)
    }

    public var nowMs: UInt64 { clock() }

    public var shown: [RequestRecord] { records.filter { $0.receivedMs > 0 } }

    public func mac(_ bogoID: Data) -> MacRecord? {
        macs.first { $0.bogoID == bogoID }
    }

    public func record(_ id: String) -> RequestRecord? {
        records.first { $0.id == id && $0.receivedMs > 0 }
    }

    public func record(bogoPrefix: String, reqID: String) -> RequestRecord? {
        records.first { $0.receivedMs > 0 && Hex.string($0.reqID) == reqID && Hex.string($0.bogoID).hasPrefix(bogoPrefix) }
    }

    public func isPaused(_ record: RequestRecord) -> Bool {
        guard let agent = record.request?.agentID else { return false }
        return pauses[record.bogoID + agent] == record.pauseEpoch
    }

    @discardableResult
    public func receive(_ bogoID: Data, msgID: Data?, _ message: MacMessage) -> Bool {
        guard let store else { return false }
        guard var mac = mac(bogoID) else { return true }
        if let msgID, store.applied(bogoID: bogoID, msgID: msgID) { return true }
        let now = clock()
        var relink = false
        do {
            if mac.state == .waiting {
                guard case .registered(let txID, let approverID) = message else { return false }
                try store.transaction {
                    if mac.route?.txID == txID, mac.approverID == approverID {
                        mac.state = .active
                        try store.save(mac)
                        relink = true
                    }
                    if let msgID { try store.markApplied(bogoID: bogoID, msgID: msgID, nowMs: now) }
                }
            } else if case .revokedAck = message, mac.state == .removed {
                try store.deleteMac(bogoID)
                relink = true
            } else {
                try store.transaction {
                    try apply(message, to: &mac, now: now)
                    if let msgID { try store.markApplied(bogoID: bogoID, msgID: msgID, nowMs: now) }
                }
            }
        } catch {
            storeFailure = true
            reload()
            return false
        }
        reload()
        if relink { link.start(macs: macs) }
        Task { await flush() }
        return true
    }

    private func apply(_ message: MacMessage, to mac: inout MacRecord, now: UInt64) throws {
        guard let store else { return }
        let bogoID = mac.bogoID
        switch message {
        case .request(let reqID, let bootSeq, let bytes, let pauseEpoch, let armDelayMs):
            guard mac.state != .removed else { return }
            let existing = records.first { $0.bogoID == bogoID && $0.reqID == reqID }
            if existing == nil || existing?.receivedMs == 0 {
                var record = RequestRecord(bogoID: bogoID, reqID: reqID, bytes: bytes, bootSeq: bootSeq, pauseEpoch: pauseEpoch, armDelayMs: armDelayMs,
                                           receivedMs: now, phase: existing?.phase ?? .pending, changedMs: now)
                if record.phase.isPending, bootSeq < mac.bootSeq { record.phase = .ended(nil, .otherBoot) }
                if record.phase.isPending, isPaused(record) { record.phase = .ended(nil, .agentPaused) }
                try store.save(record)
            }
            try store.enqueue(.seen(reqID: reqID), to: bogoID, nowMs: now)
        case .settled(let reqID):
            try apply(.settled, to: reqID, at: bogoID, now: now)
        case .ended(let reqID, let why):
            try apply(.ended(why), to: reqID, at: bogoID, now: now)
        case .outcome(let reqID, let outcome?):
            try apply(.outcome(outcome), to: reqID, at: bogoID, now: now)
        case .outcome, .registered, .revokedAck:
            break
        case .boot(let bootSeq, _):
            guard bootSeq > mac.bootSeq else { return }
            for var record in records where record.bogoID == bogoID && record.bootSeq < bootSeq && record.phase.isPending && record.receivedMs > 0 {
                record.phase = .ended(nil, .otherBoot)
                record.changedMs = now
                try store.save(record)
            }
            mac.bootSeq = bootSeq
            try store.save(mac)
            let open = records.filter { $0.bogoID == bogoID && $0.phase.decision != nil && !Self.final($0.phase) }.map(\.reqID)
            if !open.isEmpty { try store.enqueue(.sync(reqIDs: open), to: bogoID, nowMs: now) }
        }
    }

    public func approve(_ record: RequestRecord) async -> DecisionResult {
        guard let mac = mac(record.bogoID), mac.state == .active, let request = record.request, record.approvable(at: clock()), !isPaused(record) else {
            return .nothingSigned("This request can no longer be approved.")
        }
        let signature: Data
        do {
            signature = try await ApprovalKey.sign(account: mac.keyAccount, reason: "Approve \(request.tool) for \(request.agentName)",
                                                   message: RequestBytes.signedMessage(record.bytes))
        } catch ApprovalKeyError.invalidated {
            markNeedsReRegistration(mac)
            return .nothingSigned("Face ID changed, so this Mac must be added again. Nothing was approved.")
        } catch ApprovalKeyError.cancelled {
            return .nothingSigned(nil)
        } catch ApprovalKeyError.notRecognized {
            return .nothingSigned("Face ID didn’t match. Nothing was approved.")
        } catch {
            return .nothingSigned("Face ID isn’t available. Nothing was approved.")
        }
        guard let current = self.record(record.id), current.approvable(at: clock()), !isPaused(current) else {
            return .nothingSigned("This request ended before you approved it. Nothing was sent.")
        }
        return decide(current, .approved, message: .approval(reqID: current.reqID, alg: ApprovalKey.algorithm, sig: signature))
    }

    public func deny(_ record: RequestRecord, note: String?) -> DecisionResult {
        guard let current = self.record(record.id), current.deniable(at: clock()) else { return .nothingSigned("This request has already ended.") }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = trimmed?.isEmpty == false ? trimmed : nil
        return decide(current, .denied(note: kept), message: .denial(reqID: current.reqID, note: kept))
    }

    public func pause(_ record: RequestRecord) {
        guard let store, let agent = record.request?.agentID else { return }
        let now = clock()
        do {
            try store.transaction {
                try store.savePause(bogoID: record.bogoID, agentID: agent, epoch: record.pauseEpoch, nowMs: now)
                for var other in records where other.bogoID == record.bogoID && other.request?.agentID == agent && other.phase.isPending && other.receivedMs > 0 {
                    other.phase = .ended(nil, .agentPaused)
                    other.changedMs = now
                    try store.save(other)
                }
                try store.enqueue(.pause(agentID: agent, epoch: record.pauseEpoch), to: record.bogoID, nowMs: now)
            }
        } catch {
            storeFailure = true
        }
        reload()
        Task { await flush() }
    }

    public func remove(_ mac: MacRecord) {
        guard let store else { return }
        ApprovalKey.delete(account: mac.keyAccount)
        var removed = mac
        removed.state = .removed
        let now = clock()
        do {
            try store.transaction {
                try store.save(removed)
                for var record in records where record.bogoID == mac.bogoID && record.phase.isPending && record.receivedMs > 0 {
                    record.phase = .ended(nil, .approverRevoked)
                    record.changedMs = now
                    try store.save(record)
                }
                try store.enqueue(.removed, to: mac.bogoID, nowMs: clock())
            }
        } catch {
            storeFailure = true
        }
        reload()
        Task { await flush() }
    }

    public func checkBiometry() {
        let current = ApprovalKey.biometryState()
        for mac in macs where mac.state == .active && mac.biometryState != nil && mac.biometryState != current {
            markNeedsReRegistration(mac)
        }
    }

    public func becameActive() async {
        checkBiometry()
        if let store {
            let waiting = records.filter { Self.awaitingOutcome($0.phase) }
            for record in waiting { try? store.markUnsent(reqID: record.reqID) }
            for mac in macs where mac.state == .active {
                let open = waiting.filter { $0.bogoID == mac.bogoID }.map(\.reqID)
                if !open.isEmpty { try? store.enqueue(.sync(reqIDs: open), to: mac.bogoID, nowMs: clock()) }
            }
            for mac in macs where mac.state == .waiting {
                if let txID = mac.route?.txID { try? store.enqueue(.regResend(txID: txID), to: mac.bogoID, nowMs: clock()) }
            }
        }
        await link.fetch()
        await flush()
    }

    public func outbox() -> [OutboxRow] {
        (try? store?.outbox()) ?? []
    }

    public func flush() async {
        guard let store else { return }
        guard !flushing else { flushAgain = true; return }
        flushing = true
        defer {
            flushing = false
            if flushAgain {
                flushAgain = false
                Task { await flush() }
            }
        }
        if let pending = try? store.outbox() {
            let resent = Set(pending.filter { $0.sentMs == nil && $0.envelope != nil }.compactMap(\.message.reqID))
            for mac in macs where mac.state == .active {
                let open = records.filter { $0.bogoID == mac.bogoID && resent.contains($0.reqID) && Self.awaitingOutcome($0.phase) }.map(\.reqID)
                if !open.isEmpty { try? store.enqueue(.sync(reqIDs: open), to: mac.bogoID, nowMs: clock()) }
            }
        }
        guard let rows = try? store.outbox() else { return }
        var failed = false
        for row in rows where row.sentMs == nil {
            guard let mac = mac(row.bogoID) else { continue }
            do {
                let sealed: Data
                if let envelope = row.envelope {
                    sealed = envelope
                } else {
                    sealed = try link.seal(row.message, msgID: row.msgID, for: mac)
                    try store.saveEnvelope(row.msgID, sealed)
                }
                try await link.send(row.message, sealed: sealed, msgID: row.msgID, to: mac)
                try store.markSent(row.msgID, nowMs: clock())
            } catch {
                failed = true
            }
        }
        if failed && retry == nil {
            retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.retry = nil
                await self?.flush()
            }
        }
    }

    public func beginRegistration(_ offer: RegistrationOffer) async throws -> RegistrationChannel {
        try await link.register(offer)
    }

    public func completeRegistration(_ channel: RegistrationChannel, confirmation: MacConfirmation) async throws -> MacRecord {
        guard let store else { throw StoreError.sqlite("unavailable") }
        let account = Hex.string(confirmation.bogoID) + "." + UUID().uuidString
        let key = try await ApprovalKey.create(account: account, reason: "Add \(confirmation.macName) to BOGO", proving: Registration.proofMessage(confirmation))
        let saved: (route: MacRoute, approverID: Data)?
        let attestation: Attestation?
        do {
            attestation = try await AppAttest.attest(clientDataHash: channel.clientDataHash(approvalKey: key.publicKey))
            saved = try channel.saveRoute()
        } catch {
            ApprovalKey.delete(account: account)
            channel.abort()
            throw error
        }
        if let previous = mac(confirmation.bogoID) {
            ApprovalKey.delete(account: previous.keyAccount)
            if let old = previous.route, old.channelAccount != saved?.route.channelAccount { ChannelKeys.delete(account: old.channelAccount) }
        }
        let mac = MacRecord(bogoID: confirmation.bogoID, name: confirmation.macName, keyAccount: account, approvalPublicKey: key.publicKey,
                            approverID: saved?.approverID, biometryState: ApprovalKey.biometryState(), state: .waiting, addedMs: clock(), bootSeq: 0,
                            route: saved?.route, pushToken: pushToken)
        try store.save(mac)
        reload()
        link.start(macs: macs)
        do {
            let registered = try await channel.submit(RegistrationSubmission(approvalPublicKey: key.publicKey, proof: key.proof, attestation: attestation,
                                                                             pushToken: pushToken, pushEnvironment: pushEnvironment))
            guard saved == nil || registered.approverID == saved?.approverID else { throw RegistrationError.tampered }
            if var current = self.mac(confirmation.bogoID), current.state == .waiting {
                current.approverID = registered.approverID
                current.state = .active
                try store.save(current)
            }
        } catch RegistrationError.unanswered where saved != nil {
            try? store.enqueue(.regResend(txID: saved!.route.txID), to: mac.bogoID, nowMs: clock())
            reload()
            Task { await flush() }
            throw RegistrationError.unanswered
        } catch {
            ApprovalKey.delete(account: account)
            if let saved { ChannelKeys.delete(account: saved.route.channelAccount) }
            try? store.deleteMac(mac.bogoID)
            reload()
            link.start(macs: macs)
            throw error
        }
        reload()
        link.start(macs: macs)
        return self.mac(confirmation.bogoID) ?? mac
    }

    private func sendPushToken() {
        guard let store, let token = pushToken, token.count == 32 else { return }
        let now = clock()
        do {
            try store.transaction {
                for var mac in macs where mac.state == .active && mac.route != nil && mac.pushToken != token {
                    mac.pushToken = token
                    try store.save(mac)
                    try store.enqueue(.pushToken(seq: now, token: token, env: pushEnvironment), to: mac.bogoID, nowMs: now)
                }
            }
        } catch {
            storeFailure = true
        }
        reload()
        Task { await flush() }
    }

    private func decide(_ record: RequestRecord, _ decision: Decision, message: PhoneMessage) -> DecisionResult {
        guard let store else { return .nothingSigned("BOGO storage is unavailable. Nothing was sent.") }
        var decided = record
        decided.phase = record.phase.applying(.decided(decision))
        decided.changedMs = clock()
        do {
            try store.transaction {
                try store.save(decided)
                try store.enqueue(message, to: record.bogoID, nowMs: decided.changedMs)
            }
        } catch {
            storeFailure = true
            return .nothingSigned("BOGO couldn’t save this decision. Nothing was sent.")
        }
        reload()
        Task { await flush() }
        return .decided
    }

    private func apply(_ event: RequestEvent, to reqID: Data, at bogoID: Data, now: UInt64) throws {
        guard let store else { return }
        if var record = records.first(where: { $0.bogoID == bogoID && $0.reqID == reqID }) {
            let next = record.phase.applying(event)
            guard next != record.phase else { return }
            record.phase = next
            record.changedMs = now
            try store.save(record)
        } else {
            let placeholder = RequestRecord(bogoID: bogoID, reqID: reqID, bytes: Data(), bootSeq: 0, pauseEpoch: 0, armDelayMs: 0, receivedMs: 0,
                                            phase: RequestPhase.pending.applying(event), changedMs: now)
            try store.save(placeholder)
        }
    }

    private func markNeedsReRegistration(_ mac: MacRecord) {
        var changed = mac
        changed.state = .needsReRegistration
        try? store?.save(changed)
        reload()
    }

    private func reload() {
        guard let store else { return }
        do {
            macs = try store.macs()
            records = try store.records()
            pauses = try store.pauses()
        } catch {
            storeFailure = true
        }
    }

    static func final(_ phase: RequestPhase) -> Bool {
        if case .finished = phase { return true }
        if case .ended = phase { return true }
        return false
    }

    static func awaitingOutcome(_ phase: RequestPhase) -> Bool {
        if case .sent = phase { return true }
        if case .settled(let decision?) = phase { return decision == .approved }
        return false
    }
}
