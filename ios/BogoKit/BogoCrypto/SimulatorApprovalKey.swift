#if targetEnvironment(simulator) && DEBUG
import CryptoKit
import Foundation
import LocalAuthentication

enum SimulatorApprovalKey {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BOGO/simulator-keys", isDirectory: true)
    }

    @MainActor
    static func create(account: String, reason: String, proving message: Data) async throws -> CreatedApprovalKey {
        try await authenticate(reason: reason)
        let key = P256.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try key.rawRepresentation.write(to: directory.appendingPathComponent(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return CreatedApprovalKey(publicKey: key.publicKey.x963Representation, proof: try key.signature(for: message).rawRepresentation)
    }

    @MainActor
    static func sign(account: String, reason: String, message: Data) async throws -> Data {
        let raw: Data
        do { raw = try Data(contentsOf: directory.appendingPathComponent(account)) } catch { throw ApprovalKeyError.invalidated }
        try await authenticate(reason: reason)
        return try P256.Signing.PrivateKey(rawRepresentation: raw).signature(for: message).rawRepresentation
    }

    static func delete(account: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(account))
    }

    @MainActor
    private static func authenticate(reason: String) async throws {
        let context = ApprovalKey.freshContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else { throw ApprovalKeyError.notRecognized }
        } catch let error as ApprovalKeyError {
            throw error
        } catch {
            throw ApprovalKey.mapped(error)
        }
    }
}
#endif
