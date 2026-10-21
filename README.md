# FoxyVPN for Windows

An unofficial Windows VPN client. It sends all of your computer's internet traffic through
Mozilla's Firefox VPN servers, using the free monthly data allowance of **your own Firefox
account**. It is a Windows port of the Android app FoxyVPN. It is not made or endorsed by Mozilla.

You need a Firefox account that is allowed to use the free VPN allowance. Your sign-in is stored
encrypted on your PC (Windows DPAPI) and only ever sent to Mozilla.

Windows 10 or 11, 64-bit.

## Install

1. Open the **Actions** tab of this GitHub project and click the latest green **Build Windows app** run.
2. Under **Artifacts**, download **FoxyVPN-Setup** and unzip it (GitHub wraps every download in a zip).
   Inside is `FoxyVPN-Setup-<version>.exe`.
3. Double-click it and accept the Windows administrator prompt. Because the installer is not
   code-signed, Windows SmartScreen may say "Windows protected your PC": click **More info**, then
   **Run anyway**.
4. Follow the wizard. It can add a desktop shortcut (off by default) and start FoxyVPN at the end.
5. In FoxyVPN, sign in, pick a location, press **Connect**. Press **Disconnect** (or just close the
   window) to go back to your normal connection.

FoxyVPN always asks for administrator rights when it starts: it needs them to create the virtual
network adapter and to change network routes.

Only one FoxyVPN runs at a time. Starting it again brings the open window to the front.

## Update

Download the newer `FoxyVPN-Setup-<version>.exe` and run it. It installs over the old version, in the
same folder, and keeps your sign-in and settings. If FoxyVPN is running, Setup asks first, then
disconnects the VPN, closes the app and carries on.

## Uninstall

Windows **Settings > Apps > Installed apps > FoxyVPN > Uninstall**.

1. If FoxyVPN is running, it is disconnected and closed first.
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

For scripts: `FoxyVPN-Setup-<version>.exe /VERYSILENT /NORESTART` installs without any window, and
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

## Android: Quick Settings tile

The Android app has a **FoxyVPN** tile for the quick settings panel. Tap it while the VPN is off to
connect to the fastest location (every location is pinged first, the lowest ping wins); tap it while it
is on or connecting to disconnect. While connected it shows the country, e.g. "Austria" (or the country you are
in). Signed out, it reads "Sign in first".

Adding it on a Xiaomi phone (HyperOS / MIUI): pull down the **Control Center** (swipe down from the top
right), tap the **pencil** (edit) icon, and drag **FoxyVPN** from the available tiles into the active
ones. Other Android phones: swipe down twice, tap the pencil, drag FoxyVPN in. The first time, the tile
opens the app so you can allow the VPN connection; after that it works without opening the app.

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
- **Setup or Uninstall says FoxyVPN did not close.** Close FoxyVPN with the close button of its
  window (that disconnects the VPN first), then run Setup or Uninstall again.
- **The internet is gone after FoxyVPN crashed.** Start FoxyVPN again: it removes what the crash
  left behind. Or reboot: the DNS rule is removed at startup.
- **"Windows protected your PC" when starting Setup.** The installer is not code-signed. **More
  info > Run anyway**.

## Portable copy (no installer)

The build also produces `FoxyVPN-Windows.zip` (artifact **FoxyVPN-Windows-portable-zip**): the same
folder as the installer installs. Unzip it, keep the files together, run `foxyvpn.exe`. It has no
uninstaller: to remove it, first run `foxyvpn.exe --cleanup` (add `--remove-data` to also delete
`%APPDATA%\FoxyVPN`) from an administrator command prompt in that folder, then delete the folder.

## Credits and licenses

- FoxyVPN for Windows: MIT license (see `LICENSE`). It is a port of FoxyVPN by Vauth, also MIT.
- [tun2socks](https://github.com/xjasonlyu/tun2socks) by xjasonlyu: MIT license
  (copy in `licenses/tun2socks-LICENSE.txt`).
- [Wintun](https://www.wintun.net/) by WireGuard LLC: Prebuilt Binaries License
  (copy in `licenses/wintun-LICENSE.txt`).
- Microsoft Visual C++ runtime DLLs, redistributed app-local
  (note in `licenses/Microsoft-VC-Runtime-NOTICE.txt`).
- Built with [Flutter](https://flutter.dev).

## Building it yourself

`flutter build windows --release` needs Visual Studio with the C++ desktop workload. Then copy
`tun2socks.exe` (from the tun2socks release zip, renamed), `wintun.dll` (amd64, from the Wintun zip) and
the three Visual C++ runtime DLLs (`VC\Redist\MSVC\<version>\x64\Microsoft.VC143.CRT` of your Visual
Studio) next to `foxyvpn.exe`. With [Inno Setup 6](https://jrsoftware.org/isinfo.php),
`ISCC.exe /DAppVersion=<pubspec version without +build> installer\foxyvpn.iss` then makes
`dist\FoxyVPN-Setup-<version>.exe`. The GitHub workflow in `.github/workflows/build-windows.yml` does
all of this and shows the exact versions, then installs and uninstalls the result once as a check.
