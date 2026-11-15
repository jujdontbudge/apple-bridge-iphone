import CryptoKit
import Foundation
import ObjectiveC

final class LobbyFixture: @unchecked Sendable {
    let lock = NSLock()
    let offer = Data(repeating: 1, count: 16)
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let nM = Data(repeating: 2, count: 16)
    var ePubP = Data()
    var nP = Data()
    var submitted = false

    func reply(_ request: URLRequest) throws -> (Int, Any) {
        lock.lock()
        defer { lock.unlock() }
        let path = request.url!.path
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let fields = RegWire.json(body) ?? [:]
        if path == "/v1/auth/challenge" {
            return (200, ["challenge": Hex.string(Data(repeating: 3, count: 32))])
        }
        if path == "/v1/auth/verify" { return (200, ["token": "test"]) }
        if path.hasSuffix("/msg") {
            let body = Hex.data(fields["body"] as! String)!
            switch body.first! {
            case RegWire.hello: ePubP = Data(body.dropFirst())
            case RegWire.phoneNonce: nP = Data(body.dropFirst())
            case RegWire.regSubmit: submitted = true
            default: break
            }
            return (200, [:])
        }
        if path.hasSuffix("/fetch") {
            if submitted { return (404, [:]) }
            let ePubM = mac.publicKey.rawRepresentation
            let commit = RegWire.commitment(ePubM: ePubM, ePubP: ePubP, nM: nM)
            var phases: [(UInt8, Data)] = [(RegWire.commit, commit)]
            if !nP.isEmpty {
                let th = RegWire.transcriptHash(
                    offer: offer, ePubM: ePubM, ePubP: ePubP,
                    commit: commit, nM: nM, nP: nP
                )
                let shared = try mac.sharedSecretFromKeyAgreement(
                    with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePubP)
                ).withUnsafeBytes { Data($0) }
                let plain = try JSONSerialization.data(withJSONObject: [
                    "macE2e": Hex.string(ePubM),
                    "macRelay": Hex.string(Data(repeating: 4, count: 32)),
                    "bogoId": Hex.string(RegWire.sha(ePubM)),
                    "macName": "Mac",
                    "challenge": Hex.string(Data(repeating: 5, count: 32))
                ])
                let sealed = try RegWire.seal(
                    plain,
                    key: RegWire.phaseKey(shared: shared, transcriptHash: th),
                    offer: offer,
                    phase: RegWire.macConfirmed
                )
                phases += [(RegWire.reveal, nM), (RegWire.macConfirmed, sealed)]
            }
            return (200, phases.map { phase, payload in
                [
                    "msg_id": Hex.string(RegWire.msgID(offer: offer, phase: phase)),
                    "from": "mac",
                    "body": Hex.string(Data([phase]) + payload)
                ]
            })
        }
        fatalError("unexpected request: \(path)")
    }
}

final class LobbyProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = LobbyFixture()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "proof.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (status, object) = try Self.fixture.reply(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(
                self, didLoad: try JSONSerialization.data(withJSONObject: object)
            )
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLSessionConfiguration {
    @objc class func proofEphemeral() -> URLSessionConfiguration {
        let config = proofEphemeral()
        config.protocolClasses = [LobbyProtocol.self]
        return config
    }
}

@main
enum ClosedLobbyProof {
    @MainActor
    static func main() async throws {
        let original = class_getClassMethod(
            URLSessionConfiguration.self,
            #selector(getter: URLSessionConfiguration.ephemeral)
        )!
        let replacement = class_getClassMethod(
            URLSessionConfiguration.self,
            #selector(URLSessionConfiguration.proofEphemeral)
        )!
        method_exchangeImplementations(original, replacement)
        defer { method_exchangeImplementations(original, replacement) }

        let fixture = LobbyProtocol.fixture
        let keys = ChannelKeys()
        let client = RelayClient(
            endpoint: RelayEndpoint(url: URL(string: "https://proof.invalid")!),
            key: keys.relay
        )
        let offer = LobbyOffer(
            offerID: fixture.offer,
            ePubM: fixture.mac.publicKey.rawRepresentation,
            label: "Mac", ageSeconds: 0
        )
        let channel = try await RelayRegistration.begin(
            client: client, keys: keys, offer: offer
        )
        _ = try await channel.macConfirmation()
        do {
            _ = try await channel.submit(RegistrationSubmission(
                approvalPublicKey: Data(), proof: Data(), attestation: nil,
                pushToken: nil, pushEnvironment: "development"
            ))
            fatalError("expected unanswered")
        } catch RegistrationError.unanswered {
            print("PASS")
        } catch {
            print("FAIL S1: lobby closed after REG_SUBMIT; expected unanswered to preserve recovery, got \(error)")
            exit(1)
        }
    }
}
