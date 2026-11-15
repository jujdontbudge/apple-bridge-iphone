import DeviceCheck
import Foundation

public struct Attestation: Sendable {
    public let keyID: String
    public let object: Data
}

public enum AppAttestError: Error {
    case unsupported
}

public enum AppAttest {
    public static func attest(clientDataHash: Data) async throws -> Attestation? {
        #if targetEnvironment(simulator) && DEBUG
        return nil
        #else
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw AppAttestError.unsupported }
        let keyID = try await service.generateKey()
        let object = try await service.attestKey(keyID, clientDataHash: clientDataHash)
        return Attestation(keyID: keyID, object: object)
        #endif
    }
}
