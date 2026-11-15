import BogoCrypto
import BogoModel
import CryptoKit
import Foundation

enum RegWire {
    static let hello: UInt8 = 0x01
    static let commit: UInt8 = 0x02
    static let phoneNonce: UInt8 = 0x03
    static let reveal: UInt8 = 0x04
    static let macConfirmed: UInt8 = 0x05
    static let regSubmit: UInt8 = 0x06
    static let registered: UInt8 = 0x07
    static let refused: UInt8 = 0x08
    static let macAbort: UInt8 = 0x09
    static let phoneAbort: UInt8 = 0x0a

    static func sha(_ parts: Data...) -> Data {
        Data(SHA256.hash(data: parts.reduce(Data(), +)))
    }

    static func tag(_ text: String) -> Data { Data(text.utf8) }

    static func msgID(offer: Data, phase: UInt8) -> Data {
        sha(tag("bogo-reg-msg"), offer, Data([phase])).prefix(16)
    }

    static func commitment(ePubM: Data, ePubP: Data, nM: Data) -> Data {
        sha(tag("bogo-reg-commit"), ePubM, ePubP, nM)
    }

    static func code(ePubM: Data, ePubP: Data, nM: Data, nP: Data) -> String {
        Registration.code(sha(tag("bogo-reg-code"), ePubM, ePubP, nM, nP))
    }

    static func transcriptHash(offer: Data, ePubM: Data, ePubP: Data, commit: Data, nM: Data, nP: Data) -> Data {
        sha(tag("bogo-reg-transcript/v1"), offer, ePubM, ePubP, commit, nM, nP)
    }

    static func txID(_ transcriptHash: Data) -> Data { sha(transcriptHash) }

    static func approverID(_ txID: Data) -> Data { sha(tag("bogo-approver-id/v1"), txID) }

    static func phaseKey(shared: Data, transcriptHash: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: transcriptHash, info: tag("bogo-reg-key/v1"), outputByteCount: 32)
    }

    static func nonce(_ phase: UInt8) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 11) + Data([phase]))
    }

    static func aad(offer: Data, phase: UInt8) -> Data {
        tag("bogo-reg/v1") + offer + Data([phase])
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, offer: Data, phase: UInt8) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(phase), authenticating: aad(offer: offer, phase: phase))
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: SymmetricKey, offer: Data, phase: UInt8) -> Data? {
        guard sealed.count >= 16, let box = try? ChaChaPoly.SealedBox(nonce: nonce(phase), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16)) else { return nil }
        return try? ChaChaPoly.open(box, using: key, authenticating: aad(offer: offer, phase: phase))
    }

    static func random(_ count: Int) -> Data {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return bytes
    }

    static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

@MainActor
final class RelayRegistration: RegistrationChannel {
    let code: String
    private let client: RelayClient
    private let keys: ChannelKeys
    private let offer: Data
    private let transcriptHash: Data
    private let key: SymmetricKey
    private var confirmed: (macE2E: Data, macRelay: Data, bogoID: Data)?
    private var challenge: Data?
    private var aborted = false

    static let poll: Duration = .milliseconds(300)

