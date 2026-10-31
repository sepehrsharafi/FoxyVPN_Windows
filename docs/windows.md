# FoxyVPN on Windows

Windows 10 or 11, 64-bit. [Back to the README](../README.md)

## Install

1. Download the **FoxyVPN-Windows** artifact from the [latest successful build](https://github.com/sepehrsharafi/FoxyVPN_Windows/actions/workflows/build.yml?query=branch%3Amain+is%3Asuccess)
   (signed in to GitHub) and unzip it.
2. Double-click `FoxyVPN-Setup.exe` and accept the Windows administrator prompt. Because the installer is not
   code-signed, Windows SmartScreen may say "Windows protected your PC": click **More info**, then
   **Run anyway**.
3. Follow the wizard. It can add a desktop shortcut (off by default) and start FoxyVPN at the end.
4. In FoxyVPN, sign in, pick a location, press **Connect**. Press **Disconnect** (or just close the
   window) to go back to your normal connection.

FoxyVPN always asks for administrator rights when it starts: it needs them to create the virtual
network adapter and to change network routes. Only one FoxyVPN runs at a time; starting it again
brings the open window to the front.

## Update

Download the newer **FoxyVPN-Setup.exe** the same way and run it. It installs over the old version, in the
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

## WSL, Docker and the terminal

FoxyVPN works at the level of Windows' routing table, not per app, so most things on the PC use it
without any setup:

- **Terminal tools** (`curl`, `git`, `ssh`, `winget`, PowerShell, cmd) go through the VPN like every
  other program, as long as they are not told to use a proxy. A proxy setting sends their traffic to
  that proxy instead: `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` variables (curl, git, pip, npm...),
  `git config http.proxy`, the Windows system proxy (PowerShell 5.1, .NET tools) or the WinHTTP proxy
  (`netsh winhttp show proxy`; winget, Windows Update). FoxyVPN warns about the variables and both
  Windows proxies. A proxy on your local network (10.x, 172.16-31.x, 192.168.x) is reached
  *outside* the VPN, like printers. Ports Mozilla's server does not carry (for example SSH or mail)
  fail unless **Allow apps the VPN can't carry** is on, and then they are not hidden.
- **WSL 2, default (NAT) networking.** Windows forwards WSL's traffic out of the host's own routes, so
  it goes through the VPN. Programs inside WSL do not need any proxy settings. Name lookups:
  - with DNS tunneling (`dnsTunneling=true` in `.wslconfig`, the default in current WSL on
    Windows 11), WSL asks Windows, which sends every lookup through the VPN;
  - without it, `/etc/resolv.conf` points at the WSL gateway (`172.x.x.1`) and Windows' DNS proxy
    answers there. That proxy is expected to go through Windows' resolver (and so FoxyVPN's DNS
    rule) too; to be sure no lookup leaves outside the VPN, turn DNS tunneling on (`[wsl2]`
    section, `dnsTunneling=true`, then `wsl --shutdown`).

  If you set a fixed `nameserver` in `/etc/resolv.conf` yourself (`generateResolvConf = false`), that
  server is used; a server on your local network is then asked outside the VPN.
- **WSL 2, mirrored networking** (`networkingMode=mirrored`). WSL sees the Windows adapters, including
  "FoxyVPN", and its routes, and uses the VPN like any Windows program. DNS tunneling is on by default in
  this mode.
- **Docker Desktop** (WSL 2 backend) and VMs on Hyper-V's **Default Switch** are NATed by Windows like
  WSL, so they use the VPN too. A Hyper-V VM on an **External** virtual switch is bridged straight onto
  your network card and does *not* go through the VPN (it is like a separate PC on your LAN).
- WSL, Docker and VMs keep reaching your local network (printers, file shares, `localhost`
  forwarding) as before; only internet traffic goes through the VPN.

One-time steps, only if something does not work:

1. **WSL was already running when you connected** and does not get through (mirrored mode in
   particular): run `wsl --shutdown` in PowerShell or cmd once, then open WSL again. Docker Desktop:
   restart it. This is not needed after every connect, only when WSL started before the VPN.
2. Check from inside WSL: `curl https://ifconfig.me` (or any "what is my IP" site) should print the
   VPN's address, the same one FoxyVPN shows.
3. Plain UDP (games, some VoIP) has the same limits inside WSL as on Windows; QUIC falls back to
   HTTPS by itself.

FoxyVPN sets the "FoxyVPN" adapter's MTU to 1500 and turns on IPv4 forwarding for it while connected
(both are removed with the adapter on disconnect), so full-size packets from WSL and VMs fit and
their replies are forwarded back to them.

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
