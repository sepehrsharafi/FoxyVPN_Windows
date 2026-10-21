#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// One FoxyVPN per PC. The installer (Inno Setup AppMutex) and the uninstaller
// use the same name to know whether the app is running, so do not rename it.
constexpr wchar_t kAppMutexName[] = L"Global\\FoxyVPN-App";

// Must match the window class in win32_window.cpp and the title passed to
// FlutterWindow::Create below (window_manager sets the same title).
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"FoxyVPN";

// How long a second start waits for the first instance (to show its window, or
// to finish closing) before it gives up.
constexpr ULONGLONG kSingleInstanceWaitMs = 20000;

HANDLE g_instance_mutex = nullptr;

void BringToFront(HWND window) {
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  ::SetForegroundWindow(window);
}

// Returns true if this process may go on and become the app. Returns false if
// another FoxyVPN is running: its window has then been brought to the front (or
// it is still closing, then there is nothing to show), and this process should
// exit.
//
// The first instance creates the mutex and owns it until it exits. A second
// instance cannot own it, so it looks for the first one's window:
//  * visible (also minimised): bring it to the front, done;
//  * hidden: the first instance is still starting (the window is shown a moment
//    after it is created) or closing (the window is hidden while the tunnel is
//    taken down). Wait for the window to appear, or for the mutex to be released
//    (the first instance is gone): then this process takes over normally.
bool BecomeSingleInstance() {
  g_instance_mutex = ::CreateMutexW(nullptr, TRUE, kAppMutexName);
  if (g_instance_mutex != nullptr && ::GetLastError() != ERROR_ALREADY_EXISTS) {
    return true;  // first instance
  }

  const ULONGLONG deadline = ::GetTickCount64() + kSingleInstanceWaitMs;
  for (;;) {
    HWND window = ::FindWindowW(kWindowClassName, kWindowTitle);
    if (window != nullptr && ::IsWindowVisible(window)) {
      BringToFront(window);
      return false;
    }
    if (g_instance_mutex != nullptr) {
      // Owner gone (WAIT_ABANDONED_0 is how a process that exits shows up)?
      const DWORD wait = ::WaitForSingleObject(g_instance_mutex, 200);
      if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED_0) {
        return true;
      }
    } else {
      ::Sleep(200);  // the mutex could not even be opened: just look for the window
    }
    if (::GetTickCount64() >= deadline) {
      break;
    }
  }
  // A hidden window that stays hidden: the other instance is busy, do not start
  // a second tunnel. No window at all: nothing real is holding the mutex.
  return ::FindWindowW(kWindowClassName, kWindowTitle) == nullptr;
}

bool HasArgument(const std::vector<std::string>& arguments,
                 const std::string& wanted) {
  for (const std::string& argument : arguments) {
    if (argument == wanted) {
      return true;
    }
  }
  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // `foxyvpn.exe --cleanup [--remove-data]` is run by the uninstaller (see
  // lib/windows_cleanup.dart). It is not the app: it takes no mutex (the
  // uninstaller checks that mutex to see whether the app is running) and never
  // shows a window.
  const bool cleanup_mode = HasArgument(command_line_arguments, "--cleanup");
  if (!cleanup_mode && !BecomeSingleInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetShowFallbackEnabled(!cleanup_mode);
  Win32Window::Point origin(100, 100);
  Win32Window::Size size(400, 720);
  // A different title in cleanup mode, so FindWindow above never finds it.
  if (!window.Create(cleanup_mode ? L"FoxyVPN cleanup" : kWindowTitle, origin,
                     size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
