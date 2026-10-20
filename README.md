# FoxyVPN for Windows

An unofficial Windows VPN client. It sends all of your computer's internet traffic through
Mozilla's Firefox VPN servers, using the free monthly data allowance of **your own Firefox
account**. It is a Windows port of the Android app FoxyVPN. It is not made or endorsed by Mozilla.

You need a Firefox account that is allowed to use the free VPN allowance. Your sign-in is stored
encrypted on your PC (Windows DPAPI) and only ever sent to Mozilla.

## Download and run

1. Open the **Actions** tab of this GitHub project and click the latest green **Build Windows app** run.
2. Under **Artifacts**, download **FoxyVPN-Windows-zip** (it contains `FoxyVPN-Windows.zip`).
3. Unzip it. Keep all the files together in one folder.
4. Double-click `foxyvpn.exe` and accept the Windows administrator prompt. (Administrator rights are
   needed to create the virtual network adapter and change the network routes.)
5. Sign in, pick a location, press **Connect**. Press **Disconnect** (or just close the window) to
   go back to your normal connection.

If the app is ever killed in a way that skips the clean-up, your normal connection comes back by
itself: the tunnel helper stops with the app, and any leftover is removed the next time you start it.

## Good to know

- Everything runs through the tunnel, including DNS (a "FoxyVPN" DNS rule is added while connected and
  removed again on disconnect). IPv6 is blocked inside the tunnel on purpose,
  so nothing leaks around the VPN; websites simply use IPv4.
- Non-DNS UDP (for example some games, or QUIC in browsers) may not work; browsers fall back to
  normal HTTPS automatically.
- Problems? Press the document icon in the app to open the log (`%APPDATA%\FoxyVPN\log.txt`).
- Antivirus programs sometimes complain about `wintun.dll` or `tun2socks.exe`. Both are the
  official, unmodified downloads (checked by SHA-256 in the build).

## Credits and licenses

- FoxyVPN for Windows: MIT license (see `LICENSE`). It is a port of FoxyVPN by Vauth, also MIT.
- [tun2socks](https://github.com/xjasonlyu/tun2socks) by xjasonlyu: MIT license
  (copy in `licenses/tun2socks-LICENSE.txt`).
- [Wintun](https://www.wintun.net/) by WireGuard LLC: Prebuilt Binaries License
  (copy in `licenses/wintun-LICENSE.txt`).
- Built with [Flutter](https://flutter.dev).

## Building it yourself

`flutter build windows --release` needs Visual Studio with the C++ desktop workload. Then copy
`tun2socks.exe` (from the tun2socks release zip, renamed) and `wintun.dll` (amd64, from the Wintun
zip) next to `foxyvpn.exe`. The GitHub workflow in `.github/workflows/build-windows.yml` does all
of this and shows the exact versions.
