import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var everShown = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The menu bar icon; Dart drives it over the "foxyvpn/tray" channel.
    let appDelegate = NSApp.delegate as? AppDelegate
    appDelegate?.statusItemController = StatusItemController(
      messenger: flutterViewController.engine.binaryMessenger)

    // The window stays hidden until Dart has sized and placed it (window_manager's
    // hiddenWindowAtLaunch). If Dart never shows it, show it after a few seconds
    // so the app is never stuck invisible.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self = self, !self.everShown else { return }
      NSApp.activate(ignoringOtherApps: true)
      self.makeKeyAndOrderFront(nil)
    }

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
    if isVisible { everShown = true }
  }
}
