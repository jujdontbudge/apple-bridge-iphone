#if DEBUG
import BogoModel
import CryptoKit
import Foundation

@MainActor
public final class StandInMacLink: MacLink {
    public static let macName = "Stand-in Mac"
    public static let armDelayMs: UInt64 = 2000
    public static let script: [(vector: String, afterMs: UInt64)] = [
        ("payment-approved", 0), ("lie-in-reason", 300), ("filesystem-write", 300), ("other-session", 300), ("researcher", 300),
        ("keys-unordered", 300), ("amount-4701", 300),
    ]

    public var receive: ((Data, MacMessage) -> Void)?
    public let directory: URL
    public let bogoID: Data

    private let vectors: [String: Data]
    private let rejects: [String: Data]
    private var mac: MacRecord?
    private var bootSeq: UInt64 = 0
    private var bootID = Data()
    private var seq: UInt64 = 0
    private var epochs: [Data: UInt64] = [:]
    private var sent: [Data: Data] = [:]
    private var poller: Task<Void, Never>?

    public init(directory: URL) {
        self.directory = directory
        let bundle = Bundle(for: StandInMacLink.self)
        vectors = Self.load(bundle.url(forResource: "requests", withExtension: "json"), list: "requests", bytes: "encoded_hex")
        rejects = Self.load(bundle.url(forResource: "decode_reject", withExtension: "json"), list: "reject", bytes: "hex")
        bogoID = vectors["payment-approved"].flatMap { RequestBytes.decode($0)?.bogoID } ?? Data(repeating: 0, count: 32)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("inbox"), withIntermediateDirectories: true)
    }

    public func start(macs: [MacRecord]) {
        mac = macs.first { $0.bogoID == bogoID && $0.state != .removed && $0.state != .waiting }
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func fetch() async {
        let inbox = directory.appendingPathComponent("inbox")
        guard mac != nil, let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") {
            let file = inbox.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file), let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            run(command)
        }
    }

    public func send(_ message: PhoneMessage, msgID: Data, to mac: MacRecord) async throws {
        var line: [String: Any] = ["msgId": Hex.string(msgID), "body": String(decoding: message.body, as: UTF8.self)]
        switch message {
        case .approval(let reqID, let alg, let sig):
            line["verified"] = verify(alg: alg, signature: sig, reqID: reqID, key: mac.approvalPublicKey)
        case .pause(let agentID, let epoch):
            guard epochs[agentID, default: 1] == epoch else { break }
            for (reqID, bytes) in sent where RequestBytes.decode(bytes)?.agentID == agentID { receive?(bogoID, .ended(reqID: reqID, why: .agentPaused)) }
        case .removed:
            self.mac = nil
            receive?(mac.bogoID, .revokedAck)
        default:
            break
        }
        log(line)
    }

    public func offers(excluding macs: [MacRecord]) async -> [RegistrationOffer] {
        guard !macs.contains(where: { $0.bogoID == bogoID && $0.state == .active }) else { return [] }
        return [RegistrationOffer(id: "stand-in", label: Self.macName, opened: Date().addingTimeInterval(-12))]
    }

    public func register(_ offer: RegistrationOffer) async throws -> RegistrationChannel {
        StandInRegistration(link: self)
    }

    func registered(_ record: MacRecord) {
        mac = record
        bootSeq += 1
        bootID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        seq = 0
        sent = [:]
        receive?(bogoID, .boot(bootSeq: bootSeq, bootID: bootID))
        Task {
            for step in Self.script {
                try? await Task.sleep(for: .milliseconds(step.afterMs))
                run(["request": step.vector])
            }
            try? await Task.sleep(for: .seconds(4))
            run(["ended": "amount-4701", "why": "callEnded"])
        }
    }

    private func run(_ command: [String: Any]) {
        let fresh = command["asIs"] as? Bool != true
        if let name = command["request"] as? String, let bytes = vectors[name] {
            deliver(fresh ? Self.restamped(bytes, nowMs: UInt64(Date().timeIntervalSince1970 * 1000)) : bytes, reqID: RequestBytes.decode(bytes)?.nonce)
        }
        if let name = command["reject"] as? String, let bytes = rejects[name] {
            deliver(bytes, reqID: nil)
        }
        if let hex = command["hex"] as? String, let bytes = Hex.data(hex) {
            deliver(bytes, reqID: RequestBytes.decode(bytes)?.nonce)
        }
        if let name = command["ended"] as? String, let reqID = nonce(name) {
            receive?(bogoID, .ended(reqID: reqID, why: EndReason(rawValue: command["why"] as? String ?? "") ?? .callEnded))
        }
        if let name = command["settled"] as? String, let reqID = nonce(name) {
            receive?(bogoID, .settled(reqID: reqID))
        }
        if let name = command["outcome"] as? String, let reqID = nonce(name) {
            receive?(bogoID, .outcome(reqID: reqID, outcome: Outcome(rawValue: command["is"] as? String ?? "") ?? .unknown))
        }
        if let agent = command["unpause"] as? String, let agentID = vectors.values.compactMap({ RequestBytes.decode($0) }).first(where: { $0.agentName == agent })?.agentID {
            epochs[agentID, default: 1] += 1
        }
        if command["boot"] as? Bool == true {
            bootSeq += 1
            receive?(bogoID, .boot(bootSeq: bootSeq, bootID: Data((0..<32).map { _ in UInt8.random(in: 0...255) })))
        }
    }

    private func deliver(_ bytes: Data, reqID: Data?) {
        seq += 1
        let id = reqID ?? bootID + withUnsafeBytes(of: seq.bigEndian) { Data($0) }
        sent[id] = bytes
        let agent = RequestBytes.decode(bytes)?.agentID ?? Data()
        receive?(bogoID, .request(reqID: id, bootSeq: bootSeq, bytes: bytes, pauseEpoch: epochs[agent, default: 1], armDelayMs: Self.armDelayMs))
    }

    private func nonce(_ name: String) -> Data? {
        vectors[name].flatMap { RequestBytes.decode($0)?.nonce }
    }

    private func verify(alg: UInt16, signature: Data, reqID: Data, key: Data) -> Bool {
        guard alg == 1, let bytes = sent[reqID], let publicKey = try? P256.Signing.PublicKey(x963Representation: key),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return publicKey.isValidSignature(parsed, for: RequestBytes.signedMessage(bytes))
    }

    private func log(_ line: [String: Any]) {
        var entry = line
        entry["atMs"] = UInt64(Date().timeIntervalSince1970 * 1000)
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(10)
        let file = directory.appendingPathComponent("received.jsonl")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    static func restamped(_ bytes: Data, nowMs: UInt64) -> Data {
        guard let request = RequestBytes.decode(bytes) else { return bytes }
        var raw = [UInt8](bytes)
        func write(_ value: UInt64, at offset: Int) {
            for index in 0..<8 { raw[offset + index] = UInt8(truncatingIfNeeded: value >> (56 - 8 * index)) }
        }
        if let expiresMs = request.expiresMs {
            let lifetime = expiresMs > request.createdMs ? min(expiresMs - request.createdMs, 3_600_000) : 600_000
            write(nowMs, at: raw.count - 18)
            write(nowMs + lifetime, at: raw.count - 8)
        } else {
            write(nowMs, at: raw.count - 10)
        }
        let result = Data(raw)
        return RequestBytes.decode(result) == nil ? bytes : result
    }

    private static func load(_ url: URL?, list: String, bytes: String) -> [String: Data] {
        guard let url, let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root[list] as? [[String: Any]] else { return [:] }
        var result: [String: Data] = [:]
        for item in items {
            if let name = item["name"] as? String, let hex = item[bytes] as? String, let value = Hex.data(hex) { result[name] = value }
        }
        return result
    }
}

