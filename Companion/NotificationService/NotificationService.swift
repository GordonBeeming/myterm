import Foundation
import MyTermRemote
import UserNotifications

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let delivery = NotificationDelivery()

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let fallback = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        fallback.title = "MyTerm"
        fallback.body = "MyTerm needs attention"
        let generation = delivery.install(completion: contentHandler, fallback: fallback)
        let working = (fallback.mutableCopy() as? UNMutableNotificationContent) ?? fallback
        let eventData = try? request.content.userInfo["event"].map {
            try JSONSerialization.data(withJSONObject: $0)
        }
        let box = NotificationContentBox(working)
        let delivery = delivery
        Task { @MainActor [weak self] in
            let content = await self?.decrypt(eventData: eventData, fallback: box) ?? box.content
            delivery.complete(with: content, generation: generation)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        delivery.completeWithFallback()
    }

    @MainActor
    private func decrypt(eventData: Data?, fallback box: NotificationContentBox) async -> UNNotificationContent {
        let fallback = box.content
        do {
            guard let gateway = AppConfiguration.pushGateway,
                  let eventData else {
                throw RemoteError.invalidMessage
            }
            let event = try JSONDecoder().decode(PushAPNSEvent.self, from: eventData)
            let secrets = KeychainSecretStore(
                service: "\(AppConfiguration.bundleIdentifier).push",
                accessGroup: AppConfiguration.sharedKeychainGroup,
                accessibility: .notificationExtension
            )
            let scopeID = try await LocalDeviceIDStore(secrets: secrets,
                                                       account: "push-scope-id-v1").loadOrCreate()
            let pinStore = PushRecipientGrantPinStore(secrets: secrets, gateway: gateway,
                                                      accountID: scopeID)
            guard let pin = try await pinStore.pin(grantID: event.grantID,
                                                   recipientID: event.recipientID) else {
                throw RemoteError.wrongPeer
            }
            let key = try await PushNotificationIdentityStore(
                secrets: secrets, gateway: gateway, accountID: scopeID
            ).loadOrCreate()
            let plaintext = try PushNotificationCrypto.open(event, using: pin,
                                                            recipientPrivateKey: key)
            try await PushReplayStore(secrets: secrets, gateway: gateway,
                                      accountID: scopeID).consume(eventID: event.eventID,
                                                                  timestamp: event.timestamp)
            guard let route = try await NotificationRouteStore(secrets: secrets)
                .reference(grantID: event.grantID) else { throw RemoteError.wrongPeer }
            guard route.relayOrigin == pin.relayOrigin.canonicalOrigin,
                  route.accountID == pin.relayAccountID,
                  route.hostID == pin.hostID else { throw RemoteError.wrongPeer }
            fallback.title = plaintext.title
            fallback.body = plaintext.body
            fallback.userInfo["relay_origin"] = route.relayOrigin
            fallback.userInfo["account_id"] = route.accountID.uuidString.lowercased()
            fallback.userInfo["host_id"] = route.hostID.uuidString.lowercased()
            fallback.userInfo["workspace_id"] = plaintext.workspaceID?.uuidString.lowercased()
            fallback.userInfo["tab_id"] = plaintext.tabID?.uuidString.lowercased()
            fallback.userInfo["session_id"] = plaintext.sessionID?.uuidString.lowercased()
            return fallback
        } catch {
            return fallback
        }
    }
}

private final class NotificationContentBox: @unchecked Sendable {
    let content: UNMutableNotificationContent
    init(_ content: UNMutableNotificationContent) { self.content = content }
}

private final class NotificationDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?
    private var generation: UUID?

    func install(completion: @escaping (UNNotificationContent) -> Void,
                 fallback: UNNotificationContent) -> UUID {
        let nextGeneration = UUID()
        let previous = lock.withLock { () -> (((UNNotificationContent) -> Void), UNNotificationContent)? in
            defer {
                self.completion = completion; self.fallback = fallback
                generation = nextGeneration
            }
            guard let oldCompletion = self.completion, let oldFallback = self.fallback else { return nil }
            return (oldCompletion, oldFallback)
        }
        if let previous { previous.0(previous.1) }
        return nextGeneration
    }

    func complete(with content: UNNotificationContent, generation: UUID) {
        let completion = takeCompletion(generation: generation)
        completion?(content)
    }

    func completeWithFallback() {
        let value = lock.withLock { () -> (((UNNotificationContent) -> Void), UNNotificationContent)? in
            guard let completion, let fallback else { return nil }
            self.completion = nil; self.fallback = nil; generation = nil
            return (completion, fallback)
        }
        if let value { value.0(value.1) }
    }

    private func takeCompletion(generation: UUID) -> ((UNNotificationContent) -> Void)? {
        lock.withLock {
            guard self.generation == generation else { return nil }
            defer { completion = nil; fallback = nil; self.generation = nil }
            return completion
        }
    }
}
