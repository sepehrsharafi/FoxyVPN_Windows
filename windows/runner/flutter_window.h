#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "tray_icon.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view, plus FoxyVPN's
// notification-area icon (method channel "foxyvpn/tray", see
// lib/platform/windows_tray.dart).
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Whether a timer shows the window if Dart has not (see OnCreate). On by
  // default; off for the headless `--cleanup` run. Call before Create.
  void SetShowFallbackEnabled(bool enabled) { show_fallback_enabled_ = enabled; }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void HandleTrayCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleTrayEvent(WPARAM wparam, LPARAM lparam);

  // Shows and focuses the window (tray icon, second start). Not while
  // quitting, and not before Dart has set the tray up (the window is still
  // starting then and shows itself).
  void ShowFromTray();

  // Quit for real (tray menu, Setup / Uninstall, Restart Manager): Dart
  // disconnects the VPN, restores routes and DNS, then exits.
  void RequestQuit();

  // Marks the app as quitting: the icon goes, show requests are ignored.
  void BeginQuitting();

  // The project to run.
  flutter::DartProject project_;

  bool show_fallback_enabled_ = true;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      tray_channel_;
  TrayIcon tray_;
  // What the tray menu shows; set by Dart with every update.
  std::wstring menu_status_;
  std::wstring menu_toggle_;
  bool menu_toggle_enabled_ = false;
  // Dart has set the tray up (the window has been shown once by then).
  bool tray_ready_ = false;
  // A real quit is in progress (window hidden, VPN being taken down).
  bool quitting_ = false;

  // Registered messages (see app_messages.h), and Explorer's TaskbarCreated.
  UINT show_message_ = 0;
  UINT quit_message_ = 0;
  UINT taskbar_created_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
