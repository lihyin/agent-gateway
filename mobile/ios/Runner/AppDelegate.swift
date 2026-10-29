import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?
  private var registration: FlutterResult?
  private var pushToken: String?
  private var registrationGeneration = 0
  private let inboxLimit = 20
  private var actionsURL: URL { inboxURL.deletingLastPathComponent().appendingPathComponent("gateway-push-actions.json") }
  private var inboxURL: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("gateway-push-inbox.json")
  }
  private func inbox(at url: URL? = nil) -> [String] {
    guard let data = try? Data(contentsOf: url ?? inboxURL), let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Array(values.prefix(inboxLimit))
  }
  private func saveInbox(_ values: [String], at destination: URL? = nil) throws {
    let destination = destination ?? inboxURL
    try FileManager.default.createDirectory(at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(values).write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var url = destination
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try url.setResourceValues(resourceValues)
  }
  private func receive(_ userInfo: [AnyHashable: Any]) {
    guard let envelope = userInfo["agw"] as? [String: Any], JSONSerialization.isValidJSONObject(envelope),
          let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
          data.count <= 3500, let encoded = String(data: data, encoding: .utf8),
          let context = envelope["context"] as? [String: Any], let expiry = context["expiresAt"] as? Int,
          expiry > Int(Date().timeIntervalSince1970) else { return }
    var values = inbox()
    values.removeAll { value in
      guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let context = object["context"] as? [String: Any], let expiry = context["expiresAt"] as? Int else { return true }
      return expiry <= Int(Date().timeIntervalSince1970)
    }
    if !values.contains(encoded) && values.count < inboxLimit { values.append(encoded) }
    // Ciphertext only. Storage failure grants no access; Muse retries the same ID.
    try? saveInbox(values)
  }
  override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
    UNUserNotificationCenter.current().delegate = self
    let actions = [
      UNNotificationAction(identifier: "approve", title: "Approve", options: [.foreground, .authenticationRequired]),
      UNNotificationAction(identifier: "review", title: "Review", options: [.foreground]),
      UNNotificationAction(identifier: "deny", title: "Deny", options: [.foreground])
    ]
    UNUserNotificationCenter.current().setNotificationCategories([
      UNNotificationCategory(identifier: "AGW_DATA_REQUEST", actions: actions, intentIdentifiers: [], options: [])
    ])
    if let info = launchOptions?[.remoteNotification] as? [AnyHashable: Any] { receive(info) }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    pushChannel = FlutterMethodChannel(name: "agent_gateway/push", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    pushChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "notifications_unavailable", message: nil, details: nil)); return }
      switch call.method {
      case "register":
        if self.registration != nil { result(FlutterError(code: "registration_busy", message: nil, details: nil)); return }
        self.registration = result
        self.registrationGeneration += 1
        let generation = self.registrationGeneration
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
          DispatchQueue.main.async {
            if !granted { self.finishRegistration(error: true); return }
            UIApplication.shared.registerForRemoteNotifications()
          }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
          if self?.registrationGeneration == generation { self?.finishRegistration(error: true) }
        }
      case "pending":
        UNUserNotificationCenter.current().getDeliveredNotifications { items in
          DispatchQueue.main.async {
            for item in items { self.receive(item.request.content.userInfo) }
            result(self.inbox())
          }
        }
      case "acknowledge":
        guard let encoded = call.arguments as? String else { result(FlutterError(code: "invalid_request", message: nil, details: nil)); return }
        do {
          try self.saveInbox(self.inbox().filter { $0 != encoded })
          UNUserNotificationCenter.current().getDeliveredNotifications { items in
            let ids = items.compactMap { item -> String? in
              guard let envelope = item.request.content.userInfo["agw"] as? [String: Any],
                    let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
                    String(data: data, encoding: .utf8) == encoded else { return nil }
              return item.request.identifier
            }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            DispatchQueue.main.async { result(nil) }
          }
        }
        catch { result(FlutterError(code: "push_storage_unavailable", message: nil, details: nil)) }
      case "actions":
        result(self.inbox(at: self.actionsURL))
      case "acknowledgeAction":
        guard let encoded = call.arguments as? String else { result(FlutterError(code: "invalid_request", message: nil, details: nil)); return }
        do {
          try self.saveInbox(self.inbox(at: self.actionsURL).filter { $0 != encoded }, at: self.actionsURL)
          result(nil)
        } catch { result(FlutterError(code: "push_storage_unavailable", message: nil, details: nil)) }
      case "setBadgeCount":
        guard let count = call.arguments as? Int, count >= 0, count <= self.inboxLimit else { result(FlutterError(code: "invalid_request", message: nil, details: nil)); return }
        if #available(iOS 16.0, *) {
          // Badge presentation must never block encrypted result delivery.
          UNUserNotificationCenter.current().setBadgeCount(count) { _ in
            DispatchQueue.main.async {
              result(nil)
            }
          }
        } else {
          UIApplication.shared.applicationIconBadgeNumber = count
          result(nil)
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  private func finishRegistration(error: Bool) {
    guard let callback = registration else { return }
    registration = nil
    if error { callback(FlutterError(code: "notifications_unavailable", message: nil, details: nil)) } else { callback(pushToken) }
  }
  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let newToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    if pushToken != newToken {
      pushToken = newToken
      pushChannel?.invokeMethod("tokenChanged", arguments: nil)
    }
    finishRegistration(error: false)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }
  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    finishRegistration(error: true)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
  override func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    DispatchQueue.main.async {
      self.receive(notification.request.content.userInfo)
      completionHandler([.banner, .list, .sound, .badge])
    }
  }
  override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    DispatchQueue.main.async {
      self.receive(response.notification.request.content.userInfo)
      if ["approve", "review", "deny"].contains(response.actionIdentifier),
         let envelope = response.notification.request.content.userInfo["agw"] as? [String: Any],
         let context = envelope["context"] as? [String: Any],
         let requestId = context["requestId"] as? String, requestId.count <= 128,
         let expiry = context["expiresAt"] as? Int, expiry > Int(Date().timeIntervalSince1970) {
        let action: [String: Any] = ["action": response.actionIdentifier, "requestId": requestId, "expiresAt": expiry]
        if let data = try? JSONSerialization.data(withJSONObject: action, options: [.sortedKeys]),
           let encoded = String(data: data, encoding: .utf8) {
          var values = self.inbox(at: self.actionsURL).filter { value in
            guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let expiry = object["expiresAt"] as? Int else { return false }
            return expiry > Int(Date().timeIntervalSince1970) && (object["requestId"] as? String) != requestId
          }
          values.append(encoded)
          try? self.saveInbox(Array(values.suffix(self.inboxLimit)), at: self.actionsURL)
          self.pushChannel?.invokeMethod("actionReceived", arguments: nil)
        }
      }
      completionHandler()
    }
  }
}
