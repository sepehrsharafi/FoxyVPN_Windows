#ifndef RUNNER_APP_MESSAGES_H_
#define RUNNER_APP_MESSAGES_H_

// Window messages (RegisterWindowMessage names) that other processes post to
// the running FoxyVPN window (class FLUTTER_RUNNER_WIN32_WINDOW, title
// "FoxyVPN"). Handled in flutter_window.cpp.
//
// The installer (installer/foxyvpn.iss) uses the quit message by name: do not
// rename one without the other.

// A second start of foxyvpn.exe (main.cpp): show the window, also when it is
// hidden in the notification area. Ignored while the app is quitting or still
// starting up (the window shows itself then).
constexpr wchar_t kShowMessageName[] = L"FoxyVPN-Show";

// Setup / Uninstall: quit for real (disconnect the VPN, restore routes and DNS,
// then exit). A plain WM_CLOSE only hides the window to the tray now.
constexpr wchar_t kQuitMessageName[] = L"FoxyVPN-Quit";

#endif  // RUNNER_APP_MESSAGES_H_
