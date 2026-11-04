import Cocoa
import FlutterMacOS

/// FoxyVPN's menu bar icon and what quitting does: the macOS side of the
/// "foxyvpn/tray" channel (the Windows side is windows/runner/tray_icon.cpp and
/// flutter_window.cpp; lib/platform/windows_tray.dart is the Dart end of both).
///
/// Dart -> native:
///   update {tooltip, connected, status, toggle, toggleEnabled} -> true (icon shown)
///   balloon {title, text}  -> false (macOS has no balloon; Dart tries again later)
///   quitting               (the icon goes away; the app may now end)
/// Native -> Dart:
///   toggle                 (menu Connect / Disconnect)
///   quit                   (menu Quit, Cmd+Q, Dock > Quit)
///
/// A quit is never abrupt while the VPN is up: the first time macOS asks the app
/// to terminate, Dart is asked to quit instead (it disconnects, restores routes
/// and DNS, then exits the process itself), and the termination is cancelled.
final class StatusItemController: NSObject {
  private let channel: FlutterMethodChannel
  private let menu = NSMenu()
  private let openItem: NSMenuItem
  private let statusLine: NSMenuItem
  private let toggleItem: NSMenuItem
  private let quitItem: NSMenuItem
  private var statusItem: NSStatusItem?

  /// Dart has said it is quitting: the icon is gone and termination is allowed.
  private(set) var quitting = false
  /// Dart was asked to quit and has not said "quitting" yet.
  private var quitRequested = false
  /// The Mac is shutting down or logging out: nothing is worth waiting for.
  private var systemEnding = false
  private var quitWatchdog: DispatchWorkItem?
  private var powerOffObserver: NSObjectProtocol?

  /// If Dart takes this long to quit (it is stuck), quit anyway: the network
  /// helper undoes the VPN as soon as the app's connection to it closes.
  private let quitWatchdogSeconds = 20.0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "foxyvpn/tray", binaryMessenger: messenger)
    openItem = NSMenuItem(title: "Open FoxyVPN", action: nil, keyEquivalent: "")
    statusLine = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
    toggleItem = NSMenuItem(title: "Connect", action: nil, keyEquivalent: "")
    quitItem = NSMenuItem(title: "Quit FoxyVPN", action: nil, keyEquivalent: "")
    super.init()

    openItem.action = #selector(openSelected)
    openItem.target = self
    statusLine.isEnabled = false
    toggleItem.action = #selector(toggleSelected)
    toggleItem.target = self
    toggleItem.isEnabled = false
    quitItem.action = #selector(quitSelected)
    quitItem.target = self

    menu.autoenablesItems = false
    menu.addItem(openItem)
    menu.addItem(statusLine)
    menu.addItem(toggleItem)
    menu.addItem(NSMenuItem.separator())
    menu.addItem(quitItem)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handle(call, result: result)
    }

    powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.systemEnding = true
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    if let observer = powerOffObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    quitWatchdog?.cancel()
  }

  // MARK: Channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      guard !quitting, let args = call.arguments as? [String: Any] else {
        result(false)
        return
      }
      apply(args)
      result(true)
    case "balloon":
      result(false)
    case "quitting":
      markQuitting()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func apply(_ args: [String: Any]) {
    let tooltip = args["tooltip"] as? String ?? "FoxyVPN"
    let connected = args["connected"] as? Bool ?? false
    let status = args["status"] as? String ?? ""
    let toggle = args["toggle"] as? String ?? "Connect"
    let toggleEnabled = args["toggleEnabled"] as? Bool ?? false

    let item = ensureStatusItem()
    if let button = item.button {
      button.toolTip = tooltip
      if let image = NSImage(named: connected ? "StatusIconOn" : "StatusIconOff") {
        image.isTemplate = true
        button.image = image
        button.title = ""
      } else {
        button.image = nil
        button.title = "FoxyVPN"
      }
    }
    statusLine.title = status
    toggleItem.title = toggle
    toggleItem.isEnabled = toggleEnabled
  }

  private func ensureStatusItem() -> NSStatusItem {
    if let item = statusItem { return item }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.menu = menu
    item.button?.imagePosition = .imageOnly
    statusItem = item
    return item
  }

  /// Dart is quitting by itself: the icon goes, and the app may now terminate.
  private func markQuitting() {
    quitting = true
    quitRequested = false
    quitWatchdog?.cancel()
    quitWatchdog = nil
    if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
  }

  // MARK: Menu

  @objc private func openSelected() {
    showWindow()
  }

  @objc private func toggleSelected() {
    channel.invokeMethod("toggle", arguments: nil)
  }

  @objc private func quitSelected() {
    NSApp.terminate(nil)
  }

  /// Brings the window back (menu, Dock icon), also when it is hidden or minimised.
  func showWindow() {
    if quitting { return }
    NSApp.activate(ignoringOtherApps: true)
    guard let window = NSApp.windows.first(where: { $0 is MainFlutterWindow }) else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  // MARK: Termination

  /// The answer to applicationShouldTerminate (see AppDelegate).
  func terminateReply() -> NSApplication.TerminateReply {
    if quitting || systemEnding { return .terminateNow }
    if quitRequested { return .terminateCancel }  // Dart is already on it
    quitRequested = true

    channel.invokeMethod("quit", arguments: nil) { [weak self] reply in
      // Nobody listens yet (Dart has not started the tray side) or it failed:
      // there is no VPN to undo, so just end.
      let unanswered = reply is FlutterError || (reply as? NSObject) === FlutterMethodNotImplemented
      if unanswered { self?.terminateNow() }
    }

    let watchdog = DispatchWorkItem { [weak self] in self?.terminateNow() }
    quitWatchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + quitWatchdogSeconds, execute: watchdog)
    return .terminateCancel
  }

  private func terminateNow() {
    markQuitting()
    NSApp.terminate(nil)
  }
}
