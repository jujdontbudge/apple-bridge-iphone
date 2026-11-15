import Foundation

@MainActor
final class EarlySyncLink: MacLink {
    var receive: ((Data, Data?, MacMessage) -> Bool)?
    var applied: ((Data, Data) -> Bool)?
    var decisionAttempts = 0
    var syncAttempts = 0
    var appliedSyncs = Set<Data>()
    var outcome: Outcome?

    func start(macs: [MacRecord]) {}
    func fetch() async {}
    func offers(excluding macs: [MacRecord]) async -> [RegistrationOffer] { [] }
    func register(_ offer: RegistrationOffer) async throws -> RegistrationChannel {
        throw RelayError.transport
    }
    func seal(_ message: PhoneMessage, msgID: Data, for mac: MacRecord) throws -> Data {
        message.body
    }
    func send(_ message: PhoneMessage, sealed: Data, msgID: Data, to mac: MacRecord) async throws {
        switch message {
        case .denial:
            decisionAttempts += 1
            if decisionAttempts < 3 { throw RelayError.transport }
            outcome = .denied
        case .sync(let ids):
            syncAttempts += 1
            guard appliedSyncs.insert(msgID).inserted else { return }
            for id in ids {
                _ = receive?(mac.bogoID, nil, .outcome(reqID: id, outcome: outcome))
            }
            if outcome == nil { throw RelayError.transport }
        default:
            break
        }
    }
}

@main
struct EarlySyncProof {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bogoID = Data(repeating: 1, count: 32)
        let reqID = Data(repeating: 2, count: 40)
        let store = try Store(directory: directory)
        try store.save(MacRecord(
            bogoID: bogoID, name: "Mac", keyAccount: "unused",
            approvalPublicKey: Data(), approverID: nil, biometryState: nil,
            state: .active, addedMs: 1, bootSeq: 1
        ))
        let link = EarlySyncLink()
        let phone = PhoneApprover(directory: directory, link: link, clock: { 1000 })
        phone.receive(bogoID, msgID: nil, .request(
            reqID: reqID, bootSeq: 1, bytes: Data(), pauseEpoch: 1, armDelayMs: 0
        ))
        guard let request = phone.records.first,
              phone.deny(request, note: nil) == .decided else {
            fatalError("fixture")
        }
        await phone.flush()
        await phone.flush()
        await phone.flush()
        let unsent = phone.outbox().filter { $0.sentMs == nil }.count
        guard phone.records.first?.phase == .finished(.denied(note: nil), .denied) else {
            print("FAIL S3: decision delivered after early sync answered live; retry reused the applied sync ID")
            print("decision attempts: \(link.decisionAttempts), sync attempts: \(link.syncAttempts), distinct sync IDs: \(link.appliedSyncs.count), unsent rows: \(unsent)")
            print("phase: \(phone.records.first!.phase)")
            exit(1)
        }
        print("PASS")
    }
}
