import Foundation

@MainActor
final class LostResponseLink: MacLink {
    var receive: ((Data, Data?, MacMessage) -> Bool)?
    var applied: ((Data, Data) -> Bool)?
    var attempts: [PhoneMessage] = []
    var accepted = Set<Data>()
    var outcomes: [Data: Outcome] = [:]

    func start(macs: [MacRecord]) {}
    func fetch() async {}
    func offers(excluding macs: [MacRecord]) async -> [RegistrationOffer] { [] }

    func register(_ offer: RegistrationOffer) async throws -> RegistrationChannel {
        throw RelayError.transport
    }

    func seal(_ message: PhoneMessage, msgID: Data, for mac: MacRecord) throws -> Data {
        message.body
    }

    func send(
        _ message: PhoneMessage, sealed: Data, msgID: Data, to mac: MacRecord
    ) async throws {
        attempts.append(message)
        switch message {
        case .denial(let reqID, _):
            if accepted.insert(msgID).inserted {
                outcomes[reqID] = .denied
                throw RelayError.transport
            }
        case .sync(let ids):
            for id in ids {
                if let outcome = outcomes[id] {
                    _ = receive?(
                        mac.bogoID, Data(repeating: 9, count: 16),
                        .outcome(reqID: id, outcome: outcome)
                    )
                }
            }
        default: break
        }
    }
}

@main
enum RetryRecoveryProof {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bogoID = Data(repeating: 1, count: 32)
        let reqID = Data(repeating: 2, count: 40)
        let store = try Store(directory: directory)
        try store.save(MacRecord(
            bogoID: bogoID, name: "Mac", keyAccount: "unused",
            approvalPublicKey: Data(), approverID: nil, biometryState: nil,
            state: .active, addedMs: 1, bootSeq: 1
        ))
        let link = LostResponseLink()
        let phone = PhoneApprover(
            directory: directory, link: link, clock: { 1000 }
        )
        phone.receive(bogoID, msgID: nil, .request(
            reqID: reqID, bootSeq: 1, bytes: Data(),
            pauseEpoch: 1, armDelayMs: 0
        ))
        guard let request = phone.records.first,
              phone.deny(request, note: "wrong amount") == .decided else {
            fatalError("fixture")
        }

        await phone.flush()
        await phone.flush()

        let deliveries = link.attempts.filter {
            if case .denial = $0 { return true }
            return false
        }.count
        guard deliveries == 2 else {
            fatalError("expected original and retry, got \(deliveries)")
        }
        guard phone.records.first?.phase ==
                .finished(.denied(note: "wrong amount"), .denied) else {
            print("FAIL S2: decision accepted by Mac; response and outcome lost; retry delivered, but no sync recovered outcome")
            print("sent: \(link.attempts.map(\.kind)); phase: \(phone.records.first!.phase)")
            exit(1)
        }
        print("PASS")
    }
}
