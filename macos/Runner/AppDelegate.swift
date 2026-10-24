import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import os.log

@main
class AppDelegate: FlutterAppDelegate {
  private var oauthChannel: FlutterMethodChannel?
  private var playerPickerChannel: FlutterMethodChannel?
  private var awaitingOAuth = false
  // Paths whose security-scoped access is currently started through us, with
  // a count: starting access twice for the same folder must be stopped twice,
  // or the extension is never fully released before process exit.
  private var openScopePaths: [String: Int] = [:]

  func configureOAuth(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.tesget.kurako/oauth_callback", binaryMessenger: messenger)
    oauthChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "beginOAuth":
        self.awaitingOAuth = true
        result(nil)
      case "endOAuth":
        self.awaitingOAuth = false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func configurePlayerPicker(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.tesget.kurako/player_picker", binaryMessenger: messenger)
    playerPickerChannel = channel
    channel.setMethodCallHandler { call, result in
      guard call.method == "pickApplication" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let dialog = NSOpenPanel()
      dialog.canChooseFiles = true
      dialog.canChooseDirectories = false
      dialog.allowsMultipleSelection = false
      dialog.showsHiddenFiles = false
      dialog.treatsFilePackagesAsDirectories = false
      dialog.allowedContentTypes = [.applicationBundle]
      dialog.message = "选择用于外置播放的应用程序"
      guard
        let window =
          NSApplication.shared.keyWindow
          ?? NSApplication.shared.mainWindow
          ?? NSApplication.shared.windows.first
      else {
        result(FlutterError(code: "NO_WINDOW", message: "no key window", details: nil))
        return
      }
      dialog.beginSheetModal(for: window) { response in
        guard response == .OK, let url = dialog.url else {
          result(nil)
          return
        }
        guard
          url.pathExtension.lowercased() == "app",
          let bundle = Bundle(url: url),
          bundle.executableURL != nil
        else {
          result(
            FlutterError(
              code: "INVALID_APP", message: "selected bundle has no executable",
              details: nil))
          return
        }
        result(url.path)
      }
    }
  }

  /// Security-scoped bookmarks: NSOpenPanel grants last for one launch only,
  /// so paths picked by the user must be retained as bookmark data and
  /// re-activated on every launch (or mpv's open() hits the sandbox). The
  /// bridge is deliberately mechanical: create/resolve/access/stop — the
  /// Dart side owns which paths are retained.
  func configureSecurityScope(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.tesget.kurako/security_scope", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      func logScope(_ text: String) {
        // os_log is visible in Console/log show even when flutter stdout is
        // captured by Xcode only — the fastest way to debug sandbox grants.
        // Debug only: callers interpolate user paths, which must not land in a
        // shipped build's system log.
        #if DEBUG
          os_log("kurako/scope %{public}@", type: .info, text)
        #endif
      }
      switch call.method {
      case "pickFolder":
        // Security-scoped bookmarks encode the powerbox grant, so the blob
        // must be created from the NSOpenPanel URL itself — recreating a URL
        // from the path string yields a bookmark the kernel refuses to issue
        // an extension for (observed: file-issue-extension target:/ deny).
        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.allowsMultipleSelection = false
        dialog.showsHiddenFiles = false
        dialog.message = "选择番剧文件夹（macOS 会记住此位置的访问权限）"
        // Fall back to any available window: the panel may be requested while
        // the app is in the background or still setting up its window.
        guard
          let window =
            NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first
        else {
          result(FlutterError(code: "NO_WINDOW", message: "no key window", details: nil))
          return
        }
        dialog.beginSheetModal(for: window) { response in
          guard response == .OK, let url = dialog.url else {
            result(nil)
            return
          }
          let data = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil,
            relativeTo: nil)
          guard let data = data else {
            logScope("panel create FAILED path=\(url.path)")
            result(FlutterError(code: "BOOKMARK_FAILED", message: "cannot create bookmark", details: nil))
            return
          }
          logScope("panel created path=\(url.path) bytes=\(data.count)")
          result(["path": url.path, "bookmark": data.base64EncodedString()])
        }
      case "createBookmark":
        guard let path = call.arguments as? String else {
          result(FlutterError(code: "BAD_ARGS", message: "path required", details: nil))
          return
        }
        let data = try? URL(fileURLWithPath: path).bookmarkData(
          options: [.withSecurityScope], includingResourceValuesForKeys: nil,
          relativeTo: nil)
        guard let data = data else {
          logScope("create FAILED path=\(path)")
          result(FlutterError(code: "BOOKMARK_FAILED", message: "cannot create bookmark", details: nil))
          return
        }
        logScope("created path=\(path) bytes=\(data.count)")
        result(data.base64EncodedString())
      case "resolveBookmark":
        guard let base64 = call.arguments as? String,
              let data = Data(base64Encoded: base64) else {
          result(FlutterError(code: "BAD_ARGS", message: "bookmark required", details: nil))
          return
        }
        var stale = false
        let url = try? URL(
          resolvingBookmarkData: data, options: [.withoutUI, .withSecurityScope],
          relativeTo: nil, bookmarkDataIsStale: &stale)
        logScope("resolve -> \(url?.path ?? "nil") stale=\(stale)")
        result(url?.path)
      case "startAccess":
        guard let base64 = call.arguments as? String,
              let data = Data(base64Encoded: base64) else {
          result(FlutterError(code: "BAD_ARGS", message: "bookmark required", details: nil))
          return
        }
        var stale = false
        guard let url = try? URL(
          resolvingBookmarkData: data, options: [.withoutUI, .withSecurityScope],
          relativeTo: nil, bookmarkDataIsStale: &stale) else {
          logScope("startAccess resolve FAILED")
          result(nil)
          return
        }
        let started = url.startAccessingSecurityScopedResource()
        logScope("startAccess path=\(url.path) stale=\(stale) started=\(started)")
        guard started else {
          result(nil)
          return
        }
        self.openScopePaths[url.path, default: 0] += 1
        result(url.path)
      case "stopAccess":
        guard let path = call.arguments as? String,
              let count = self.openScopePaths[path] else {
          result(nil)
          return
        }
        URL(fileURLWithPath: path).stopAccessingSecurityScopedResource()
        if count <= 1 {
          self.openScopePaths.removeValue(forKey: path)
        } else {
          self.openScopePaths[path] = count - 1
        }
        logScope("stopped")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    guard awaitingOAuth, let channel = oauthChannel else { return }
    for url in urls {
      guard url.scheme == "kurako", url.host == "oauth",
            url.path == "/callback", url.user == nil, url.password == nil,
            url.port == nil, url.fragment == nil else { continue }
      channel.invokeMethod("onOAuthCallback", arguments: url.absoluteString) { [weak self] accepted in
        guard accepted as? Bool == true else { return }
        self?.awaitingOAuth = false
        application.activate(ignoringOtherApps: true)
        application.mainWindow?.makeKeyAndOrderFront(nil)
      }
    }
  }

  override func applicationWillTerminate(_ notification: Notification) {
    // A stopAccess() leak keeps the sandbox extension open until process exit;
    // terminating anyway makes that a non-issue, but pair what we can.
    for (path, count) in openScopePaths {
      let url = URL(fileURLWithPath: path)
      for _ in 0..<count {
        url.stopAccessingSecurityScopedResource()
      }
    }
    openScopePaths.removeAll()
  }
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
