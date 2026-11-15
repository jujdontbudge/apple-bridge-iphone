import BogoModel
import CryptoKit
import Foundation

/// Where BOGO's relay is and the service identity its mailbox auth binds
/// (normally `host:port`).
public struct RelayEndpoint: Sendable, Equatable {
    public let url: URL
    public let service: String

    public init(url: URL) {
        self.url = url
        service = (url.host() ?? "") + ":" + String(url.port ?? 443)
    }
}

public enum RelayError: Error, Equatable {
    case transport
    case status(Int)
    case wire
}

public struct RelayMessage: Sendable {
    public let msgID: String
    public let from: String
    public let body: Data
}

public struct LobbyOffer: Sendable {
    public let offerID: Data
    public let ePubM: Data
    public let label: String
    public let ageSeconds: UInt64
}

/// One authenticated relay mailbox (RELAY-PROTOCOL "Mailbox transport"). TLS
/// and hostname checks stay on, redirects are refused, and the bearer token
/// lives only in memory; a 401 re-authenticates once.
@MainActor
public final class RelayClient {
    public let endpoint: RelayEndpoint
    public let mailbox: String
    private let key: Curve25519.Signing.PrivateKey
    private var token: String?
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public init(endpoint: RelayEndpoint, key: Curve25519.Signing.PrivateKey) {
        self.endpoint = endpoint
        self.key = key
        mailbox = Self.mailbox(key.publicKey.rawRepresentation)
    }

    public static func mailbox(_ publicKey: Data) -> String {
        Hex.string(Data(SHA256.hash(data: publicKey)))
    }

    public func allow(_ senders: [String]) async throws {
        _ = try await call("POST", "/v1/allow", ["senders": senders])
    }

    public func send(to: String, msgID: Data, envelope: Data) async throws {
        _ = try await call("POST", "/v1/send", ["to": to, "msg_id": Hex.string(msgID), "body": Hex.string(envelope)])
    }

    public func fetch(wait: Bool) async throws -> [RelayMessage] {
        try messages(try await call("POST", "/v1/fetch", ["wait": wait]))
    }

    public func ack(_ msgIDs: [String]) async throws {
        _ = try await call("POST", "/v1/ack", ["msg_ids": msgIDs])
    }

    public func offers() async throws -> [LobbyOffer] {
        guard let list = try JSONSerialization.jsonObject(with: try await call("GET", "/v1/lobby", nil)) as? [[String: Any]] else { throw RelayError.wire }
        return list.compactMap { item in
            guard let id = (item["offer_id"] as? String).flatMap(Hex.data), id.count == 16,
                  let key = (item["e_pub_m"] as? String).flatMap(Hex.data), key.count == 32,
                  let label = item["mac_label"] as? String else { return nil }
            return LobbyOffer(offerID: id, ePubM: key, label: label, ageSeconds: (item["age_seconds"] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    public func lobbySend(offer: Data, msgID: Data, body: Data) async throws {
        _ = try await call("POST", "/v1/lobby/\(Hex.string(offer))/msg", ["msg_id": Hex.string(msgID), "body": Hex.string(body)])
    }

    public func lobbyFetch(offer: Data) async throws -> [RelayMessage] {
        try messages(try await call("POST", "/v1/lobby/\(Hex.string(offer))/fetch", nil))
    }

    private func messages(_ data: Data) throws -> [RelayMessage] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw RelayError.wire }
        return list.compactMap { item in
            guard let id = item["msg_id"] as? String, let from = item["from"] as? String,
                  let body = (item["body"] as? String).flatMap(Hex.data) else { return nil }
            return RelayMessage(msgID: id, from: from, body: body)
        }
    }

    private func call(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> Data {
        if token == nil { try await authenticate() }
        do {
            return try await request(method, path, body, bearer: token)
        } catch RelayError.status(401) {
            token = nil
            try await authenticate()
            return try await request(method, path, body, bearer: token)
        }
    }

    private func authenticate() async throws {
        let publicKey = Hex.string(key.publicKey.rawRepresentation)
        let challengeReply = try await request("POST", "/v1/auth/challenge", ["pub": publicKey], bearer: nil)
        guard let challengeHex = (try? JSONSerialization.jsonObject(with: challengeReply) as? [String: Any])?["challenge"] as? String,
              let challenge = Hex.data(challengeHex), challenge.count == 32 else { throw RelayError.wire }
        let service = Data(endpoint.service.utf8)
        var signed = Data("bogo/relay/auth/v1".utf8) + Data([0])
        signed += withUnsafeBytes(of: UInt32(service.count).bigEndian) { Data($0) }
        signed += service + Data(SHA256.hash(data: key.publicKey.rawRepresentation)) + challenge
        let signature = try key.signature(for: signed)
        let tokenReply = try await request("POST", "/v1/auth/verify", ["pub": publicKey, "sig": Hex.string(signature)], bearer: nil)
        guard let token = (try? JSONSerialization.jsonObject(with: tokenReply) as? [String: Any])?["token"] as? String else { throw RelayError.wire }
        self.token = token
    }

    private func request(_ method: String, _ path: String, _ body: [String: Any]?, bearer: String?) async throws -> Data {
        guard endpoint.url.scheme == "https", let url = URL(string: path, relativeTo: endpoint.url) else { throw RelayError.wire }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw RelayError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw RelayError.transport }
        guard (200..<300).contains(http.statusCode) else { throw RelayError.status(http.statusCode) }
        return data
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
