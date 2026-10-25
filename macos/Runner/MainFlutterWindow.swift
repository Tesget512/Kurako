import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var revealChannel: FlutterMethodChannel?
  private var revealTimer: Timer?
  private var revealed = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    (NSApplication.shared.delegate as? AppDelegate)?.configureOAuth(
      messenger: flutterViewController.engine.binaryMessenger)
    (NSApplication.shared.delegate as? AppDelegate)?.configureSecurityScope(
      messenger: flutterViewController.engine.binaryMessenger)
    (NSApplication.shared.delegate as? AppDelegate)?.configurePlayerPicker(
      messenger: flutterViewController.engine.binaryMessenger)

    // Stay fully transparent until Flutter has painted its first frame, so
    // launching never flashes a black un-styled window. The window itself
    // stays ordered in (unlike visibleAtLaunch=NO, which starves the render
    // loop — no frame ever painted, so nothing ever revealed); an invisible
    // window still receives vsync, the first frame paints, and Dart calls
    // `reveal` over the channel. The native timer is the safety net: even if
    // Dart never reports in, the window becomes visible after two seconds.
    alphaValue = 0.0
    revealChannel = FlutterMethodChannel(
      name: "kurako/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    revealChannel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "reveal":
        self?.reveal()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    revealTimer = Timer.scheduledTimer(
      withTimeInterval: 2.0,
      repeats: false
    ) { [weak self] _ in
      self?.reveal()
    }

    super.awakeFromNib()
  }

  private func reveal() {
    if revealed { return }
    revealed = true
    revealTimer?.invalidate()
    revealTimer = nil
    alphaValue = 1.0
  }

  deinit {
    revealTimer?.invalidate()
  }
}
