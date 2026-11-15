import BogoCrypto
import BogoModel
import Foundation

public enum MacMessage: Equatable, Sendable {
    case request(reqID: Data, bootSeq: UInt64, bytes: Data, pauseEpoch: UInt64, armDelayMs: UInt64)
    case settled(reqID: Data)
    case ended(reqID: Data, why: EndReason)
    case boot(bootSeq: UInt64, bootID: Data)
    case outcome(reqID: Data, outcome: Outcome?)
    case registered(txID: Data, approverID: Data)
    case revokedAck

    /// Parses an opened envelope (RELAY-PROTOCOL "iPhone route messages"). The
    /// JSON `type` must agree with the header's type byte.
    public init?(kind: UInt8, body: Data) {
        guard let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let type = fields["type"] as? String else { return nil }
        func bytes(_ key: String) -> Data? { (fields[key] as? String).flatMap(Hex.data) }
        func number(_ key: String) -> UInt64? {
            guard let value = fields[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.uint64Value
        }
        switch (type, kind) {
        case ("request", 1):
            guard let reqID = bytes("reqId"), reqID.count == 40, let bootSeq = number("bootSeq"), let raw = bytes("bytes"),
                  let pauseEpoch = number("pauseEpoch"), let armDelayMs = number("armDelayMs") else { return nil }
            self = .request(reqID: reqID, bootSeq: bootSeq, bytes: raw, pauseEpoch: pauseEpoch, armDelayMs: armDelayMs)
        case ("settled", 2):
            guard let reqID = bytes("reqId"), reqID.count == 40 else { return nil }
            self = .settled(reqID: reqID)
        case ("ended", 3):
            guard let reqID = bytes("reqId"), reqID.count == 40 else { return nil }
            self = .ended(reqID: reqID, why: EndReason(rawValue: fields["why"] as? String ?? "") ?? .unknown)
        case ("boot", 4):
            guard let bootSeq = number("bootSeq"), let bootID = bytes("bootId"), bootID.count == 32 else { return nil }
            self = .boot(bootSeq: bootSeq, bootID: bootID)
        case ("outcome", 5):
            guard let reqID = bytes("reqId"), reqID.count == 40, let word = fields["outcome"] as? String else { return nil }
            self = .outcome(reqID: reqID, outcome: word == "live" ? nil : Outcome(rawValue: word) ?? .unknown)
        case ("registered", 6):
            guard let txID = bytes("txId"), txID.count == 32, let approverID = bytes("approverId"), approverID.count == 32 else { return nil }
            self = .registered(txID: txID, approverID: approverID)
        case ("revokedAck", 7):
            self = .revokedAck
        default:
            return nil
        }
    }
}

public enum PhoneMessage: Equatable, Sendable {
    case approval(reqID: Data, alg: UInt16, sig: Data)
    case denial(reqID: Data, note: String?)
    case pause(agentID: Data, epoch: UInt64)
    case seen(reqID: Data)
    case sync(reqIDs: [Data])
    case pushToken(seq: UInt64, token: Data, env: String)
    case regResend(txID: Data)
    case removed

    /// The envelope header's type byte.
    public var typeByte: UInt8 {
        switch self {
        case .approval: return 1
        case .denial: return 2
        case .pause: return 3
        case .seen: return 4
        case .pushToken: return 5
        case .sync: return 6
        case .regResend: return 7
        case .removed: return 8
        }
    }

