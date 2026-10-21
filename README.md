# FoxyVPN

A small VPN app for **Windows and Android** that sends your traffic through Mozilla's Firefox VPN
servers, using the free monthly data allowance of **your own Firefox account**.

Runs on **Windows** 10 / 11 (64-bit) and **Android** 8 or newer.

## Download and install

GitHub builds both apps every time the code changes. To get them:

1. Open the [latest successful build](https://github.com/sepehrsharafi/FoxyVPN_Windows/actions/workflows/build.yml?query=branch%3Amain+is%3Asuccess)
   and click the run at the top.
2. Scroll down to **Artifacts** and download **FoxyVPN-Windows** or **FoxyVPN-Android**. You need to
   be signed in to GitHub. Each download is a zip; unzip it.

**Windows:** run `FoxyVPN-Setup.exe` and accept the administrator prompt. The installer isn't
code-signed, so if Windows says "Windows protected your PC", click **More info**, then **Run anyway**.
(There's also `FoxyVPN-Windows-portable.zip` if you'd rather not install anything.)

**Android:** open `FoxyVPN-Android.apk` on your phone (download it there, or copy it over) and allow
installing apps from that source when Android asks. Google Play Protect may offer to scan it because
it doesn't come from the Play Store: let it scan, or tap **Install anyway**. The first time you
connect, Android asks you to allow the VPN.

Then sign in with your Firefox account, pick a location and connect.

## Why this exists

This is a personal project. I wanted a simple, good-looking VPN I could use on my PC and my phone
with the Firefox account I already have, so I built one, mostly by working with AI coding
assistants. It is the app I use myself, and I keep improving it as I go.

It started from [**FoxyVPN** by Vauth](https://github.com/Vauth/FoxyVPN), an unofficial Firefox
VPN client for Android. This project brings it to Windows and reworks the Android app.

## What it does

- Sign in with your Firefox account, pick a location (or **Recommended**, the fastest one right
  now) and connect.
- Everything goes through the tunnel, DNS included, so nothing leaks around the VPN.
- Live upload and download speeds, the data left this month, and a session timer.
- **Windows:** a normal installer, and a clean uninstall that puts your network back as it was.
- **Android:** a notification with live speeds and a Quick Settings tile that connects to the
  fastest location.

Your sign-in is stored encrypted on your device and is only ever sent to Mozilla.

More detail: [Windows guide](docs/windows.md) · [Android guide](docs/android.md)

## Not commercial, not official

This project is **not commercial**: it is free, with no ads and no tracking. It is **not made
or endorsed by Mozilla**. It only uses the free allowance that comes with your own Firefox account.

## Building

Built with [Flutter](https://flutter.dev). See [Windows](docs/windows.md#building-it-yourself) and
[Android](docs/android.md#building-it-yourself) for the steps.

The design notes are in [docs/DESIGN.md](docs/DESIGN.md).

## Credits and licenses

- FoxyVPN: MIT license (see [LICENSE](LICENSE)). Based on [FoxyVPN by Vauth](https://github.com/Vauth/FoxyVPN), also MIT.
- [tun2socks](https://github.com/xjasonlyu/tun2socks) by xjasonlyu (MIT) and
  [Wintun](https://www.wintun.net/) by WireGuard LLC on Windows.
- [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) by heiher (MIT) on Android.
- Microsoft Visual C++ runtime DLLs, shipped next to the Windows app.
