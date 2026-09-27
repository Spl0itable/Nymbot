import Security
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private static let group = "group.ai.nymbot"
  private static let maxFileBytes = 50 * 1024 * 1024
  private static let maxTotalBytes = 80 * 1024 * 1024
  private static let maxFiles = 10
  private static let maxTextLength = 200_000

  private let lock = NSLock()
  private var started = false
  private var texts: [String] = []
  private var files: [[String: String]] = []
  private var total = 0
  private var folder: URL?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if started { return }
    started = true
    guard
      let root = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: ShareViewController.group)
    else {
      finish()
      return
    }
    let made = root.appendingPathComponent("ShareInbox", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    } catch {
      finish()
      return
    }
    folder = made
    let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
    take(providers[...])
  }

  private func take(_ rest: ArraySlice<NSItemProvider>) {
    guard let provider = rest.first else {
      DispatchQueue.main.async { self.deliver() }
      return
    }
    load(provider) { [weak self] in
      self?.take(rest.dropFirst())
    }
  }

  private func load(_ provider: NSItemProvider, then next: @escaping () -> Void) {
    let url = UTType.url.identifier
    let fileURL = UTType.fileURL.identifier
    if provider.hasItemConformingToTypeIdentifier(url),
      !provider.hasItemConformingToTypeIdentifier(fileURL)
    {
      provider.loadItem(forTypeIdentifier: url, options: nil) { item, _ in
        if let link = item as? URL, !link.isFileURL {
          self.add(text: link.absoluteString)
        } else if let link = item as? URL {
          self.copy(link, name: provider.suggestedName, type: nil)
        } else if let data = item as? Data, let link = URL(dataRepresentation: data, relativeTo: nil) {
          self.add(text: link.absoluteString)
        }
        next()
      }
      return
    }
    for type in [UTType.movie, UTType.image, UTType.pdf, UTType.data] {
      if type == .data, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        break
      }
      if provider.hasItemConformingToTypeIdentifier(type.identifier) {
        loadFile(provider, type: type, then: next)
        return
      }
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
        if let text = item as? String {
          self.add(text: text)
        } else if let link = item as? URL, link.isFileURL {
          self.copy(link, name: provider.suggestedName, type: .plainText)
        } else if let link = item as? URL {
          self.add(text: link.absoluteString)
        } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
          self.add(text: text)
        }
        next()
      }
      return
    }
    next()
  }

  private func loadFile(_ provider: NSItemProvider, type: UTType, then next: @escaping () -> Void) {
    let identifier =
      provider.registeredTypeIdentifiers.first { id in
        UTType(id)?.conforms(to: type) ?? false
      } ?? type.identifier
    provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
      if let url = url {
        self.copy(url, name: provider.suggestedName, type: UTType(identifier))
        next()
        return
      }
      provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
        if let link = item as? URL, link.isFileURL {
          self.copy(link, name: provider.suggestedName, type: UTType(identifier))
        } else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
          self.write(data, name: provider.suggestedName, type: .jpeg)
        } else if let data = item as? Data {
          self.write(data, name: provider.suggestedName, type: UTType(identifier))
        }
        next()
      }
    }
  }

  private func add(text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    lock.lock()
    defer { lock.unlock() }
    let used = texts.reduce(0) { $0 + $1.count }
    if used >= ShareViewController.maxTextLength { return }
    texts.append(String(trimmed.prefix(ShareViewController.maxTextLength - used)))
  }

  private func room(for size: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return files.count < ShareViewController.maxFiles
      && size <= ShareViewController.maxFileBytes
      && total + size <= ShareViewController.maxTotalBytes
  }

  private func copy(_ source: URL, name: String?, type: UTType?) {
    guard let folder = folder else { return }
    let reading = source.startAccessingSecurityScopedResource()
    defer { if reading { source.stopAccessingSecurityScopedResource() } }
    let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
    guard room(for: size) else { return }
    let stored = ShareViewController.randomName()
    do {
      try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(stored))
    } catch {
      return
    }
    let label = ShareViewController.label(
      name ?? source.lastPathComponent, fallback: source.pathExtension, type: type)
    record(stored: stored, label: label, size: size)
  }

  private func write(_ data: Data, name: String?, type: UTType?) {
    guard let folder = folder, room(for: data.count) else { return }
    let stored = ShareViewController.randomName()
    do {
      try data.write(to: folder.appendingPathComponent(stored), options: .atomic)
    } catch {
      return
    }
    let label = ShareViewController.label(name ?? "", fallback: "", type: type)
    record(stored: stored, label: label, size: data.count)
  }

  private func record(stored: String, label: String, size: Int) {
    lock.lock()
    defer { lock.unlock() }
    files.append(["name": label, "file": stored])
    total += size
  }

  private static func randomName() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func label(_ raw: String, fallback: String, type: UTType?) -> String {
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
    if name.isEmpty { name = "shared" }
    if (name as NSString).pathExtension.isEmpty {
      if let ext = type?.preferredFilenameExtension {
        name += ".\(ext)"
      } else if !fallback.isEmpty, fallback.count <= 9 {
        name += ".\(fallback)"
      }
    }
    return name
  }

  private func deliver() {
    guard let folder = folder else {
      finish()
      return
    }
    let text = texts.joined(separator: "\n\n")
    if text.isEmpty && files.isEmpty {
      try? FileManager.default.removeItem(at: folder)
      finish()
      return
    }
    let manifest: [String: Any] = ["text": text, "files": files]
    do {
      let data = try JSONSerialization.data(withJSONObject: manifest)
      try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      finish()
      return
    }
    if let url = URL(string: "nymbot://share") {
      launch(url)
    }
    finish()
  }

  private func launch(_ url: URL) {
    typealias Open = @convention(c) (
      AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
    ) -> Void
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication, application.responds(to: selector) {
        let open = unsafeBitCast(application.method(for: selector), to: Open.self)
        open(application, selector, url as NSURL, NSDictionary(), nil)
        return
      }
      responder = current.next
    }
  }

  private func finish() {
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }
}
