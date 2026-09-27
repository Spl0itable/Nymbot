import AVFoundation
import AuthenticationServices
import CryptoKit
import Flutter
import LocalAuthentication
import Security
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "NymbotIntents") {
      Intents.attach(registrar.messenger())
    }
    ShareInbox.drain()
    _ = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      ShareInbox.drain()
    }
    if let registrar = self.registrar(forPlugin: "NymbotDictation") {
      let channel = FlutterMethodChannel(
        name: "ai.nymbot/dictate", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        Dictation.handle(call, result: result)
      }
    }
    if let registrar = self.registrar(forPlugin: "NymbotVaultKey") {
      let channel = FlutterMethodChannel(
        name: "ai.nymbot/vault_key", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        VaultKey.handle(call, result: result)
      }
    }
    if let registrar = self.registrar(forPlugin: "NymbotSecure") {
      let channel = FlutterMethodChannel(
        name: "ai.nymbot/secure", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        SecretClipboard.handle(call, result: result)
      }
    }
    if let registrar = self.registrar(forPlugin: "NymbotReplyNotify") {
      ReplyNotify.register(with: registrar)
    }
    if let registrar = self.registrar(forPlugin: "NymbotPasskey") {
      let channel = FlutterMethodChannel(
        name: "ai.nymbot/passkey", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        Passkeys.handle(call, result: result)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.scheme?.lowercased() == "nymbot" {
      if url.host?.lowercased() == "share" { ShareInbox.drain() }
      return true
    }
    return super.application(app, open: url, options: options)
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
      let url = userActivity.webpageURL
    {
      Intents.deliver(["type": "link", "url": url.absoluteString])
      return true
    }
    return super.application(
      application, continue: userActivity, restorationHandler: restorationHandler)
  }
}

enum Intents {
  private static var channel: FlutterMethodChannel?
  private static var pending: [[String: Any]] = []
  private static var listening = false

  static func attach(_ messenger: FlutterBinaryMessenger) {
    let made = FlutterMethodChannel(name: "ai.nymbot/intents", binaryMessenger: messenger)
    made.setMethodCallHandler { call, result in
      if call.method == "initial" {
        let held = pending
        pending = []
        listening = true
        result(held)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    channel = made
  }

  static func deliver(_ payload: [String: Any]) {
    if listening, let channel = channel {
      channel.invokeMethod("incoming", arguments: payload)
    } else {
      pending.append(payload)
    }
  }
}

enum ShareInbox {
  static let group = "group.ai.nymbot"
  static let maxFileBytes = 50 * 1024 * 1024
  static let maxTotalBytes = 80 * 1024 * 1024
  static let maxFiles = 10
  private static let queue = DispatchQueue(label: "ai.nymbot.share-inbox")
  private static let stale: TimeInterval = 3600

  static func drain() {
    queue.async {
      let found = collect()
      if found.isEmpty { return }
      DispatchQueue.main.async {
        for payload in found { Intents.deliver(payload) }
      }
    }
  }

  static func collect() -> [[String: Any]] {
    let manager = FileManager.default
    guard
      let root = manager.containerURL(forSecurityApplicationGroupIdentifier: group)?
        .appendingPathComponent("ShareInbox", isDirectory: true),
      let entries = try? manager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.creationDateKey],
        options: [.skipsHiddenFiles])
    else {
      return []
    }
    let dated = entries.map { entry -> (URL, Date) in
      let made = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
      return (entry, made)
    }
    var found: [[String: Any]] = []
    for (entry, made) in dated.sorted(by: { $0.1 < $1.1 }) {
      guard let data = try? Data(contentsOf: entry.appendingPathComponent("manifest.json")) else {
        if Date().timeIntervalSince(made) > stale { try? manager.removeItem(at: entry) }
        continue
      }
      defer { try? manager.removeItem(at: entry) }
      guard let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        continue
      }
      if let payload = payload(manifest, in: entry) { found.append(payload) }
    }
    return found
  }

  private static func payload(_ manifest: [String: Any], in folder: URL) -> [String: Any]? {
    let text = (manifest["text"] as? String) ?? ""
    var files: [[String: Any]] = []
    var total = 0
    for item in (manifest["files"] as? [[String: Any]] ?? []).prefix(maxFiles) {
      guard
        let stored = item["file"] as? String,
        stored.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
      else { continue }
      let url = folder.appendingPathComponent(stored)
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
      guard size <= maxFileBytes, total + size <= maxTotalBytes,
        let bytes = try? Data(contentsOf: url)
      else { continue }
      total += bytes.count
      files.append([
        "name": label(item["name"] as? String ?? ""),
        "bytes": FlutterStandardTypedData(bytes: bytes),
      ])
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty {
      return nil
    }
    return ["type": "share", "text": text, "files": files]
  }

  static func label(_ raw: String) -> String {
    var name = raw.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? ""
    name = String(
      String.UnicodeScalarView(
        name.unicodeScalars.filter {
          !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }))
    name = name.trimmingCharacters(in: .whitespaces)
    while name.hasPrefix(".") { name.removeFirst() }
    name = name.trimmingCharacters(in: .whitespaces)
    if name.count > 120 {
      let ext = (name as NSString).pathExtension
      let tail = ext.isEmpty || ext.count > 9 ? "" : ".\(ext)"
      name = String(name.prefix(120 - tail.count)) + tail
    }
    return name.isEmpty ? "shared" : name
  }
}

