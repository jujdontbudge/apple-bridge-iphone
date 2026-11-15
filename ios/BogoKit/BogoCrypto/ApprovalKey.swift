import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum ApprovalKeyError: Error, Equatable {
    case cancelled
    case notRecognized
    case unavailable
    case invalidated
}

public struct CreatedApprovalKey: Sendable {
    public let publicKey: Data
    public let proof: Data
}

@MainActor
public enum ApprovalKey {
    public static let algorithm: UInt16 = 1

    public static func create(account: String, reason: String, proving message: Data) async throws -> CreatedApprovalKey {
        #if targetEnvironment(simulator) && DEBUG
        return try await SimulatorApprovalKey.create(account: account, reason: reason, proving: message)
        #else
        return try await SecureEnclaveApprovalKey.create(account: account, reason: reason, proving: message)
        #endif
    }

    public static func sign(account: String, reason: String, message: Data) async throws -> Data {
        #if targetEnvironment(simulator) && DEBUG
        return try await SimulatorApprovalKey.sign(account: account, reason: reason, message: message)
        #else
        return try await SecureEnclaveApprovalKey.sign(account: account, reason: reason, message: message)
        #endif
    }

    public static func delete(account: String) {
        #if targetEnvironment(simulator) && DEBUG
        SimulatorApprovalKey.delete(account: account)
        #else
        BogoKeychain.delete(account: account, service: BogoKeychain.approvalService)
        #endif
    }

    public static func biometryState() -> Data? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return nil }
        return context.domainState.biometry.stateHash
    }

    static func freshContext() -> LAContext {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
        return context
    }

    static func mapped(_ error: Error) -> ApprovalKeyError {
        guard let error = error as? LAError else { return .invalidated }
        switch error.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
        case .authenticationFailed: return .notRecognized
        default: return .unavailable
        }
    }
}

enum SecureEnclaveApprovalKey {
    @MainActor
    static func create(account: String, reason: String, proving message: Data) async throws -> CreatedApprovalKey {
        guard SecureEnclave.isAvailable else { throw ApprovalKeyError.unavailable }
        let access = try accessControl()
        let context = try await authenticated(access, reason: reason)
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
            let proof = try key.signature(for: message).rawRepresentation
            try BogoKeychain.store(key.dataRepresentation, account: account, service: BogoKeychain.approvalService)
            return CreatedApprovalKey(publicKey: key.publicKey.x963Representation, proof: proof)
        } catch {
            throw ApprovalKeyError.unavailable
        }
    }

    @MainActor
    static func sign(account: String, reason: String, message: Data) async throws -> Data {
        guard SecureEnclave.isAvailable else { throw ApprovalKeyError.unavailable }
        let wrapped: Data
        do { wrapped = try BogoKeychain.load(account: account, service: BogoKeychain.approvalService) } catch { throw ApprovalKeyError.invalidated }
        let context = try await authenticated(try accessControl(), reason: reason)
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: wrapped, authenticationContext: context)
            return try key.signature(for: message).rawRepresentation
        } catch {
            throw ApprovalKeyError.invalidated
        }
    }

    private static func accessControl() throws -> SecAccessControl {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil) else {
            throw ApprovalKeyError.unavailable
        }
        return access
    }

    @MainActor
    private static func authenticated(_ access: SecAccessControl, reason: String) async throws -> LAContext {
        let context = ApprovalKey.freshContext()
        do {
            guard try await context.evaluateAccessControl(access, operation: .useKeySign, localizedReason: reason) else { throw ApprovalKeyError.notRecognized }
        } catch let error as ApprovalKeyError {
            throw error
        } catch {
            throw ApprovalKey.mapped(error)
        }
        return context
    }
}
