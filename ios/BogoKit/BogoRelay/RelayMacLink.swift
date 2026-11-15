import BogoCrypto
import BogoModel
import CryptoKit
import Foundation

/// The real link to BOGO on a Mac: HPKE envelopes in relay mailboxes, one
/// mailbox per registered Mac (ARCHITECTURE §3.11, §3.13 BogoRelay).
///
/// Inbound order for every message: drop a known message ID unopened, open and
/// check it, apply it to the store, and only then acknowledge it to the relay.
/// A message the store can't take yet stays in the mailbox and is fetched again.
@MainActor
public final class RelayMacLink: MacLink {
    public var receive: ((Data, Data?, MacMessage) -> Bool)?
    public var applied: ((Data, Data) -> Bool)?
    public let endpoint: RelayEndpoint

    private struct Mailbox {
        let route: MacRoute
        let task: Task<Void, Never>
        let client: RelayClient
    }

    private var mailboxes: [Data: Mailbox] = [:]
    private var macs: [Data: MacRecord] = [:]
    private var keys: [String: ChannelKeys] = [:]
    /// The relay identity Add Mac browses the lobby with; the offer the owner
    /// picks is claimed with it, so it becomes that Mac's `phoneRelay` key.
    private var candidate: (keys: ChannelKeys, client: RelayClient)?

    public init(endpoint: RelayEndpoint) {
        self.endpoint = endpoint
    }

    public func start(macs: [MacRecord]) {
        let relayed = macs.filter { $0.route != nil && $0.approverID != nil }
        self.macs = Dictionary(uniqueKeysWithValues: relayed.map { ($0.bogoID, $0) })
        for (bogoID, mailbox) in mailboxes where self.macs[bogoID]?.route != mailbox.route {
            mailbox.task.cancel()
            mailboxes[bogoID] = nil
            if self.macs[bogoID] == nil {
                ChannelKeys.delete(account: mailbox.route.channelAccount)
                keys[mailbox.route.channelAccount] = nil
            }
        }
        for mac in relayed where mailboxes[mac.bogoID] == nil {
            guard let route = mac.route, let channel = channelKeys(route) else { continue }
            let client = RelayClient(endpoint: endpoint, key: channel.relay)
            let bogoID = mac.bogoID
            let task = Task { [weak self] in _ = await self?.poll(bogoID, client: client, route: route) }
            mailboxes[bogoID] = Mailbox(route: route, task: task, client: client)
        }
    }

    public func fetch() async {
        for (bogoID, mailbox) in mailboxes {
            guard let batch = try? await mailbox.client.fetch(wait: false) else { continue }
            await apply(batch, bogoID: bogoID, client: mailbox.client)
        }
    }