    public var kind: String {
        switch self {
        case .approval: return "approval"
        case .denial: return "denial"
        case .pause: return "pause"
        case .seen: return "seen"
        case .sync: return "sync"
        case .pushToken: return "pushToken"
        case .regResend: return "regResend"
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
        case .pushToken(let seq, let token, let env):
            fields["tokenSeq"] = seq
            fields["token"] = Hex.string(token)
            fields["env"] = env
            fields["encodingVersions"] = [1]
        case .regResend(let txID):
            fields["txId"] = Hex.string(txID)
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
        case "pushToken":
            guard let seq = (fields["tokenSeq"] as? NSNumber)?.uint64Value, let token = (fields["token"] as? String).flatMap(Hex.data),
                  let env = fields["env"] as? String else { return nil }
            self = .pushToken(seq: seq, token: token, env: env)
        case "regResend":
            guard let txID = (fields["txId"] as? String).flatMap(Hex.data) else { return nil }
            self = .regResend(txID: txID)
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
    /// How the relay reaches this Mac; nil for the Debug stand-in Mac.
    public var route: MacRoute?
    /// The push token this Mac was last told about.
    public var pushToken: Data?

    public init(bogoID: Data, name: String, keyAccount: String, approvalPublicKey: Data, approverID: Data?, biometryState: Data?, state: MacState,
                addedMs: UInt64, bootSeq: UInt64, route: MacRoute? = nil, pushToken: Data? = nil) {
        self.bogoID = bogoID
        self.name = name
        self.keyAccount = keyAccount
        self.approvalPublicKey = approvalPublicKey
        self.approverID = approverID
        self.biometryState = biometryState
        self.state = state
        self.addedMs = addedMs
        self.bootSeq = bootSeq
        self.route = route
        self.pushToken = pushToken
    }

    public var id: String { Hex.string(bogoID) }
}

/// What the phone keeps to reach one Mac through the relay. The channel keys
/// themselves stay in the Keychain under `channelAccount`.
public struct MacRoute: Equatable, Sendable {
    public let macE2E: Data
    public let macMailbox: String
    public let txID: Data
    public let channelAccount: String

    public init(macE2E: Data, macMailbox: String, txID: Data, channelAccount: String) {
        self.macE2E = macE2E
        self.macMailbox = macMailbox
        self.txID = txID
        self.channelAccount = channelAccount
    }
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
    public let pushEnvironment: String
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

public enum RegistrationError: Error, Equatable {
    /// The owner said no on the Mac, or the Mac stopped the attempt.
    case macCancelled
    /// The Mac checked the phone's submission and refused it; nothing was registered.
    case refused(String)
    /// The Mac's reveal didn't match its commitment.
    case tampered
    /// The submission went out but no answer came back; the Mac may still have registered this phone.
    case unanswered
}

@MainActor
public protocol RegistrationChannel: AnyObject {
    var code: String { get }
    func macConfirmation() async throws -> MacConfirmation
    /// App Attest's client data hash, binding the transcript, the challenge,
    /// the approval key and this channel's own keys.
    func clientDataHash(approvalKey: Data) -> Data
    /// Saves this channel's keys and says how the relay reaches the Mac; nil
    /// for the stand-in Mac.
    func saveRoute() throws -> (route: MacRoute, approverID: Data)?
    func submit(_ submission: RegistrationSubmission) async throws -> Registered
    func abort()
}

@MainActor
public protocol MacLink: AnyObject {
    /// Applies one message from a Mac. `msgID` is the envelope's ID when there
    /// is one; it returns true once the effect (or the decision to drop the
    /// message) is durable, and only then is the message acknowledged.
    var receive: ((Data, Data?, MacMessage) -> Bool)? { get set }
    /// True if a message with this ID was already applied for this Mac.
    var applied: ((Data, Data) -> Bool)? { get set }
    func start(macs: [MacRecord])
    func fetch() async
    /// The bytes sent for this outbox row; sealed once and reused on every resend.
    func seal(_ message: PhoneMessage, msgID: Data, for mac: MacRecord) throws -> Data
    func send(_ message: PhoneMessage, sealed: Data, msgID: Data, to mac: MacRecord) async throws
    func offers(excluding macs: [MacRecord]) async -> [RegistrationOffer]
    func register(_ offer: RegistrationOffer) async throws -> RegistrationChannel
}
