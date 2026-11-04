import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// The menu bar icon and quit handling; set by MainFlutterWindow once Flutter is up.
  var statusItemController: StatusItemController?

  // Closing the window hides it (Dart decides); the app keeps running in the menu bar.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Clicking the Dock icon brings the window back, also when it was hidden.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    statusItemController?.showWindow()
    return false
  }

  // Cmd+Q, Dock > Quit and the menu bar's Quit ask Dart to quit (it disconnects
  // the VPN first, then exits). Without Dart there is nothing to undo.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller = statusItemController else { return .terminateNow }
    return controller.terminateReply()
  }
}
