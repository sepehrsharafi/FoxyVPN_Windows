#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <utility>

#include <optional>

#include "app_messages.h"
#include "flutter/generated_plugin_registrant.h"

namespace {
// Timer that shows the window if Dart has not done so (see OnCreate).
constexpr UINT_PTR kShowFallbackTimerId = 0x464F58;  // "FOX"
constexpr UINT kShowFallbackDelayMs = 3000;

// In case the Windows SDK in use is older than Vista's headers.
#ifndef ENDSESSION_CLOSEAPP
#define ENDSESSION_CLOSEAPP 0x00000001
#endif

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                           static_cast<int>(utf8.size()),
                                           nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        utf16.data(), length);
  return utf16;
}

const flutter::EncodableValue* Field(const flutter::EncodableValue* arguments,
                                     const char* name) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return nullptr;
  }
  auto it = map->find(flutter::EncodableValue(name));
  return it == map->end() ? nullptr : &it->second;
}

std::wstring StringField(const flutter::EncodableValue* arguments,
                         const char* name) {
  const auto* value = Field(arguments, name);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? Utf16FromUtf8(*text) : std::wstring();
}

bool BoolField(const flutter::EncodableValue* arguments, const char* name) {
  const auto* value = Field(arguments, name);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag != nullptr && *flag;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project),
      show_message_(::RegisterWindowMessageW(kShowMessageName)),
      quit_message_(::RegisterWindowMessageW(kQuitMessageName)),
      taskbar_created_message_(::RegisterWindowMessageW(L"TaskbarCreated")) {}

FlutterWindow::~FlutterWindow() {
  // window_manager's destroy() only ends the message loop, so this (not
  // OnDestroy) is usually where the window goes: take the icon with it.
  tray_.Remove();
  if (tray_channel_) {
    tray_channel_->SetMethodCallHandler(nullptr);
    tray_channel_ = nullptr;
  }
}

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

  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "foxyvpn/tray",
          &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleTrayCall(call, std::move(result)); });

  // The app runs elevated, Explorer does not: without this, Windows drops
  // Explorer's TaskbarCreated (and a show request from a non-elevated
  // process) before it reaches this window. The quit message stays limited
  // to processes with at least the app's rights (Setup / Uninstall are).
  ::ChangeWindowMessageFilterEx(GetHandle(), taskbar_created_message_,
                                MSGFLT_ALLOW, nullptr);
  ::ChangeWindowMessageFilterEx(GetHandle(), show_message_, MSGFLT_ALLOW,
                                nullptr);

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
  tray_.Remove();
  if (tray_channel_) {
    tray_channel_->SetMethodCallHandler(nullptr);
    tray_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleTrayCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const flutter::EncodableValue* arguments = call.arguments();
  if (method == "update") {
    // {tooltip, connected, status, toggle, toggleEnabled}
    if (quitting_) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    tray_ready_ = true;
    menu_status_ = StringField(arguments, "status");
    menu_toggle_ = StringField(arguments, "toggle");
    menu_toggle_enabled_ = BoolField(arguments, "toggleEnabled");
    const bool shown = tray_.Update(GetHandle(), StringField(arguments, "tooltip"),
                                    BoolField(arguments, "connected"));
    result->Success(flutter::EncodableValue(shown));
  } else if (method == "balloon") {
    // {title, text}
    const bool shown = !quitting_ &&
                       tray_.ShowBalloon(StringField(arguments, "title"),
                                         StringField(arguments, "text"));
    result->Success(flutter::EncodableValue(shown));
  } else if (method == "quitting") {
    BeginQuitting();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void FlutterWindow::HandleTrayEvent(WPARAM wparam, LPARAM lparam) {
  switch (LOWORD(lparam)) {
    case NIN_SELECT:
    case NIN_KEYSELECT:
    case WM_LBUTTONDBLCLK:
    case NIN_BALLOONUSERCLICK:
      ShowFromTray();
      break;
    case WM_CONTEXTMENU: {
      // Version 4 icons pass the anchor point (screen coordinates) in wparam.
      const POINT at = {static_cast<short>(LOWORD(wparam)),
                        static_cast<short>(HIWORD(wparam))};
      switch (tray_.ShowMenu(at, menu_status_, menu_toggle_,
                             menu_toggle_enabled_)) {
        case TrayIcon::kOpen:
          ShowFromTray();
          break;
        case TrayIcon::kToggle:
          if (tray_channel_ && !quitting_) {
            tray_channel_->InvokeMethod("toggle", nullptr);
          }
          break;
        case TrayIcon::kQuit:
          RequestQuit();
          break;
        default:
          break;
      }
      break;
    }
  }
}

void FlutterWindow::ShowFromTray() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || quitting_ || !tray_ready_) {
    return;
  }
  ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(hwnd);
  if (flutter_controller_) {
    flutter_controller_->ForceRedraw();
  }
}

void FlutterWindow::RequestQuit() {
  if (!tray_ready_ || !tray_channel_) {
    // Dart has not set the tray up (still starting, or its setup failed): its
    // close handler still quits for real then (lib/main.dart).
    ::PostMessage(GetHandle(), WM_CLOSE, 0, 0);
    return;
  }
  BeginQuitting();
  // Repeated requests (Setup asks every few seconds) are ignored by Dart.
  tray_channel_->InvokeMethod("quit", nullptr);
}

void FlutterWindow::BeginQuitting() {
  quitting_ = true;
  // The window is hidden while the VPN is taken down: the show fallback must
  // not bring it back then.
  ::KillTimer(GetHandle(), kShowFallbackTimerId);
  tray_.Remove();
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

  // The notification-area icon and the messages other processes send (see
  // app_messages.h). RegisterWindowMessage never returns 0 for these on
  // success; 0 would only mean it failed, so it is never matched.
  if (message == TrayIcon::kCallbackMessage) {
    HandleTrayEvent(wparam, lparam);
    return 0;
  }
  if (show_message_ != 0 && message == show_message_) {
    ShowFromTray();
    return 0;
  }
  if (quit_message_ != 0 && message == quit_message_) {
    RequestQuit();
    return 0;
  }
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_.Readd();  // Explorer restarted: the icon is gone, add it again
    return 0;
  }

  // A close (button, Alt+F4) hides the window to the tray or quits; either way
  // the show fallback must not bring the window back.
  if (message == WM_CLOSE) {
    ::KillTimer(hwnd, kShowFallbackTimerId);
  }

  // The installer closes a running app through the Restart Manager, which first
  // sends WM_QUERYENDSESSION with ENDSESSION_CLOSEAPP. Turn that into a real
  // quit (WM_CLOSE only hides the window to the tray now): lib/main.dart then
  // disconnects the VPN and exits cleanly. (A real logoff or shutdown does not
  // carry this flag and is left alone.)
  if (message == WM_QUERYENDSESSION && (lparam & ENDSESSION_CLOSEAPP) != 0) {
    ::PostMessage(hwnd, quit_message_, 0, 0);
    return TRUE;
  }

  // The session really ends (logoff, shutdown): the process is about to be
  // ended, take the icon away first.
  if (message == WM_ENDSESSION && wparam != 0) {
    tray_.Remove();
  }

  if (message == WM_DESTROY) {
    tray_.Remove();
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
