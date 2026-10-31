; FoxyVPN installer (Inno Setup 6.3 or newer). Build it from the repository root:
;
;   ISCC.exe /DAppVersion=0.1.0 installer\foxyvpn.iss
;
; AppVersion is the pubspec version without the "+build" part (CI passes it).
; The Release folder (flutter build windows --release, plus tun2socks.exe,
; wintun.dll, the app-local Visual C++ runtime DLLs and licenses\) is read from
; ..\build\windows\x64\runner\Release; the result is ..\dist\FoxyVPN-Setup-<version>.exe.
;
; What it changes on the PC: files in {autopf}\FoxyVPN, Start Menu (and optionally
; desktop) shortcuts, the uninstall entry. Nothing else: no PATH edit, no
; service, no system-wide Visual C++ redistributable. FoxyVPN itself, when it
; runs, adds routes/DNS rule/scheduled task/Wintun adapter and %ProgramData%\FoxyVPN
; and takes them all back on disconnect and on uninstall (see README.md).

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#if Pos("+", AppVersion) > 0
  #error AppVersion must not contain "+": pass the pubspec version without the build number.
#endif

#define AppName "FoxyVPN"
#define AppExe "foxyvpn.exe"
; Same name as in windows/runner/main.cpp. Do not rename one without the other.
#define AppMutexName "Global\FoxyVPN-App"
#define ReleaseDir "..\build\windows\x64\runner\Release"

; Fail the build, not the user, if the folder is incomplete.
#define ReleaseDirFull AddBackslash(SourcePath) + ReleaseDir
#if !FileExists(ReleaseDirFull + "\foxyvpn.exe")
  #error Release folder is missing foxyvpn.exe. Run flutter build windows --release first.
#endif
#if !FileExists(ReleaseDirFull + "\tun2socks.exe")
  #error Release folder is missing tun2socks.exe
#endif
#if !FileExists(ReleaseDirFull + "\wintun.dll")
  #error Release folder is missing wintun.dll
#endif
#if !FileExists(ReleaseDirFull + "\msvcp140.dll")
  #error Release folder is missing msvcp140.dll (app-local Visual C++ runtime)
#endif
#if !FileExists(ReleaseDirFull + "\vcruntime140.dll")
  #error Release folder is missing vcruntime140.dll (app-local Visual C++ runtime)
#endif
#if !FileExists(ReleaseDirFull + "\vcruntime140_1.dll")
  #error Release folder is missing vcruntime140_1.dll (app-local Visual C++ runtime)
#endif

