# FoxyVPN on Android

Android 8 or newer. [Back to the README](../README.md)

## Install

1. Download the **FoxyVPN-Android** artifact from the [latest successful build](https://github.com/sepehrsharafi/FoxyVPN_Windows/actions/workflows/build.yml?query=branch%3Amain+is%3Asuccess)
   (signed in to GitHub), unzip it and open `FoxyVPN-Android.apk` on the phone.
2. Allow your browser or file manager to install apps when Android asks.
3. Google Play Protect may offer to scan the app, because it doesn't come from the Play Store. You can
   let it scan, or tap **Install anyway**.
4. Open FoxyVPN, sign in, pick a location and tap the switch. The first time, Android asks to allow
   the VPN connection.

To update, install the newer APK over the old one; your sign-in and settings stay.

## While connected

The notification shows where you are connected, the live download and upload speeds and the data
used this session, without having to expand it. Expand it for **Disconnect**.

## Quick Settings tile

FoxyVPN has a tile for the quick settings panel. Tap it while the VPN is off to connect to the
fastest location (every location is pinged first; the lowest ping wins), and tap it again to
disconnect. Signed out, it reads "Sign in first".

To add it on a Xiaomi phone (HyperOS / MIUI), pull down the **Control Center** (swipe down from the
top right), tap the **pencil** icon, and drag **FoxyVPN** into the active tiles. On other phones,
swipe down twice, tap the pencil and drag FoxyVPN in. The first time, the tile opens the app so you
can allow the VPN connection; after that it works on its own.

## Building it yourself

```bash
flutter build apk --release
```

The APK is in `build/app/outputs/flutter-apk/`. Without `android/key.properties` (see the comment at
the top of `android/app/build.gradle.kts`) it is signed with the debug key: it installs, but can't
update a copy signed with the release key.

## Signing the GitHub build (optional)

Android only installs an update over an app signed with the same key. Without your key, every
GitHub build is signed with a new throwaway debug key, so people have to uninstall the old version
before installing a newer APK. To have GitHub sign with your release key instead, add four
repository secrets (**Settings > Secrets and variables > Actions**):

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | the keystore file as base64 (see below) |
| `ANDROID_KEYSTORE_PASSWORD` | `storePassword` from `android/key.properties` |
| `ANDROID_KEY_ALIAS` | `keyAlias` from `android/key.properties` |
| `ANDROID_KEY_PASSWORD` | `keyPassword` from `android/key.properties` |

The base64 text of the keystore (PowerShell; use the `storeFile` path from `key.properties`):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\.foxyvpn\release.jks")) | Set-Clipboard
```

When you raise `version:` in `pubspec.yaml`, also raise the number after `+`, or Android refuses
the update.
