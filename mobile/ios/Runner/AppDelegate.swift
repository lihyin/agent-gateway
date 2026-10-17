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
  private var inboxURL: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("gateway-push-inbox.json")
  }
  private func inbox() -> [String] {
    guard let data = try? Data(contentsOf: inboxURL), let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Array(values.prefix(inboxLimit))
  }
  private func saveInbox(_ values: [String]) throws {
    try FileManager.default.createDirectory(at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(values).write(to: inboxURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var url = inboxURL
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
    pushToken = deviceToken.map { String(format: "%02x", $0) }.joined()
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
      completionHandler([.banner, .sound])
    }
  }
  override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    DispatchQueue.main.async {
      self.receive(response.notification.request.content.userInfo)
      completionHandler()
    }
  }
}