enum SecretClipboard {
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "copySecret":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let text = args["text"] as? String else {
        result(FlutterError(code: "failed", message: nil, details: nil))
        return
      }
      let seconds = (args["seconds"] as? NSNumber)?.doubleValue ?? 60
      UIPasteboard.general.setItems(
        [[UTType.plainText.identifier: text]],
        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(seconds)])
      result(true)
    case "secure":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

enum VaultKey {
  private static let base: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "ai.nymbot.vault",
    kSecAttrAccount as String: "vault_key",
  ]

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
    switch call.method {
    case "store":
      guard let secret = args["secret"] as? String, let data = secret.data(using: .utf8) else {
        result(FlutterError(code: "failed", message: nil, details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async { reply(store(data)) }
    case "load":
      let title = args["title"] as? String ?? ""
      let cancel = args["cancel"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async { reply(load(title, cancel)) }
    case "erase":
      DispatchQueue.global(qos: .userInitiated).async {
        SecItemDelete(base as CFDictionary)
        reply(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func store(_ data: Data) -> Any? {
    SecItemDelete(base as CFDictionary)
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil)
    else {
      return FlutterError(code: "unavailable", message: nil, details: nil)
    }
    var query = base
    query[kSecAttrAccessControl as String] = access
    query[kSecValueData as String] = data
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecSuccess { return nil }
    return failure(status)
  }

  private static func load(_ title: String, _ cancel: String) -> Any? {
    let context = LAContext()
    context.localizedReason = title
    context.localizedCancelTitle = cancel
    context.localizedFallbackTitle = ""
    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = context
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { return failure(status) }
    guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
      return FlutterError(code: "failed", message: nil, details: nil)
    }
    return secret
  }

  private static func failure(_ status: OSStatus) -> FlutterError {
    let message = SecCopyErrorMessageString(status, nil) as String?
    switch status {
    case errSecUserCanceled:
      return FlutterError(code: "cancelled", message: message, details: nil)
    case errSecNotAvailable, errSecInteractionNotAllowed:
      return FlutterError(code: "unavailable", message: message, details: nil)
    default:
      return FlutterError(code: "failed", message: message, details: nil)
    }
  }
}

enum Dictation {
  private static var recorder: AVAudioRecorder?

  private static var file: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("dictation.m4a")
  }

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async {
          if !granted {
            result(FlutterError(code: "denied", message: nil, details: nil))
            return
          }
          result(begin())
        }
      }
    case "stop":
      result(finish(keep: true))
    case "level":
      result(level())
    case "cancel":
      _ = finish(keep: false)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func begin() -> Any {
    _ = finish(keep: false)
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
      try session.setActive(true)
      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32000,
      ]
      let made = try AVAudioRecorder(url: file, settings: settings)
      made.isMeteringEnabled = true
      guard made.record() else {
        return FlutterError(code: "unavailable", message: nil, details: nil)
      }
      recorder = made
      return true
    } catch {
      return FlutterError(code: "unavailable", message: error.localizedDescription, details: nil)
    }
  }

  private static func level() -> Any? {
    guard let made = recorder, made.isRecording else { return nil }
    made.updateMeters()
    let power = Double(made.averagePower(forChannel: 0))
    guard power.isFinite else { return nil }
    return max(0.0, min(1.0, (power + 60.0) / 60.0))
  }

  private static func finish(keep: Bool) -> Any? {
    guard let made = recorder else { return nil }
    recorder = nil
    made.stop()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    defer { try? FileManager.default.removeItem(at: file) }
    guard keep, let data = try? Data(contentsOf: file) else { return nil }
    return FlutterStandardTypedData(bytes: data)
  }
}

