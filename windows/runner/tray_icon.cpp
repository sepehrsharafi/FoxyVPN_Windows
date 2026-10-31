#include "tray_icon.h"

#include <shellapi.h>
#include <wchar.h>

#include "resource.h"

namespace {

constexpr UINT kIconId = 1;

void CopyTruncated(wchar_t* target, size_t capacity, const std::wstring& text) {
  wcsncpy_s(target, capacity, text.c_str(), _TRUNCATE);
}

HICON LoadSmallIcon(int resource_id) {
  // Notification-area size for the current scaling (16 px at 100 %, 32 at 200 %).
  // The .ico files carry these sizes, so nothing is scaled.
  const int size = ::GetSystemMetrics(SM_CXSMICON);
  return static_cast<HICON>(::LoadImageW(::GetModuleHandleW(nullptr),
                                         MAKEINTRESOURCEW(resource_id),
                                         IMAGE_ICON, size, size,
                                         LR_DEFAULTCOLOR));
}

}  // namespace

TrayIcon::~TrayIcon() {
  Remove();
  FreeIcons();
}

void TrayIcon::LoadIcons() {
  FreeIcons();
  icon_on_ = LoadSmallIcon(IDI_APP_ICON);
  icon_off_ = LoadSmallIcon(IDI_TRAY_OFF);
}

void TrayIcon::FreeIcons() {
  if (icon_on_ != nullptr) {
    ::DestroyIcon(icon_on_);
    icon_on_ = nullptr;
  }
  if (icon_off_ != nullptr) {
    ::DestroyIcon(icon_off_);
    icon_off_ = nullptr;
  }
}

void TrayIcon::Fill(NOTIFYICONDATAW& data) const {
  data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kCallbackMessage;
  HICON icon = connected_ ? icon_on_ : icon_off_;
  data.hIcon = icon != nullptr ? icon : icon_on_;
  CopyTruncated(data.szTip, ARRAYSIZE(data.szTip), tooltip_);
}

bool TrayIcon::Add() {
  NOTIFYICONDATAW data;
  Fill(data);
  if (!::Shell_NotifyIconW(NIM_ADD, &data)) {
    // NIM_ADD can report a failure when Explorer was merely slow and the icon
    // is there after all (or it is still there from before): try updating it.
    if (!::Shell_NotifyIconW(NIM_MODIFY, &data)) {
      added_ = false;
      return false;
    }
  }
  data.uVersion = NOTIFYICON_VERSION_4;
  ::Shell_NotifyIconW(NIM_SETVERSION, &data);
  added_ = true;
  return true;
}

bool TrayIcon::Update(HWND window, const std::wstring& tooltip, bool connected) {
  if (icon_on_ == nullptr) {
    LoadIcons();
  }
  window_ = window;
  tooltip_ = tooltip;
  connected_ = connected;
  wanted_ = true;
  if (added_) {
    NOTIFYICONDATAW data;
    Fill(data);
    if (::Shell_NotifyIconW(NIM_MODIFY, &data)) {
      return true;
    }
    added_ = false;  // gone (Explorer restarted?): add it again
  }
  return Add();
}

bool TrayIcon::ShowBalloon(const std::wstring& title, const std::wstring& text) {
  if (!added_) {
    return false;
  }
  NOTIFYICONDATAW data;
  Fill(data);
  data.uFlags = NIF_INFO;
  // NIIF_USER: the notification shows the app's own icon.
  data.dwInfoFlags = NIIF_USER;
  CopyTruncated(data.szInfoTitle, ARRAYSIZE(data.szInfoTitle), title);
  CopyTruncated(data.szInfo, ARRAYSIZE(data.szInfo), text);
  return ::Shell_NotifyIconW(NIM_MODIFY, &data) != FALSE;
}

void TrayIcon::Remove() {
  wanted_ = false;
  if (!added_) {
    return;
  }
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
  added_ = false;
}

void TrayIcon::Readd() {
  added_ = false;  // the new Explorer has no icons at all
  if (!wanted_) {
    return;
  }
  LoadIcons();  // the display scaling may have changed meanwhile
  Add();
}

TrayIcon::Command TrayIcon::ShowMenu(POINT at, const std::wstring& status,
                                     const std::wstring& toggle_label,
                                     bool toggle_enabled) {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return kNone;
  }
  ::AppendMenuW(menu, MF_STRING, kOpen, L"Open FoxyVPN");
  ::SetMenuDefaultItem(menu, kOpen, FALSE);  // bold: what a click on the icon does
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  if (!status.empty()) {
    // An information line, not a command.
    ::AppendMenuW(menu, MF_STRING | MF_GRAYED, kNone, status.c_str());
  }
  if (!toggle_label.empty()) {
    ::AppendMenuW(menu, MF_STRING | (toggle_enabled ? MF_ENABLED : MF_GRAYED),
                  kToggle, toggle_label.c_str());
  }
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kQuit, L"Quit FoxyVPN");

  // Without this the menu does not close when the user clicks elsewhere
  // (documented TrackPopupMenu behaviour for notification icons).
  ::SetForegroundWindow(window_);
  UINT flags = TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN;
  flags |= ::GetSystemMetrics(SM_MENUDROPALIGNMENT) != 0 ? TPM_RIGHTALIGN
                                                         : TPM_LEFTALIGN;
  const UINT chosen = static_cast<UINT>(
      ::TrackPopupMenuEx(menu, flags, at.x, at.y, window_, nullptr));
  ::PostMessageW(window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  switch (chosen) {
    case kOpen:
    case kToggle:
    case kQuit:
      return static_cast<Command>(chosen);
    default:
      return kNone;
  }
}