    static func begin(client: RelayClient, keys: ChannelKeys, offer: LobbyOffer) async throws -> RelayRegistration {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ePubP = ephemeral.publicKey.rawRepresentation
        try await send(client, offer.offerID, RegWire.hello, ePubP)
        let commit = try await wait(client, offer.offerID, for: [RegWire.commit]).payload
        guard commit.count == 32 else { throw RegistrationError.tampered }
        let nP = RegWire.random(16)
        try await send(client, offer.offerID, RegWire.phoneNonce, nP)
        let nM = try await wait(client, offer.offerID, for: [RegWire.reveal]).payload
        guard nM.count == 16, RegWire.commitment(ePubM: offer.ePubM, ePubP: ePubP, nM: nM) == commit else {
            try? await send(client, offer.offerID, RegWire.phoneAbort, Data())
            throw RegistrationError.tampered
        }
        let macKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: offer.ePubM)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: macKey).withUnsafeBytes { Data($0) }
        guard shared.contains(where: { $0 != 0 }) else {
            try? await send(client, offer.offerID, RegWire.phoneAbort, Data())
            throw RegistrationError.tampered
        }
        let th = RegWire.transcriptHash(offer: offer.offerID, ePubM: offer.ePubM, ePubP: ePubP, commit: commit, nM: nM, nP: nP)
        return RelayRegistration(client: client, keys: keys, offer: offer.offerID, transcriptHash: th,
                                 key: RegWire.phaseKey(shared: shared, transcriptHash: th),
                                 code: RegWire.code(ePubM: offer.ePubM, ePubP: ePubP, nM: nM, nP: nP))
    }

    private init(client: RelayClient, keys: ChannelKeys, offer: Data, transcriptHash: Data, key: SymmetricKey, code: String) {
        self.client = client
        self.keys = keys
        self.offer = offer
        self.transcriptHash = transcriptHash
        self.key = key
        self.code = code
    }

    var txID: Data { RegWire.txID(transcriptHash) }

    func macConfirmation() async throws -> MacConfirmation {
        let sealed = try await Self.wait(client, offer, for: [RegWire.macConfirmed], until: { [weak self] in self?.aborted ?? true }).payload
        guard let plain = RegWire.open(sealed, key: key, offer: offer, phase: RegWire.macConfirmed), let fields = RegWire.json(plain),
              let macE2E = (fields["macE2e"] as? String).flatMap(Hex.data), macE2E.count == 32,
              let macRelay = (fields["macRelay"] as? String).flatMap(Hex.data), macRelay.count == 32,
              let bogoID = (fields["bogoId"] as? String).flatMap(Hex.data), bogoID == RegWire.sha(macE2E),
              let challenge = (fields["challenge"] as? String).flatMap(Hex.data), challenge.count == 32,
              let name = fields["macName"] as? String, !name.isEmpty else {
            abort()
            throw RegistrationError.tampered
        }
        confirmed = (macE2E, macRelay, bogoID)
        self.challenge = challenge
        return MacConfirmation(bogoID: bogoID, macName: name, challenge: challenge, transcriptHash: transcriptHash)
    }

    func clientDataHash(approvalKey: Data) -> Data {
        guard let challenge else { return Data() }
        return RegWire.sha(transcriptHash, challenge, approvalKey, keys.e2e.publicKey.rawRepresentation, keys.relay.publicKey.rawRepresentation)
    }


    func saveRoute() throws -> (route: MacRoute, approverID: Data)? {
        guard let confirmed else { throw RegistrationError.macCancelled }
        let account = Hex.string(confirmed.bogoID) + "." + Hex.string(txID.prefix(8))
        try keys.save(account: account)
        let route = MacRoute(macE2E: confirmed.macE2E, macMailbox: RelayClient.mailbox(confirmed.macRelay), txID: txID, channelAccount: account)
        return (route, RegWire.approverID(txID))
    }

    func submit(_ submission: RegistrationSubmission) async throws -> Registered {
        let fields: [String: Any] = [
            "approvalKey": Hex.string(submission.approvalPublicKey),
            "proof": Hex.string(submission.proof),
            "phoneE2e": Hex.string(keys.e2e.publicKey.rawRepresentation),
            "phoneRelay": Hex.string(keys.relay.publicKey.rawRepresentation),
            "attestation": submission.attestation.map { ["keyId": $0.keyID, "object": $0.object.base64EncodedString()] } ?? NSNull(),
            "pushToken": submission.pushToken.map(Hex.string) ?? NSNull(),
            "pushEnv": submission.pushToken == nil ? NSNull() : submission.pushEnvironment as Any,
            "encodingVersions": [1],
        ]
        let plain = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let sealed = try RegWire.seal(plain, key: key, offer: offer, phase: RegWire.regSubmit)
        do {
            try await Self.send(client, offer, RegWire.regSubmit, sealed)
            let answer = try await Self.wait(client, offer, for: [RegWire.registered, RegWire.refused], timeout: .seconds(90))
            if answer.phase == RegWire.refused {
                let why = RegWire.open(answer.payload, key: key, offer: offer, phase: RegWire.refused).flatMap(RegWire.json)?["why"] as? String
                throw RegistrationError.refused(why ?? "")
            }
            guard let opened = RegWire.open(answer.payload, key: key, offer: offer, phase: RegWire.registered), let reply = RegWire.json(opened),
                  let tx = (reply["txId"] as? String).flatMap(Hex.data), let approver = (reply["approverId"] as? String).flatMap(Hex.data),
                  tx == txID, approver == RegWire.approverID(txID) else { throw RegistrationError.unanswered }
            return Registered(txID: tx, approverID: approver)
        } catch RegistrationError.refused(let why) {
            throw RegistrationError.refused(why)
        } catch RegistrationError.macCancelled {
            throw RegistrationError.macCancelled
        } catch {
            throw RegistrationError.unanswered
        }
    }

    func abort() {
        guard !aborted else { return }
        aborted = true
        let (client, offer) = (client, offer)
        Task { try? await Self.send(client, offer, RegWire.phoneAbort, Data()) }
    }

    private static func send(_ client: RelayClient, _ offer: Data, _ phase: UInt8, _ payload: Data) async throws {
        try await client.lobbySend(offer: offer, msgID: RegWire.msgID(offer: offer, phase: phase), body: Data([phase]) + payload)
    }

    private static func wait(_ client: RelayClient, _ offer: Data, for phases: Set<UInt8>, timeout: Duration = .seconds(600),
                             until cancelled: @MainActor () -> Bool = { false }) async throws -> (phase: UInt8, payload: Data) {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if cancelled() || Task.isCancelled { throw RegistrationError.macCancelled }
            let messages: [RelayMessage]
            do {
                messages = try await client.lobbyFetch(offer: offer)
            } catch RelayError.status(404) {
                throw RegistrationError.macCancelled
            } catch RelayError.status(403) {
                throw RegistrationError.macCancelled
            } catch {
                try await Task.sleep(for: .seconds(1))
                continue
            }
            for message in messages {
                guard let phase = message.body.first, message.msgID == Hex.string(RegWire.msgID(offer: offer, phase: phase)) else { continue }
                if phase == RegWire.macAbort { throw RegistrationError.macCancelled }
                if phases.contains(phase) { return (phase, Data(message.body.dropFirst())) }
            }
            try await Task.sleep(for: poll)
        }
        throw RegistrationError.unanswered
    }
}
