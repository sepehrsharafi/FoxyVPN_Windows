import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var everShown = false
  private var appIcons: AppIconChannel?

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

    // App icons for the Usage page ("foxyvpn/apps").
    appIcons = AppIconChannel(messenger: flutterViewController.engine.binaryMessenger)

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

/// App icons for the Usage page: the macOS side of the "foxyvpn/apps" channel
/// (lib/platform/macos_apps.dart is the Dart end).
///
/// Dart -> native:
///   appIcon {path, size} -> PNG bytes of the app bundle's icon, size x size px, or nil
final class AppIconChannel: NSObject {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "foxyvpn/apps", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "appIcon" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
      let path = args["path"] as? String,
      path.hasPrefix("/"), path.hasSuffix(".app"),
      FileManager.default.fileExists(atPath: path)
    else {
      result(nil)
      return
    }
    let size = min(max((args["size"] as? Int) ?? 64, 16), 512)
    // Method calls arrive on the main thread, where NSWorkspace and drawing belong.
    result(AppIconChannel.png(of: NSWorkspace.shared.icon(forFile: path), size: size))
  }

  private static func png(of icon: NSImage, size: Int) -> FlutterStandardTypedData? {
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    icon.draw(
      in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy,
      fraction: 1.0)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
    return FlutterStandardTypedData(bytes: data)
  }
}
