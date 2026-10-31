# FoxyVPN on Windows

Windows 10 or 11, 64-bit. [Back to the README](../README.md)

## Install

1. Download the **FoxyVPN-Windows** artifact from the [latest successful build](https://github.com/sepehrsharafi/FoxyVPN_Windows/actions/workflows/build.yml?query=branch%3Amain+is%3Asuccess)
   (signed in to GitHub) and unzip it.
2. Double-click `FoxyVPN-Setup.exe` and accept the Windows administrator prompt. Because the installer is not
   code-signed, Windows SmartScreen may say "Windows protected your PC": click **More info**, then
   **Run anyway**.
3. Follow the wizard. It can add a desktop shortcut (off by default) and start FoxyVPN at the end.
4. In FoxyVPN, sign in, pick a location, press **Connect**. Press **Disconnect** (or **Quit** in the
   tray icon's menu) to go back to your normal connection.

FoxyVPN always asks for administrator rights when it starts: it needs them to create the virtual
network adapter and to change network routes. Only one FoxyVPN runs at a time; starting it again
brings its window back to the front, also when it is hidden in the tray.

## Closing, the tray icon and quitting

Like most VPN apps, FoxyVPN keeps running when you close its window:

- **Close (X)** hides the window to the notification area ("system tray", next to the clock). The VPN
  stays connected. The first time, a notification tells you FoxyVPN is still running there.
- **Minimise (–)** works as in any other app: the window goes to the taskbar.
- **The tray icon** is the fox: mint while connected, grey otherwise. Hover it for the status.
  Click (or double-click) it to open the window again. Right-click it for a menu: **Open FoxyVPN**,
  the current status, **Connect** / **Disconnect** (to the location selected in the app), and
  **Quit FoxyVPN**.
- **Quit FoxyVPN** disconnects the VPN, restores your normal routes and DNS, and then exits.

Prefer the old behaviour, where closing the window disconnects and exits? Turn off **Run in the tray
when closed** under **Account**. Signing out of Windows or shutting down works as before.

## Update

Download the newer **FoxyVPN-Setup.exe** the same way and run it. It installs over the old version, in the
same folder, and keeps your sign-in and settings. If FoxyVPN is running (also when only in the tray),
Setup asks first, then disconnects the VPN, quits the app and carries on.

## Uninstall

Windows **Settings > Apps > Installed apps > FoxyVPN > Uninstall**.

1. If FoxyVPN is running (also when only in the tray), it is disconnected and quit first.
2. You are asked **"Also delete your saved sign-in and settings?"**. The default is **No**, which
   keeps them in case you install FoxyVPN again. A silent uninstall (`/VERYSILENT`) never deletes them.
3. Before any file is deleted, FoxyVPN's cleanup (`foxyvpn.exe --cleanup`) gives everything back
   (see the list below). Then the files are deleted.

Your sign-in and settings are stored per Windows user, in `%APPDATA%\FoxyVPN`. FoxyVPN runs as
administrator *as you*, so it is your own folder. If you start the uninstaller with another
administrator's password, "delete my data" removes that administrator's folder instead; delete
`%APPDATA%\FoxyVPN` yourself in that case.

Note: FoxyVPN's data lives in the `%APPDATA%` of the account that *elevated*. With an
over-the-shoulder UAC prompt (you are a standard user and an administrator types their password),
that is the administrator's profile, not yours. Sign-in and settings are then stored there, and the
app will not find them when it is started from another account.

For scripts: `FoxyVPN-Setup.exe /VERYSILENT /NORESTART` installs without any window, and
`"C:\Program Files\FoxyVPN\unins000.exe" /VERYSILENT` uninstalls and keeps your data.

## What the installer puts on your PC

Only this, in `C:\Program Files\FoxyVPN`:

- `foxyvpn.exe` and the Flutter files it needs (`flutter_windows.dll`, `data\`)
- `tun2socks.exe` and `wintun.dll` (the tunnel; see Credits)
- `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`: Microsoft's Visual C++ runtime, as private
  copies next to the app. **Nothing is installed system-wide** (no Visual C++ Redistributable), no
  PATH change, no Windows service.
- `licenses\`
- a Start Menu shortcut (and a desktop shortcut if you choose it) and the entry in Installed apps

## What FoxyVPN itself adds while you use it

| What | Where | When it is removed |
| --- | --- | --- |
| Virtual network adapter "FoxyVPN" (Wintun) and its routes and DNS servers | Windows networking | Disconnect (and uninstall, if one is left) |
| Routes to Mozilla's server and to your local network (not persistent) | Windows routing table | Disconnect |
| A DNS rule named "FoxyVPN" (NRPT) that sends every name lookup through the VPN | Windows registry | Disconnect |
| A scheduled task `FoxyVPN-DnsCleanup` (runs at boot and logon, removes the DNS rule if FoxyVPN was killed or Windows shut down while connected, then deletes itself) | Task Scheduler | Disconnect |
| Sign-in (encrypted), settings, log | `%APPDATA%\FoxyVPN` | Uninstall, only if you answer Yes |
| `install.json`: one line saying whether the Wintun driver was already on your PC | `%ProgramData%\FoxyVPN` (administrators only) | Uninstall |

If the app is killed in a way that skips the clean-up, your normal connection comes back by
itself: the tunnel helper stops with the app, and any leftover is removed the next time you start it
(or at the next boot, for the DNS rule).

### The Wintun driver

`wintun.dll` installs the Wintun network driver the first time FoxyVPN creates its adapter, unless
the driver is already there. Many VPNs and WireGuard use the same driver. So:

- Before FoxyVPN creates its first adapter, it notes in `install.json` whether the driver was
  already installed.
- On uninstall, the driver is removed **only if FoxyVPN was the one that installed it**, and only
  if no adapter of any other program still uses it (Windows refuses to remove a driver that is in use).
- The note lives in an administrators-only folder (`%ProgramData%\FoxyVPN`) and counts only if SYSTEM
  or Administrators own the file; a note anyone else could have written is ignored.
- If the driver was already on your PC, or there is no (trusted) note, it is left alone.

## Good to know

- Everything runs through the tunnel, including DNS (a "FoxyVPN" DNS rule is added while connected and
  removed again on disconnect). IPv6 goes through the tunnel as well, so nothing leaks around the VPN.
  Local network addresses (printers, file shares) stay reachable.
- Non-DNS UDP (for example some games, or QUIC in browsers) may not work; browsers fall back to
  normal HTTPS automatically.
- Problems? Press the document icon in the app to open the log (`%APPDATA%\FoxyVPN\log.txt`).
  Setup's own log is in your temp folder (`Setup Log ... .txt`); the uninstall cleanup writes
  `FoxyVPN-cleanup.log` there.
- Antivirus programs sometimes complain about `wintun.dll` or `tun2socks.exe`. Both are the
  official, unmodified downloads (checked by SHA-256 in the build).

## Troubleshooting

- **Claude Code / other apps don't work while connected.** Another proxy such as Happ is set as
  the Windows system proxy, so those apps send their traffic to it instead of the VPN. Quit that proxy
  program, or turn on **Allow apps the VPN can't carry** in FoxyVPN.
- **Setup or Uninstall says FoxyVPN did not close.** Right-click the FoxyVPN icon in the notification
  area and choose **Quit FoxyVPN** (that disconnects the VPN first), then run Setup or Uninstall again.
- **I closed FoxyVPN but the VPN is still on.** Closing the window only hides FoxyVPN to the tray.
  Use **Disconnect** or **Quit FoxyVPN** in the tray icon's menu (or turn off **Run in the tray when
  closed** under **Account**).
- **The internet is gone after FoxyVPN crashed.** Start FoxyVPN again: it removes what the crash
  left behind. Or reboot: the DNS rule is removed at startup.
- **"Windows protected your PC" when starting Setup.** The installer is not code-signed. **More
  info > Run anyway**.

## Portable copy (no installer)

The **FoxyVPN-Windows** artifact also has **FoxyVPN-Windows-portable.zip**: the same
folder as the installer installs. Unzip it, keep the files together, run `foxyvpn.exe`. It has no
uninstaller: to remove it, first run `foxyvpn.exe --cleanup` (add `--remove-data` to also delete
`%APPDATA%\FoxyVPN`) from an administrator command prompt in that folder, then delete the folder.

## Building it yourself

`flutter build windows --release` needs Visual Studio with the C++ desktop workload. Then copy
`tun2socks.exe` (from the tun2socks release zip, renamed), `wintun.dll` (amd64, from the Wintun zip) and
the three Visual C++ runtime DLLs (`VC\Redist\MSVC\<version>\x64\Microsoft.VC143.CRT` of your Visual
Studio) next to `foxyvpn.exe`. With [Inno Setup 6](https://jrsoftware.org/isinfo.php),
`ISCC.exe /DAppVersion=<pubspec version without +build> installer\foxyvpn.iss` then makes
`dist\FoxyVPN-Setup-<version>.exe`. The GitHub workflow in `.github/workflows/build-windows.yml` does
all of this and shows the exact versions, then installs and uninstalls the result once as a check.