enum Passkeys {
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      if #available(iOS 17.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "create", "get":
      guard #available(iOS 17.0, *) else {
        result(FlutterError(code: "unavailable", message: nil, details: nil))
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      guard
        let text = args["request"] as? String,
        let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
        let request = parsed as? [String: Any]
      else {
        result(FlutterError(code: "failed", message: "bad request", details: nil))
        return
      }
      PasskeyFlow.start(create: call.method == "create", request: request, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func bytes(_ value: Any?) -> Data? {
    guard var text = value as? String, !text.isEmpty else { return nil }
    text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while text.count % 4 != 0 { text += "=" }
    return Data(base64Encoded: text)
  }

  static func text(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

@available(iOS 17.0, *)
final class PasskeyFlow: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  private static var running: PasskeyFlow?

  private let result: FlutterResult
  private var controller: ASAuthorizationController?

  private init(result: @escaping FlutterResult) {
    self.result = result
  }

  static func start(create: Bool, request: [String: Any], result: @escaping FlutterResult) {
    if running != nil {
      result(FlutterError(code: "busy", message: nil, details: nil))
      return
    }
    let extensions = request["extensions"] as? [String: Any] ?? [:]
    let prf = (extensions["prf"] as? [String: Any])?["eval"] as? [String: Any]
    let prfSalt = Passkeys.bytes(prf?["first"])
    let largeBlob = extensions["largeBlob"] as? [String: Any]
    guard let challenge = Passkeys.bytes(request["challenge"]) else {
      result(FlutterError(code: "failed", message: "bad challenge", details: nil))
      return
    }
    let authorization: ASAuthorizationRequest
    if create {
      let rp = request["rp"] as? [String: Any] ?? [:]
      let user = request["user"] as? [String: Any] ?? [:]
      guard
        let rpId = rp["id"] as? String,
        let name = user["name"] as? String,
        let userId = Passkeys.bytes(user["id"])
      else {
        result(FlutterError(code: "failed", message: "bad request", details: nil))
        return
      }
      let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
        relyingPartyIdentifier: rpId)
      let made = provider.createCredentialRegistrationRequest(
        challenge: challenge, name: name, userID: userId)
      made.userVerificationPreference = .required
      if let support = largeBlob?["support"] as? String {
        if support == "required" {
          made.largeBlob = .supportRequired
        } else {
          made.largeBlob = .supportPreferred
        }
      }
      if #available(iOS 18.0, *), let salt = prfSalt {
        made.prf = .inputValues(
          ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues(saltInput1: salt))
      }
      authorization = made
    } else {
      guard let rpId = request["rpId"] as? String else {
        result(FlutterError(code: "failed", message: "bad request", details: nil))
        return
      }
      let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
        relyingPartyIdentifier: rpId)
      let asked = provider.createCredentialAssertionRequest(challenge: challenge)
      asked.userVerificationPreference = .required
      let allowed = (request["allowCredentials"] as? [[String: Any]] ?? []).compactMap {
        Passkeys.bytes($0["id"])
      }
      if !allowed.isEmpty {
        asked.allowedCredentials = allowed.map {
          ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
      }
      if let write = Passkeys.bytes(largeBlob?["write"]) {
        asked.largeBlob = .write(write)
      } else if largeBlob?["read"] as? Bool == true {
        asked.largeBlob = .read
      }
      if #available(iOS 18.0, *), let salt = prfSalt {
        asked.prf = .inputValues(
          ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues(saltInput1: salt))
      }
      authorization = asked
    }
    let flow = PasskeyFlow(result: result)
    let controller = ASAuthorizationController(authorizationRequests: [authorization])
    controller.delegate = flow
    controller.presentationContextProvider = flow
    flow.controller = controller
    running = flow
    controller.performRequests()
  }

  private func finish(_ value: Any?) {
    PasskeyFlow.running = nil
    controller = nil
    result(value)
  }

  private static func key(_ key: SymmetricKey) -> String {
    Passkeys.text(key.withUnsafeBytes { Data($0) })
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    var extensions: [String: Any] = [:]
    let id: Data
    if let made = authorization.credential
      as? ASAuthorizationPlatformPublicKeyCredentialRegistration
    {
      id = made.credentialID
      if let blob = made.largeBlob {
        extensions["largeBlob"] = ["supported": blob.isSupported]
      }
      if #available(iOS 18.0, *), let prf = made.prf {
        var out: [String: Any] = ["enabled": prf.isSupported]
        if let first = prf.first {
          out["results"] = ["first": PasskeyFlow.key(first)]
        }
        extensions["prf"] = out
      }
    } else if let got = authorization.credential
      as? ASAuthorizationPlatformPublicKeyCredentialAssertion
    {
      id = got.credentialID
      if let blob = got.largeBlob {
        var out: [String: Any] = ["written": false]
        switch blob.result {
        case .read(let data):
          if let data = data {
            out["blob"] = Passkeys.text(data)
          }
        case .write(let success):
          out["written"] = success
        @unknown default:
          break
        }
        extensions["largeBlob"] = out
      }
      if #available(iOS 18.0, *), let prf = got.prf {
        extensions["prf"] = ["results": ["first": PasskeyFlow.key(prf.first)]]
      }
    } else {
      finish(FlutterError(code: "failed", message: "unexpected credential", details: nil))
      return
    }
    let response: [String: Any] = [
      "id": Passkeys.text(id),
      "rawId": Passkeys.text(id),
      "type": "public-key",
      "clientExtensionResults": extensions,
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: response),
      let json = String(data: data, encoding: .utf8)
    else {
      finish(FlutterError(code: "failed", message: nil, details: nil))
      return
    }
    finish(json)
  }

  func authorizationController(
    controller: ASAuthorizationController, didCompleteWithError error: Error
  ) {
    if let failure = error as? ASAuthorizationError, failure.code == .canceled {
      finish(FlutterError(code: "cancelled", message: nil, details: nil))
    } else {
      finish(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
    }
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
  }
}
