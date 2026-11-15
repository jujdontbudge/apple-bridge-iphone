import BogoSection
import Foundation

@MainActor
final class BogoEdge: BogoHost {
    static let shared = BogoEdge()
    var pushToken: Data?
    let apnsEnvironment: BogoAPNsEnvironment = BogoAPNsEnvironment(rawValue: Bundle.main.object(forInfoDictionaryKey: "BogoAPNsEnvironment") as? String ?? "") ?? .production

    lazy var section = BogoSection(
        host: self,
        storageDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BOGO", isDirectory: true),
        relayURL: URL(string: "https://bogo.eilmer.si:8443")!
    )
}