    public func seal(_ message: PhoneMessage, msgID: Data, for mac: MacRecord) throws -> Data {
        guard let route = mac.route, let approverID = mac.approverID, let channel = channelKeys(route) else { throw RelayError.wire }
        return try Channel.seal(sender: channel.e2e, recipient: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: route.macE2E),
                                bogoID: mac.bogoID, approverID: approverID, direction: .phoneToMac, kind: message.typeByte, msgID: msgID,
                                plaintext: message.body)
    }

    public func send(_ message: PhoneMessage, sealed: Data, msgID: Data, to mac: MacRecord) async throws {
        guard let route = mac.route, let mailbox = mailboxes[mac.bogoID] else { throw RelayError.transport }
        try await mailbox.client.send(to: route.macMailbox, msgID: msgID, envelope: sealed)
    }

    public func offers(excluding macs: [MacRecord]) async -> [RegistrationOffer] {
        let browsing = candidate ?? {
            let keys = ChannelKeys()
            return (keys, RelayClient(endpoint: endpoint, key: keys.relay))
        }()
        candidate = browsing
        guard let listed = try? await browsing.client.offers() else { return [] }
        return listed.map { RegistrationOffer(id: Hex.string($0.offerID) + Hex.string($0.ePubM), label: $0.label,
                                              opened: Date().addingTimeInterval(-TimeInterval($0.ageSeconds))) }
    }

    public func register(_ offer: RegistrationOffer) async throws -> RegistrationChannel {
        guard let browsing = candidate, let raw = Hex.data(offer.id), raw.count == 48 else { throw RegistrationError.macCancelled }
        // A claimed offer binds this relay key; the next attempt browses with a new one.
        candidate = nil
        let lobby = LobbyOffer(offerID: raw.prefix(16), ePubM: raw.suffix(32), label: offer.label, ageSeconds: 0)
        return try await RelayRegistration.begin(client: browsing.client, keys: browsing.keys, offer: lobby)
    }

    private func channelKeys(_ route: MacRoute) -> ChannelKeys? {
        if let cached = keys[route.channelAccount] { return cached }
        let loaded = ChannelKeys.load(account: route.channelAccount)
        keys[route.channelAccount] = loaded
        return loaded
    }

    /// One long-poll at a time per mailbox, with backoff while the relay is unreachable.
    private func poll(_ bogoID: Data, client: RelayClient, route: MacRoute) async {
        var allowed = false
        var backoff: Duration = .milliseconds(500)
        while !Task.isCancelled {
            do {
                if !allowed {
                    try await client.allow([route.macMailbox])
                    allowed = true
                }
                let batch = try await client.fetch(wait: true)
                backoff = .milliseconds(500)
                let progressed = await apply(batch, bogoID: bogoID, client: client)
                if !batch.isEmpty && !progressed { try? await Task.sleep(for: .seconds(2)) }
            } catch {
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(15))
            }
        }
    }

    @discardableResult
    private func apply(_ batch: [RelayMessage], bogoID: Data, client: RelayClient) async -> Bool {
        var acked: [String] = []
        for message in batch {
            if handle(message, bogoID: bogoID) { acked.append(message.msgID) }
        }
        guard !acked.isEmpty else { return false }
        try? await client.ack(acked)
        return true
    }

    /// True when the message may be acknowledged: applied durably, already
    /// applied before, or dropped because it can't be authenticated.
    private func handle(_ message: RelayMessage, bogoID: Data) -> Bool {
        guard let mac = macs[bogoID], let route = mac.route, let approverID = mac.approverID, message.from == route.macMailbox,
              let msgID = Channel.peekID(message.body), Hex.string(msgID) == message.msgID else { return true }
        if applied?(bogoID, msgID) == true { return true }
        guard let channel = channelKeys(route), let macKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: route.macE2E),
              let opened = try? Channel.open(recipient: channel.e2e, sender: macKey, bogoID: bogoID, approverID: approverID,
                                             direction: .macToPhone, envelope: message.body),
              let parsed = MacMessage(kind: opened.kind, body: opened.plaintext) else { return true }
        return receive?(bogoID, msgID, parsed) ?? false
    }
}

#if DEBUG
/// Debug builds keep the in-process stand-in Mac beside the real relay link,
/// so the section still works without a Mac. A Mac with a relay route goes to
/// the relay; the stand-in Mac has none.
@MainActor
public final class DebugMacLinks: MacLink {
    public let relay: RelayMacLink
    public let standIn: StandInMacLink

    public var receive: ((Data, Data?, MacMessage) -> Bool)? {
        didSet {
            relay.receive = receive
            standIn.receive = receive
        }
    }

    public var applied: ((Data, Data) -> Bool)? {
        didSet {
            relay.applied = applied
            standIn.applied = applied
        }
    }

    public init(relay: RelayMacLink, standIn: StandInMacLink) {
        self.relay = relay
        self.standIn = standIn
    }

    public func start(macs: [MacRecord]) {
        relay.start(macs: macs)
        standIn.start(macs: macs.filter { $0.route == nil })
    }

    public func fetch() async {
        await relay.fetch()
        await standIn.fetch()
    }

    public func seal(_ message: PhoneMessage, msgID: Data, for mac: MacRecord) throws -> Data {
        mac.route == nil ? try standIn.seal(message, msgID: msgID, for: mac) : try relay.seal(message, msgID: msgID, for: mac)
    }

    public func send(_ message: PhoneMessage, sealed: Data, msgID: Data, to mac: MacRecord) async throws {
        if mac.route == nil {
            try await standIn.send(message, sealed: sealed, msgID: msgID, to: mac)
        } else {
            try await relay.send(message, sealed: sealed, msgID: msgID, to: mac)
        }
    }

    public func offers(excluding macs: [MacRecord]) async -> [RegistrationOffer] {
        await relay.offers(excluding: macs) + standIn.offers(excluding: macs)
    }

    public func register(_ offer: RegistrationOffer) async throws -> RegistrationChannel {
        offer.id == StandInMacLink.offerID ? try await standIn.register(offer) : try await relay.register(offer)
    }
}
#endif
