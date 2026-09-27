import Flutter
import UIKit
import UserNotifications

final class ReplyNotify: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  private static var shared: ReplyNotify?

  private let channel: FlutterMethodChannel
  private var token: String?
  private var waiting: [FlutterResult] = []
  private var viewing: String?
  private var pendingChat: String?
  private var tasks: [Int: UIBackgroundTaskIdentifier] = [:]
  private var nextTask = 1

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "ai.nymbot/notify", binaryMessenger: registrar.messenger())
    let instance = ReplyNotify(channel: channel)
    shared = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    UNUserNotificationCenter.current().delegate = instance
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "permission":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
        granted, _ in
        DispatchQueue.main.async {
          if granted { UIApplication.shared.registerForRemoteNotifications() }
          result(granted)
        }
      }
    case "token":
      fetchToken(result)
    case "reply":
      showReply(args, result: result)
    case "viewing":
      viewing = args["chat"] as? String
      clearDelivered(for: viewing)
      result(nil)
    case "initial":
      let chat = pendingChat
      pendingChat = nil
      result(chat)
    case "beginBackground":
      result(beginBackground())
    case "endBackground":
      endBackground((args["id"] as? NSNumber)?.intValue ?? 0)
      result(nil)
    case "wait", "stopWaiting":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func fetchToken(_ result: @escaping FlutterResult) {
    if let token = token {
      result(token)
      return
    }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        let status = settings.authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else {
          result(nil)
          return
        }
        if let token = self.token {
          result(token)
          return
        }
        self.waiting.append(result)
        UIApplication.shared.registerForRemoteNotifications()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.flush() }
      }
    }
  }

  private func flush() {
    let held = waiting
    waiting = []
    for result in held { result(token) }
  }

  private func showReply(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let chat = args["chat"] as? String else {
      result(false)
      return
    }
    let content = UNMutableNotificationContent()
    content.title = args["title"] as? String ?? "Nymbot"
    content.body = args["body"] as? String ?? ""
    content.sound = .default
    content.threadIdentifier = chat
    content.userInfo = ["chat": chat]
    let request = UNNotificationRequest(identifier: "reply-" + chat, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
      DispatchQueue.main.async { result(error == nil) }
    }
  }

  private func clearDelivered(for chat: String?) {
    guard let chat = chat else { return }
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { delivered in
      let ids = delivered
        .filter { ($0.request.content.userInfo["chat"] as? String) == chat }
        .map { $0.request.identifier }
      if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
  }

  private func beginBackground() -> Int {
    let id = nextTask
    nextTask += 1
    let task = UIApplication.shared.beginBackgroundTask(withName: "nymbot-reply-notify") {
      [weak self] in
      self?.endBackground(id)
    }
    if task == .invalid { return 0 }
    tasks[id] = task
    return id
  }

  private func endBackground(_ id: Int) {
    guard let task = tasks.removeValue(forKey: id) else { return }
    UIApplication.shared.endBackgroundTask(task)
  }

  private func open(_ chat: String) {
    pendingChat = chat
    channel.invokeMethod("open", arguments: chat) { [weak self] reply in
      guard let self = self else { return }
      if reply is FlutterError { return }
      if let r = reply as? NSObject, r === FlutterMethodNotImplemented { return }
      if self.pendingChat == chat { self.pendingChat = nil }
    }
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    token = deviceToken.map { String(format: "%02x", $0) }.joined()
    flush()
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    flush()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let chat = notification.request.content.userInfo["chat"] as? String
    if chat != nil && chat == viewing && UIApplication.shared.applicationState == .active {
      completionHandler([])
      return
    }
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let chat = response.notification.request.content.userInfo["chat"] as? String {
      open(chat)
    }
    completionHandler()
  }
}