@MainActor
final class StandInRegistration: RegistrationChannel {
    let code: String
    private let link: StandInMacLink
    private let transcriptHash: Data
    private let challenge: Data
    private var aborted = false

    init(link: StandInMacLink) {
        self.link = link
        let mac = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let phone = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let macNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let phoneNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        code = Registration.code(Data(SHA256.hash(data: Data("bogo-reg-code".utf8) + mac + phone + macNonce + phoneNonce)))
        transcriptHash = Data(SHA256.hash(data: mac + phone + macNonce + phoneNonce))
        challenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    }

    func macConfirmation() async throws -> MacConfirmation {
        try await Task.sleep(for: .milliseconds(1800))
        guard !aborted else { throw CancellationError() }
        return MacConfirmation(bogoID: link.bogoID, macName: StandInMacLink.macName, challenge: challenge, transcriptHash: transcriptHash)
    }

    func submit(_ submission: RegistrationSubmission) async throws -> Registered {
        guard !aborted, let key = try? P256.Signing.PublicKey(x963Representation: submission.approvalPublicKey),
              let proof = try? P256.Signing.ECDSASignature(rawRepresentation: submission.proof),
              key.isValidSignature(proof, for: Registration.proofDomain + transcriptHash + challenge) else { throw CancellationError() }
        let registered = Registered(txID: Data(SHA256.hash(data: transcriptHash)), approverID: Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let record = MacRecord(bogoID: link.bogoID, name: StandInMacLink.macName, keyAccount: "", approvalPublicKey: submission.approvalPublicKey,
                               approverID: registered.approverID, biometryState: nil, state: .active, addedMs: 0, bootSeq: 0)
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            link.registered(record)
        }
        return registered
    }

    func abort() {
        aborted = true
    }
}
#endif
