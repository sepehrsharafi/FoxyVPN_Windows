#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {
// Timer that shows the window if Dart has not done so (see OnCreate).
constexpr UINT_PTR kShowFallbackTimerId = 0x464F58;  // "FOX"
constexpr UINT kShowFallbackDelayMs = 3000;

// In case the Windows SDK in use is older than Vista's headers.
#ifndef ENDSESSION_CLOSEAPP
#define ENDSESSION_CLOSEAPP 0x00000001
#endif
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // The window stays hidden after the first frame: window_manager (see
  // lib/main.dart) applies the size, the hidden title bar and the dark
  // background first and then shows it, so nothing flashes. If that never
  // happens (Dart failed before it got there) a timer shows the window
  // anyway, so the app can never stay running with no window.
  // (Not for the headless `--cleanup` run, which must never show a window.)
  if (show_fallback_enabled_) {
    flutter_controller_->engine()->SetNextFrameCallback([&]() {
      ::SetTimer(this->GetHandle(), kShowFallbackTimerId, kShowFallbackDelayMs,
                 nullptr);
    });
  }

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Safety net for a window that is still hidden a few seconds after the
  // first frame. Checked first so that no plugin can swallow it.
  if (message == WM_TIMER && wparam == kShowFallbackTimerId) {
    ::KillTimer(hwnd, kShowFallbackTimerId);
    if (!::IsWindowVisible(hwnd)) {
      this->Show();
    }
    return 0;
  }

  // The installer closes a running app through the Restart Manager, which first
  // sends WM_QUERYENDSESSION with ENDSESSION_CLOSEAPP. Turn that into the same
  // WM_CLOSE a click on the close button gives: lib/main.dart then disconnects
  // the VPN and exits cleanly. (A real logoff or shutdown does not carry this
  // flag and is left alone.)
  // A close (button, installer, Restart Manager) hides the window while the
  // VPN is taken down: the show fallback must not bring it back then.
  if (message == WM_CLOSE) {
    ::KillTimer(hwnd, kShowFallbackTimerId);
  }

  if (message == WM_QUERYENDSESSION && (lparam & ENDSESSION_CLOSEAPP) != 0) {
    ::PostMessage(hwnd, WM_CLOSE, 0, 0);
    return TRUE;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
