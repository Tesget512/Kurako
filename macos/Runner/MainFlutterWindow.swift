import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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

    super.awakeFromNib()
  }
}
