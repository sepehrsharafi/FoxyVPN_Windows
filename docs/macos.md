# FoxyVPN on macOS

macOS 12 (Monterey) or newer, Apple Silicon or Intel. [Back to the README](../README.md)

## Install

1. Download the **FoxyVPN-macOS** artifact from the [latest successful build](https://github.com/sepehrsharafi/FoxyVPN_Windows/actions/workflows/build.yml?query=branch%3Amain+is%3Asuccess)
   (signed in to GitHub) and unzip it. It holds `FoxyVPN-macOS.dmg`.
2. Open the disk image and drag **FoxyVPN** onto the **Applications** folder next to it. Eject the
   disk image, then open FoxyVPN from Applications (not from the disk image: it has to run from
   the Applications folder).
3. The first time, macOS says it cannot verify FoxyVPN, because the app is not notarised by Apple
   (that needs a paid developer account). You allow it once:
   - **macOS 15 (Sequoia) or newer:** try to open FoxyVPN, close the message, open **System Settings >
     Privacy & Security**, scroll down to the Security section and click **Open Anyway** next to
     FoxyVPN. Confirm with your password or Touch ID.
   - **macOS 14 or older:** right-click (or Control-click) FoxyVPN, choose **Open**, then **Open** again.
   - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/FoxyVPN.app`
4. In FoxyVPN, sign in, pick a location, press **Connect**. The first time, macOS asks for your
   password once: FoxyVPN installs its small network helper (see below). macOS then shows a
   **"Background item added"** notification. That is the helper, and it is expected.
5. Press **Disconnect** (or **Quit FoxyVPN** in the menu bar icon's menu) to go back to your normal
   connection.

The helper is what lets a normal app (not run as administrator) create the VPN's network
interface and change routes and DNS. Only the app you installed can talk to it. Only one FoxyVPN
runs at a time.

## Closing, the menu bar icon and quitting

Like most VPN apps, FoxyVPN keeps running when you close its window:

- **Close (the red X in the window, or Cmd+W)** hides the window. FoxyVPN stays in the menu bar and
  the VPN stays connected.
- **Minimise (–)** works as in any other app: the window goes to the Dock.
- **The menu bar icon** is the fox: an outline while you are not connected, filled while you are.
  Hover it for the status. Click it for a menu: **Open FoxyVPN**, the current status,
  **Connect** / **Disconnect** (to the location selected in the app), and **Quit FoxyVPN**.
  Clicking the Dock icon opens the window again too.
- **Quit FoxyVPN** (the menu, or Cmd+Q, or Dock icon > Quit) disconnects the VPN, restores your
  normal routes and DNS, and then exits.

Prefer the old behaviour, where closing the window disconnects and exits? Turn off **Keep running
in the menu bar when closed** under **Account**. Logging out or shutting down works as before.

## Update

Download the newer **FoxyVPN-macOS.dmg** the same way. Quit FoxyVPN (menu bar icon > **Quit
FoxyVPN**), drag the new FoxyVPN onto Applications and choose **Replace**. Your sign-in and
settings are kept. If the new version needs a newer network helper, FoxyVPN installs it the next
time you connect (one more password prompt). macOS may ask you to allow the new copy once, like the
first time.

## Uninstall

1. Quit FoxyVPN (menu bar icon > **Quit FoxyVPN**).
2. To remove the helper at once, run this in Terminal **before** moving the app to the Trash:

   ```
   sudo "/Applications/FoxyVPN.app/Contents/Resources/helper/uninstall.sh"
   ```

   It stops the helper (which gives your DNS settings back first) and deletes everything in the
   table below.
3. Drag FoxyVPN from Applications to the Trash.

If you skip step 2, nothing is left running for long: the helper notices that the app is gone
within a few hours (it checks when it starts and every 6 hours), gives everything back, removes its
own files and exits.

Your sign-in and settings are in `~/Library/Application Support/FoxyVPN`. Delete that folder too
if you do not plan to use FoxyVPN again.

## What gets installed

The app itself is `/Applications/FoxyVPN.app`: the Flutter app, plus the helper's files in
`Contents/Resources/helper/` (including tun2socks' licence). The first connect copies them out, as
administrator, to:

| What | Where |
| --- | --- |
| The network helper (universal binary, root) | `/Library/PrivilegedHelperTools/com.foxyvpn.helper` |
| tun2socks (turns the virtual interface's traffic into the tunnel) | `/Library/Application Support/FoxyVPN/tun2socks` |
| Which app may use the helper, and the helper's version | `/Library/Application Support/FoxyVPN/helper.json` |
| What the helper has changed right now, so a crash can be undone | `/Library/Application Support/FoxyVPN/state.json` |
| The helper's log (capped at about 2 MB) | `/Library/Application Support/FoxyVPN/helper.log` |
| The LaunchDaemon that starts the helper at boot | `/Library/LaunchDaemons/com.foxyvpn.helper.plist` |
| The socket the app talks to the helper through | `/var/run/com.foxyvpn.helper.sock` |
| Sign-in, settings, the app's log | `~/Library/Application Support/FoxyVPN` |

No kernel extension, no network extension, no system extension, no change to the PATH.

While you are connected FoxyVPN also adds, and removes again on disconnect:

| What | When it is removed |
| --- | --- |
| A virtual interface `utunN` with its routes (everything goes through it) | Disconnect |
| Routes to Mozilla's server and to your local network (not persistent) | Disconnect |
| DNS servers on your network services (Wi-Fi, Ethernet...), pointing at the VPN | Disconnect, and the previous DNS settings are put back |

If the app is killed in a way that skips the clean-up, the helper notices the app is gone (the
connection to it closes) and undoes everything itself. If the helper is killed too, or the Mac loses
power, it undoes what is left the next time it starts, which is at boot.

## Good to know

- Everything runs through the tunnel, including DNS. FoxyVPN sets the DNS servers of your network
  services (**System Settings > Network**) to the VPN's while connected and puts your old ones back on
  disconnect, on a crash and at boot. IPv6 goes through the tunnel as well, so nothing leaks around the
  VPN. Local network addresses (printers, file shares, AirPlay devices) stay reachable.
- Non-DNS UDP (for example some games, or QUIC in browsers) may not work; browsers fall back to
  normal HTTPS automatically.
- Problems? Press the document icon in the app to open the log
  (`~/Library/Application Support/FoxyVPN/log.txt`). The helper's log is
  `/Library/Application Support/FoxyVPN/helper.log`.
- The helper only takes commands from the FoxyVPN app installed in Applications, so keep FoxyVPN in
  `/Applications` (not in a folder that other programs can write to).
- macOS lists the helper under **System Settings > General > Login Items & Extensions** (macOS 13 or
  newer). Leave it on: that is how it starts at boot to put your DNS back after a power cut.
- Other VPNs and proxy apps: FoxyVPN warns when it finds proxy environment variables
  (`HTTP_PROXY`, `ALL_PROXY`...) or a system proxy (**System Settings > Network > Details > Proxies**)
  that would send traffic around the VPN. Quit that app or turn the proxy off.

## Troubleshooting

- **"FoxyVPN cannot be opened because Apple cannot check it for malicious software."** The app is not
  notarised. See step 3 of Install (**Open Anyway**, or the `xattr` command).
- **"Move FoxyVPN to the Applications folder, then open it again."** FoxyVPN runs from a disk image or
  from a temporary place macOS made because the app was quarantined. Drag it to Applications,
  eject the disk image, and open it from there.
- **"Connecting needs your Mac password once..."** You cancelled the password prompt. Press
  Connect again and enter your password (the account must be an administrator).
- **The internet is gone after FoxyVPN or the Mac crashed.** Open FoxyVPN again: it asks the helper to
  undo what was left. Or reboot: the helper does it at start. As a last resort, delete the DNS servers
  yourself: **System Settings > Network > (your connection) > Details > DNS**.
- **I closed FoxyVPN but the VPN is still on.** Closing the window only hides FoxyVPN to the menu
  bar. Use **Disconnect** or **Quit FoxyVPN** in its menu (or turn off **Keep running in the menu
  bar when closed** under **Account**).
- **The menu bar icon is missing.** A crowded menu bar (especially on a Mac with a notch) hides
  icons that do not fit. Quit another menu bar app or use a menu bar manager; the Dock icon always
  brings the window back.
- **After an update FoxyVPN asks for the password again.** The network helper was updated too.
  That happens once per helper version.

## Building it yourself

You need a Mac with Xcode, [Flutter](https://flutter.dev) (the version in
`.github/workflows/build.yml`) and [Go](https://go.dev) 1.22 or newer.

1. `flutter build macos --release` builds `build/macos/Build/Products/Release/FoxyVPN.app`
   (universal, ad-hoc signed by Xcode).
2. Get the two tun2socks v2.7.0 darwin zips and its LICENSE from
   <https://github.com/xjasonlyu/tun2socks/releases/tag/v2.7.0>, and combine the binaries with
   `lipo -create ... -output tun2socks`, then `codesign --force --sign - tun2socks` (their SHA-256
   checksums are pinned in the workflow).
3. `bash macos_helper/build.sh <folder>` builds the universal `foxyvpn-helper` into `<folder>`.
4. Copy `foxyvpn-helper`, `tun2socks`, `macos_helper/install.sh`, `macos_helper/uninstall.sh`,
   `macos_helper/com.foxyvpn.helper.plist` and the tun2socks LICENSE (as `LICENSE-tun2socks.txt`) into
   `FoxyVPN.app/Contents/Resources/helper/`, and make the first four executable.
5. `codesign --force --deep --sign - FoxyVPN.app` seals the app with everything inside.

The GitHub workflow (`macos` job in `.github/workflows/build.yml`) does all of this, then starts the
app, installs the helper on the runner, sends traffic through a test tunnel, checks that routes and
DNS come back and the helper uninstalls, and finally builds the disk image with `hdiutil`.
Without an Apple developer account the app cannot be notarised, which is why the first start needs
**Open Anyway**.
