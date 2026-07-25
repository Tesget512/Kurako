import Flutter
import UIKit

/// iOS-specific integrations that require a real UIKit controller instead of
/// a best-effort cross-platform plugin.
private final class KurakoIosBridge: NSObject, UIDocumentPickerDelegate {
  private var pendingResult: FlutterResult?
  // Security-scoped URLs must stay alive for as long as Rust may scan/play
  // their paths. Keep them open for this app process and restore them at launch.
  private var activeFolderUrls: [URL] = []
  private let folderBookmarksKey = "kurako.securityScopedFolderBookmarks"

  func register(with messenger: FlutterBinaryMessenger) {
    restoreFolderAccess()
    let channel = FlutterMethodChannel(name: "kurako/ios", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "bridge_unavailable", message: nil, details: nil))
        return
      }
      switch call.method {
      case "pickLibraryFolder":
        self.pickLibraryFolder(result)
      case "shareVideo":
        let args = call.arguments as? [String: Any]
        self.shareVideo(args?["path"] as? String, result: result)
      case "openExternalUrl":
        let args = call.arguments as? [String: Any]
        self.openExternalUrl(args?["url"] as? String, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func pickLibraryFolder(_ result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(FlutterError(code: "picker_busy", message: "已有系统选择器正在打开", details: nil))
      return
    }
    pendingResult = result
    let picker = UIDocumentPickerViewController(
      documentTypes: ["public.folder"], in: .open)
    picker.allowsMultipleSelection = false
    picker.delegate = self
    topViewController()?.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishPicker(nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController,
                      didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      finishPicker(nil)
      return
    }
    guard url.startAccessingSecurityScopedResource() else {
      finishPicker(FlutterError(code: "folder_access_denied",
                                message: "系统没有授予该文件夹的读取权限", details: nil))
      return
    }
    activeFolderUrls.append(url)
    saveBookmark(for: url)
    finishPicker(url.path)
  }

  private func finishPicker(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    result?(value)
  }

  private func saveBookmark(for url: URL) {
    do {
      // iOS bookmarks are security-scoped by the document picker grant;
      // unlike macOS, the explicit .withSecurityScope option is unavailable.
      let data = try url.bookmarkData(options: [],
                                      includingResourceValuesForKeys: nil,
                                      relativeTo: nil)
      var bookmarks = UserDefaults.standard.dictionary(forKey: folderBookmarksKey) as? [String: String] ?? [:]
      bookmarks[url.path] = data.base64EncodedString()
      UserDefaults.standard.set(bookmarks, forKey: folderBookmarksKey)
    } catch {
      // The current process still has access. Scanning reports a normal error
      // after a relaunch if this provider cannot supply a durable bookmark.
      NSLog("KURAKO could not persist folder bookmark: %@", error.localizedDescription)
    }
  }

  private func restoreFolderAccess() {
    let bookmarks = UserDefaults.standard.dictionary(forKey: folderBookmarksKey) as? [String: String] ?? [:]
    var repaired = bookmarks
    for (path, encoded) in bookmarks {
      guard let data = Data(base64Encoded: encoded) else { continue }
      do {
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [],
                          relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { continue }
        activeFolderUrls.append(url)
        if stale {
          let fresh = try url.bookmarkData(options: [],
                                           includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
          repaired.removeValue(forKey: path)
          repaired[url.path] = fresh.base64EncodedString()
        }
      } catch {
        NSLog("KURAKO could not restore folder %@: %@", path, error.localizedDescription)
      }
    }
    UserDefaults.standard.set(repaired, forKey: folderBookmarksKey)
  }

  private func shareVideo(_ path: String?, result: @escaping FlutterResult) {
    guard let path, !path.isEmpty,
          FileManager.default.isReadableFile(atPath: path) else {
      result(FlutterError(code: "unreadable_file", message: "视频文件不可读取", details: nil))
      return
    }
    let controller = UIActivityViewController(
      activityItems: [URL(fileURLWithPath: path)], applicationActivities: nil)
    topViewController()?.present(controller, animated: true)
    result(true)
  }

  /// Ask iOS to route a URI to the application which registered its scheme.
  /// This is the only generic cross-app hand-off available on iOS; unlike
  /// Android there is no ACTION_VIEW chooser API.
  private func openExternalUrl(_ rawUrl: String?, result: @escaping FlutterResult) {
    guard let rawUrl, let url = URL(string: rawUrl) else {
      result(FlutterError(code: "invalid_url", message: "无效的外部地址", details: nil))
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      result(opened)
    }
  }

  private func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var controller = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? scene?.windows.first?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let iosBridge = KurakoIosBridge()
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    iosBridge.register(with: engineBridge.applicationRegistrar.messenger())
  }
}
