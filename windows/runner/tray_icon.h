#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <string>

// FoxyVPN's notification-area ("system tray") icon, owned by the main window.
// Plain Shell_NotifyIcon (NOTIFYICON_VERSION_4); the Dart side decides what it
// says (lib/platform/windows_tray.dart), flutter_window.cpp routes its events.
class TrayIcon {
 public:
  // Sent to the owner window for mouse / keyboard / balloon events on the
  // icon: LOWORD(lparam) is the event (NIN_SELECT, WM_CONTEXTMENU, ...),
  // wparam the anchor point in screen coordinates.
  static constexpr UINT kCallbackMessage = WM_APP + 0x46;

  // Context menu commands (see ShowMenu).
  enum Command : UINT { kNone = 0, kOpen = 1, kToggle = 2, kQuit = 3 };

  TrayIcon() = default;
  ~TrayIcon();
  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Adds the icon (first call) or updates it. False if the shell did not take
  // it (no taskbar yet): it is added on the next TaskbarCreated (Readd).
  bool Update(HWND window, const std::wstring& tooltip, bool connected);

  // A one-off notification from the icon. False if it could not be shown.
  bool ShowBalloon(const std::wstring& title, const std::wstring& text);

  // Takes the icon away (no ghost icon is left behind). Safe to call twice.
  void Remove();

  // Explorer (re)started and has no icons: add ours again, if it is wanted.
  void Readd();

  // Shows the context menu at |at| and returns the chosen command.
  Command ShowMenu(POINT at, const std::wstring& status,
                   const std::wstring& toggle_label, bool toggle_enabled);

 private:
  bool Add();
  void LoadIcons();
  void FreeIcons();
  void Fill(NOTIFYICONDATAW& data) const;

  HWND window_ = nullptr;
  bool wanted_ = false;  // Update was called and Remove was not
  bool added_ = false;   // the shell has the icon
  bool connected_ = false;
  std::wstring tooltip_;
  HICON icon_on_ = nullptr;
  HICON icon_off_ = nullptr;
};

#endif  // RUNNER_TRAY_ICON_H_
