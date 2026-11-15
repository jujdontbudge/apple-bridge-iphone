import CryptoKit
import Foundation

/// BOGO's end-to-end envelope (RELAY-PROTOCOL "Envelope"): single-shot RFC 9180
/// HPKE in auth mode, DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / ChaCha20-Poly1305.
///
///     "BOGOE2E\0" | version=1 | direction | type | msgId:16 | u32 32 | enc:32 | u32 n | ciphertext
///
/// The first 27 bytes are the AAD; `info = "bogo/e2e/v1" ‖ bogoId ‖ approverId`.
public enum Channel {
    public enum Direction: UInt8, Sendable {
        case macToPhone = 0
        case phoneToMac = 1
    }

    public struct Opened: Sendable {
        public let msgID: Data
        public let kind: UInt8
        public let plaintext: Data
    }

    public enum Failure: Error {
        case invalid
    }

    static let magic = Data("BOGOE2E".utf8) + Data([0])
    static let headerLength = 27
    static let maxPlaintext = 1024 * 1024
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    static func info(bogoID: Data, approverID: Data) -> Data {
        Data("bogo/e2e/v1".utf8) + bogoID + approverID
    }

    public static func seal(sender: Curve25519.KeyAgreement.PrivateKey, recipient: Curve25519.KeyAgreement.PublicKey, bogoID: Data, approverID: Data,
                            direction: Direction, kind: UInt8, msgID: Data, plaintext: Data) throws -> Data {
        guard msgID.count == 16, plaintext.count <= maxPlaintext, kind & 0x80 == 0 else { throw Failure.invalid }
        var header = magic
        header.append(contentsOf: [1, direction.rawValue, kind])
        header.append(msgID)
        var hpke = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info(bogoID: bogoID, approverID: approverID), authenticatedBy: sender)
        let ciphertext = try hpke.seal(plaintext, authenticating: header)
        let enc = hpke.encapsulatedKey
        guard enc.count == 32 else { throw Failure.invalid }
        return header + u32(32) + enc + u32(UInt32(ciphertext.count)) + ciphertext
    }

    /// The message ID, read before decryption so a duplicate can be dropped unopened.
    public static func peekID(_ envelope: Data) -> Data? {
        let bytes = [UInt8](envelope)
        guard bytes.count >= headerLength, Data(bytes[0..<8]) == magic, bytes[8] == 1 else { return nil }
        return Data(bytes[11..<27])
    }

    public static func open(recipient: Curve25519.KeyAgreement.PrivateKey, sender: Curve25519.KeyAgreement.PublicKey, bogoID: Data, approverID: Data,
                            direction: Direction, envelope: Data) throws -> Opened {
        let bytes = [UInt8](envelope)
        guard let msgID = peekID(envelope), bytes.count >= 83, bytes.count <= maxPlaintext + 83, bytes[9] == direction.rawValue,
              readU32(bytes, 27) == 32, Int(readU32(bytes, 63)) == bytes.count - 67 else { throw Failure.invalid }
        let kind = bytes[10]
        guard kind & 0x80 == 0 else { throw Failure.invalid }
        let header = Data(bytes[0..<headerLength])
        do {
            var hpke = try HPKE.Recipient(privateKey: recipient, ciphersuite: suite, info: info(bogoID: bogoID, approverID: approverID),
                                          encapsulatedKey: Data(bytes[31..<63]), authenticatedBy: sender)
            let plaintext = try hpke.open(Data(bytes[67...]), authenticating: header)
            return Opened(msgID: msgID, kind: kind, plaintext: plaintext)
        } catch {
            throw Failure.invalid
        }
    }

    private static func u32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}

/// One registered Mac's channel keys on this phone: X25519 `phoneE2E` and
/// Ed25519 `phoneRelay`. They open and seal envelopes and sign into the relay
/// mailbox; they can never produce an approval. Kept in BOGO's own Keychain
/// items, `AfterFirstUnlockThisDeviceOnly`, so a push wake can use them.
public struct ChannelKeys: Sendable {
    public let e2e: Curve25519.KeyAgreement.PrivateKey
    public let relay: Curve25519.Signing.PrivateKey

    static let service = "si.eilmer.bogo.channel-key"

    public init() {
        e2e = Curve25519.KeyAgreement.PrivateKey()
        relay = Curve25519.Signing.PrivateKey()
    }

    public init(relay: Curve25519.Signing.PrivateKey) {
        e2e = Curve25519.KeyAgreement.PrivateKey()
        self.relay = relay
    }

    public func save(account: String) throws {
        try BogoKeychain.store(e2e.rawRepresentation + relay.rawRepresentation, account: account, service: Self.service)
    }

    public static func load(account: String) -> ChannelKeys? {
        guard let raw = try? BogoKeychain.load(account: account, service: service), raw.count == 64,
              let e2e = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw.prefix(32)),
              let relay = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw.suffix(32)) else { return nil }
        return ChannelKeys(e2e: e2e, relay: relay)
    }

    public static func delete(account: String) {
        BogoKeychain.delete(account: account, service: service)
    }

    private init(e2e: Curve25519.KeyAgreement.PrivateKey, relay: Curve25519.Signing.PrivateKey) {
        self.e2e = e2e
        self.relay = relay
    }
}
