import BogoModel
import Foundation

@MainActor
final class ReconciliationLink: MacLink {
    var receive: ((Data, Data?, MacMessage) -> Bool)?
    var applied: ((Data, Data) -> Bool)?
    var messages: [PhoneMessage] = []
    func start(macs: [MacRecord]) {}
    func fetch() async {}
    func seal(_ message: PhoneMessage, msgID: Data, for mac: MacRecord) throws -> Data { message.body }
    func send(_ message: PhoneMessage, sealed: Data, msgID: Data, to mac: MacRecord) async throws {
        messages.append(message)
    }
    func offers(excluding macs: [MacRecord]) async -> [RegistrationOffer] { [] }
    func register(_ offer: RegistrationOffer) async throws -> RegistrationChannel {
        throw URLError(.unsupportedURL)
    }
}

@main
enum BogoReconciliationProof {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        let bogoID = Data(repeating: 1, count: 32)
        let reqID = Data(repeating: 2, count: 40)
        try store.save(MacRecord(bogoID: bogoID, name: "Mac", keyAccount: "unused", approvalPublicKey: Data(),
                                 approverID: nil, biometryState: nil, state: .active, addedMs: 1, bootSeq: 1))
        let link = ReconciliationLink()
        let approver = PhoneApprover(directory: directory, link: link, clock: { 1000 })
        approver.receive(bogoID, msgID: nil, .request(reqID: reqID, bootSeq: 1, bytes: Data(), pauseEpoch: 1, armDelayMs: 0))
        guard let record = approver.records.first,
              approver.deny(record, note: "wrong amount") == .decided else {
            fatalError("Fixture must persist a denial")
        }
        await approver.flush()
        await approver.becameActive()
        guard link.messages.contains(.sync(reqIDs: [reqID])) else {
            print("FAIL S2: foreground with a decision awaiting outcome must send sync; sent \(link.messages.map(\.kind))")
            exit(1)
        }
    }
}
