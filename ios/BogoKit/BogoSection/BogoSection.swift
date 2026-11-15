import BogoModel
import BogoRelay
import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

public enum BogoAPNsEnvironment: String, Sendable {
    case development, production
}

@MainActor
public protocol BogoHost: AnyObject {
    var pushToken: Data? { get }
    var apnsEnvironment: BogoAPNsEnvironment { get }
}

public struct BogoWake: Sendable, Equatable {
    public let mac: String
    public let rid: String
}

@MainActor
@Observable
public final class BogoSection {
    public static let requestCategory = "bogo.request"
    public static let denyAction = "bogo.deny"

    public private(set) var focusRequests = 0
    var page: BogoPage = .inbox
    var reviewing: String?
    let approver: PhoneApprover
    @ObservationIgnored private weak var host: BogoHost?

    public init(host: BogoHost, storageDirectory: URL, relayURL: URL) {
        self.host = host
        #if DEBUG
        let link: MacLink = StandInMacLink(directory: storageDirectory.appendingPathComponent("stand-in"))
        #else
        let link: MacLink = UnlinkedMacLink()
        #endif
        approver = PhoneApprover(directory: storageDirectory, link: link)
        approver.pushToken = host.pushToken
    }

    public var tab: some View {
        BogoTab(section: self)
    }

    public static var notificationCategories: Set<UNNotificationCategory> {
        let deny = UNNotificationAction(identifier: denyAction, title: "Deny", options: [.destructive])
        return [UNNotificationCategory(identifier: requestCategory, actions: [deny], intentIdentifiers: [])]
    }

    public nonisolated static func owns(_ userInfo: [AnyHashable: Any]) -> Bool {
        wake(userInfo) != nil
    }

    public nonisolated static func wake(_ userInfo: [AnyHashable: Any]) -> BogoWake? {
        guard let payload = userInfo["bogo"] as? [String: Any] else { return nil }
        return BogoWake(mac: payload["mac"] as? String ?? "", rid: payload["rid"] as? String ?? "")
    }

    public func remoteNotification(_ wake: BogoWake) async -> UIBackgroundFetchResult {
        await approver.link.fetch()
        await approver.flush()
        return approver.record(bogoPrefix: wake.mac, reqID: wake.rid) == nil ? .noData : .newData
    }

    public func notificationResponse(_ wake: BogoWake, action: String) async {
        await approver.link.fetch()
        guard let record = approver.record(bogoPrefix: wake.mac, reqID: wake.rid) else { return }
        if action == Self.denyAction {
            _ = approver.deny(record, note: nil)
            await approver.flush()
        } else if action == UNNotificationDefaultActionIdentifier {
            page = .inbox
            reviewing = record.id
            focusRequests += 1
        }
    }

    public func pushTokenChanged(_ token: Data) {
        approver.pushToken = token
    }

    public func sceneBecameActive() async {
        approver.pushToken = host?.pushToken ?? approver.pushToken
        await approver.becameActive()
    }
}
