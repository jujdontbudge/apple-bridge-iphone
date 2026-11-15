import BogoCrypto
import BogoModel
import Foundation

public enum MacMessage: Equatable, Sendable {
    case request(reqID: Data, bootSeq: UInt64, bytes: Data, pauseEpoch: UInt64, armDelayMs: UInt64)
    case settled(reqID: Data)
    case ended(reqID: Data, why: EndReason)
    case boot(bootSeq: UInt64, bootID: Data)
    case outcome(reqID: Data, outcome: Outcome?)
    case revokedAck
}

public enum PhoneMessage: Equatable, Sendable {
    case approval(reqID: Data, alg: UInt16, sig: Data)
    case denial(reqID: Data, note: String?)
    case pause(agentID: Data, epoch: UInt64)
    case seen(reqID: Data)
    case sync(reqIDs: [Data])
    case removed

    public var kind: String {
        switch self {
        case .approval: return "approval"
        case .denial: return "denial"
        case .pause: return "pause"
        case .seen: return "seen"
        case .sync: return "sync"
        case .removed: return "removed"
        }
    }

    public var reqID: Data? {
        switch self {
        case .approval(let reqID, _, _), .denial(let reqID, _), .seen(let reqID): return reqID
        default: return nil
        }
    }

    public var body: Data {
        var fields: [String: Any] = ["type": kind]
        switch self {
        case .approval(let reqID, let alg, let sig):
            fields["reqId"] = Hex.string(reqID)
            fields["alg"] = Int(alg)
            fields["sig"] = Hex.string(sig)
        case .denial(let reqID, let note):
            fields["reqId"] = Hex.string(reqID)
            fields["note"] = note ?? NSNull()
        case .pause(let agentID, let epoch):
            fields["agentId"] = Hex.string(agentID)
            fields["epoch"] = epoch
        case .seen(let reqID):
            fields["reqId"] = Hex.string(reqID)
        case .sync(let reqIDs):
            fields["reqIds"] = reqIDs.map(Hex.string)
        case .removed:
            break
        }
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }

    public init?(body: Data) {
        guard let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let kind = fields["type"] as? String else { return nil }
        let reqID = (fields["reqId"] as? String).flatMap(Hex.data)
        switch kind {
        case "approval":
            guard let reqID, let alg = fields["alg"] as? Int, let sig = (fields["sig"] as? String).flatMap(Hex.data) else { return nil }
            self = .approval(reqID: reqID, alg: UInt16(alg), sig: sig)
        case "denial":
            guard let reqID else { return nil }
            self = .denial(reqID: reqID, note: fields["note"] as? String)
        case "pause":
            guard let agentID = (fields["agentId"] as? String).flatMap(Hex.data), let epoch = fields["epoch"] as? UInt64 else { return nil }
            self = .pause(agentID: agentID, epoch: epoch)
        case "seen":
            guard let reqID else { return nil }
            self = .seen(reqID: reqID)
        case "sync":
            self = .sync(reqIDs: (fields["reqIds"] as? [String] ?? []).compactMap(Hex.data))
        case "removed":
            self = .removed
        default:
            return nil
        }
    }
}

public enum MacState: String, Sendable {
    case waiting, active, needsReRegistration, removed
}

public struct MacRecord: Identifiable, Equatable, Sendable {
    public let bogoID: Data
    public var name: String
    public let keyAccount: String
    public let approvalPublicKey: Data
    public var approverID: Data?
    public var biometryState: Data?
    public var state: MacState
    public let addedMs: UInt64
    public var bootSeq: UInt64

    public var id: String { Hex.string(bogoID) }
}

public struct RegistrationOffer: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let opened: Date

    public init(id: String, label: String, opened: Date) {
        self.id = id
        self.label = label
        self.opened = opened
    }
}

public struct MacConfirmation: Sendable {
    public let bogoID: Data
    public let macName: String
    public let challenge: Data
    public let transcriptHash: Data

    public init(bogoID: Data, macName: String, challenge: Data, transcriptHash: Data) {
        self.bogoID = bogoID
        self.macName = macName
        self.challenge = challenge
        self.transcriptHash = transcriptHash
    }
}

public struct RegistrationSubmission: Sendable {
    public let approvalPublicKey: Data
    public let proof: Data
    public let attestation: Attestation?
    public let pushToken: Data?
}

public struct Registered: Sendable {
    public let txID: Data
    public let approverID: Data

    public init(txID: Data, approverID: Data) {
        self.txID = txID
        self.approverID = approverID
    }
}

public enum Registration {
    public static let proofDomain = Data("BOGO-REG".utf8) + Data([0]) + Data("v1".utf8)

    public static func proofMessage(_ confirmation: MacConfirmation) -> Data {
        proofDomain + confirmation.transcriptHash + confirmation.challenge
    }

    public static func code(_ digest: Data) -> String {
        let value = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        return String(format: "%06llu", value)
    }
}

@MainActor
public protocol RegistrationChannel: AnyObject {
    var code: String { get }
    func macConfirmation() async throws -> MacConfirmation
    func submit(_ submission: RegistrationSubmission) async throws -> Registered
    func abort()
}

@MainActor
public protocol MacLink: AnyObject {
    var receive: ((Data, MacMessage) -> Void)? { get set }
    func start(macs: [MacRecord])
    func fetch() async
    func send(_ message: PhoneMessage, msgID: Data, to mac: MacRecord) async throws
    func offers(excluding macs: [MacRecord]) async -> [RegistrationOffer]
    func register(_ offer: RegistrationOffer) async throws -> RegistrationChannel
}

@MainActor
public final class UnlinkedMacLink: MacLink {
    public var receive: ((Data, MacMessage) -> Void)?

    public init() {}

    public func start(macs: [MacRecord]) {}
    public func fetch() async {}
    public func send(_ message: PhoneMessage, msgID: Data, to mac: MacRecord) async throws { throw URLError(.notConnectedToInternet) }
    public func offers(excluding macs: [MacRecord]) async -> [RegistrationOffer] { [] }
    public func register(_ offer: RegistrationOffer) async throws -> RegistrationChannel { throw URLError(.notConnectedToInternet) }
}