[Setup]
; Never change this GUID: it is how an update finds the installed version.
AppId={{7D3A9F52-1B64-4C8E-A5F0-9E2B6C41D870}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=FoxyVPN (unofficial)
AppCopyright=MIT license
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup

; x64 Windows 10 or newer only.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

; Creating the adapter and changing routes needs administrator rights anyway.
PrivilegesRequired=admin
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UsePreviousAppDir=yes

; One Setup at a time. AppMutex: refuse to replace files of a running app
; (the app creates this mutex, see windows/runner/main.cpp). CloseApplications:
; Windows' Restart Manager asks a still running app to close; the app turns
; that request into a real quit (it disconnects the VPN first). The [Code]
; section below also quits the app by itself before that.
SetupMutex=FoxyVPN-Setup
AppMutex={#AppMutexName}
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no

WizardStyle=modern
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
LicenseFile=..\LICENSE

OutputDir=..\dist
OutputBaseFilename=FoxyVPN-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; An update replaces these folders completely (no stale files of an older version).
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\licenses"

[Files]
; Everything from the Release folder: foxyvpn.exe, flutter_windows.dll, data\,
; tun2socks.exe, wintun.dll, the app-local Visual C++ runtime, licenses\.
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; The app is elevated (it asks for administrator rights itself) and so is Setup.
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent runascurrentuser shellexec

; No [UninstallRun] section on purpose: Inno Setup evaluates the Check of an
; [UninstallRun] entry at INSTALL time (it decides what goes into the uninstall
; log), so the uninstall-time "delete my data?" answer could never select an
; entry. `foxyvpn.exe --cleanup [--remove-data]` is run from
; CurUninstallStepChanged(usUninstall) in [Code] instead: after the uninstall
; is confirmed, BEFORE any file is deleted.

[UninstallDelete]
; The install record (whether FoxyVPN installed the Wintun driver) lives here.
Type: filesandordirs; Name: "{commonappdata}\FoxyVPN"
Type: filesandordirs; Name: "{app}"

[Code]
const
  AppMutexName = '{#AppMutexName}';
  // Class of the runner window (windows/runner/win32_window.cpp) and its title.
  AppWindowClass = 'FLUTTER_RUNNER_WIN32_WINDOW';
  AppWindowTitle = '{#AppName}';
  // Registered window message that makes the app quit for real (see
  // windows/runner/app_messages.h). WM_CLOSE only hides it to the tray now.
  AppQuitMessageName = 'FoxyVPN-Quit';
  WM_CLOSE = $0010;
  // The app disconnects the VPN (about a second, up to a minute in a bad case).
  CloseWaitSeconds = 60;

function FoxyFindWindow(ClassName, WindowName: String): Longint;
  external 'FindWindowW@user32.dll stdcall';
function FoxyPostMessage(Wnd: Longint; Msg: Longint; WParam: Longint; LParam: Longint): Longint;
  external 'PostMessageW@user32.dll stdcall';
function FoxyRegisterWindowMessage(Name: String): Longint;
  external 'RegisterWindowMessageW@user32.dll stdcall';

function AppIsRunning: Boolean;
begin
  Result := CheckForMutexes(AppMutexName);
end;

{ Asks the running app to quit, the same way Quit in its tray menu does (the
  registered "FoxyVPN-Quit" message; WM_CLOSE would only hide it to the tray):
  it then disconnects the VPN, restores routes and DNS, and exits. Also works when
  the window is hidden in the tray. Waits until the app is really gone (its mutex
  is released). False if it is still there. }
function CloseRunningApp: Boolean;
var
  Wnd: Longint;
  QuitMessage: Longint;
  Waited: Integer;
begin
  QuitMessage := FoxyRegisterWindowMessage(AppQuitMessageName);
  Waited := 0;
  while AppIsRunning and (Waited < CloseWaitSeconds * 1000) do
  begin
    if (Waited mod 3000) = 0 then
    begin
      Wnd := FoxyFindWindow(AppWindowClass, AppWindowTitle);
      if Wnd <> 0 then
      begin
        if QuitMessage <> 0 then
          FoxyPostMessage(Wnd, QuitMessage, 0, 0);
        // Still there after 3 s: an older FoxyVPN (before the tray), which does
        // not know the quit message and quits on WM_CLOSE. A current one is busy
        // disconnecting by then and ignores the extra close.
        if (Waited > 0) or (QuitMessage = 0) then
          FoxyPostMessage(Wnd, WM_CLOSE, 0, 0);
      end;
    end;
    Sleep(250);
    Waited := Waited + 250;
  end;
  Result := not AppIsRunning;
end;

function InitializeSetup: Boolean;
begin
  Result := True;
  if AppIsRunning then
  begin
    // Silent installs just close it (the default answer).
    if SuppressibleMsgBox(
         '{#AppName} is running. Setup will disconnect the VPN and close it, then continue.' + #13#10#13#10 +
         'Continue?', mbConfirmation, MB_YESNO, IDYES) <> IDYES then
    begin
      Result := False;
      Exit;
    end;
    if not CloseRunningApp then
    begin
      SuppressibleMsgBox(
        '{#AppName} did not close. Quit it yourself (right-click its icon in the notification area, then ' +
        'Quit FoxyVPN; that disconnects the VPN first), then run Setup again.', mbError, MB_OK, IDOK);
      Result := False;
    end;
  end;
end;

function InitializeUninstall: Boolean;
begin
  Result := True;

  // Closed here (not later): right after this, Uninstall checks AppMutex and a
  // silent uninstall would simply be cancelled if the app were still running.
  if AppIsRunning then
  begin
    if SuppressibleMsgBox(
         '{#AppName} is running. Uninstall will disconnect the VPN and close it, then continue.' + #13#10#13#10 +
         'Continue?', mbConfirmation, MB_YESNO, IDYES) <> IDYES then
    begin
      Result := False;
      Exit;
    end;
    if not CloseRunningApp then
    begin
      SuppressibleMsgBox(
        '{#AppName} did not close. Quit it yourself (right-click its icon in the notification area, then ' +
        'Quit FoxyVPN; that disconnects the VPN first), then run Uninstall again.', mbError, MB_OK, IDOK);
      Result := False;
      Exit;
    end;
  end;
end;

{ After the user confirmed the uninstall and before any file is deleted: give
  back routes, DNS, the scheduled task, the Wintun adapter and, if FoxyVPN
  installed it and nothing else uses it, the Wintun driver; optionally the
  user's data (see lib/windows_cleanup.dart). Hidden; the uninstaller waits. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  RemoveData: Boolean;
  Params: String;
  ResultCode: Integer;
begin
  if CurUninstallStep <> usUninstall then
    Exit;

  // A silent uninstall never deletes personal data. Otherwise: No is the default.
  RemoveData := False;
  if not UninstallSilent then
    RemoveData := MsgBox(
      'Also delete your saved sign-in and settings?' + #13#10#13#10 +
      'Choose No to keep them (they are used again if you install {#AppName} later).',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;

  Params := '--cleanup';
  if RemoveData then
    Params := Params + ' --remove-data';
  if Exec(ExpandConstant('{app}\{#AppExe}'), Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Log(Format('foxyvpn.exe %s finished with exit code %d (see %%TEMP%%\FoxyVPN-cleanup.log)', [Params, ResultCode]))
  else
    Log(Format('foxyvpn.exe %s could not be started: %s', [Params, SysErrorMessage(ResultCode)]));
end;
