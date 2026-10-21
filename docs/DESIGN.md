# FoxyVPN design

**One idea:** a quiet instrument panel on true black. Calm until it's protecting you, then a single
mint signal. Crisp layers instead of gradients, one glow in the whole app, no stock illustrations.
Confidence comes from restraint, precise spacing and one accent colour that *means* something.

## Window
- Fixed size **400 × 720**, not resizable, centred on first launch. No responsive layouts needed.
- **No native title bar.** A custom 40 px bar: the small mark on the left (no "FoxyVPN" text, the
  taskbar already says it), drag area across the middle, minimise + close on the right
  (thin 1.5 px line icons, 40 × 40 hit targets, close turns `#E5484D` on hover).
- The window title (taskbar / Alt+Tab) stays "FoxyVPN".
- Text scale is capped at 1.3 (Windows "make text bigger"); every screen is verified to hold at 1.3.

## Colour (dark only, true black base)
| Token | Hex | Use |
|---|---|---|
| `bg` | `#000000` | window background |
| `surface` | `#0E0F11` | cards, panel, inputs |
| `surfaceHi` | `#16171A` | hover, selected, inner tiles |
| `line` | `#212327` | 1 px hairlines and card borders |
| `text` | `#F5F6F8` | primary text |
| `textDim` | `#9BA0A9` | secondary text (7.99:1 on `bg`) |
| `textFaint` | `#7A818B` | captions, disabled, idle timer (5.34:1 on `bg`, 4.88:1 on `surface`, 4.56:1 on `surfaceHi`) |
| `accent` | `#3DDC97` | **only** for "protected" and the primary action |
| `accentInk` | `#06120C` | text on accent |
| `warn` | `#F5B544` | connecting / reconnecting, the conflict icon and dialog |
| `danger` | `#E5484D` | errors, unprotected-after-drop, the "VPN disconnected" dialog |

Two helper steps exist for states only: `pressed` `#1E2024` (pressed fill, hover on a selected item)
and `lineHi` `#2E3136` (hover borders, switch track).

Rules:
- Mint never decorates. If something is mint, you are protected (or it's the one button to press).
- One glow: while protected, a very faint radial wash (at most 8 % mint) sits behind the power
  switch. Nothing else glows; there are no drop shadows.

## Type
- **Urbanist**, bundled (SIL Open Font License 1.1, https://github.com/coreyhu/Urbanist). Static cuts
  only, in `assets/fonts/urbanist/`: Medium 500, SemiBold 600, Bold 700, ExtraBold 800, with `OFL.txt`
  (also shown on the Licenses page). **Nothing in the app is lighter than 500.**
- Urbanist has no tabular figures, so numbers that change (session timer, speeds) are set with
  `TabularText`: each digit sits in a fixed-width cell (the widest digit of the style).
- Scale (size / weight):
  - 46 / 700 big session timer
  - 30 / 800 sign-in headline
  - 16 / 700 titles and buttons
  - 15 / 500 body, 15 / 600 labels and country names
  - 13 / 500 captions (+0.1 tracking), 12 / 500 for tiny totals
  - 13 / 600 `textDim`, tabular: the ping ("31 ms")
  - 12 / 700 uppercase section labels (+1.2 tracking)
- The big timer ignores the text scale (it is already large); everything else follows it.

## Shape and space
- 8 pt grid. Screen padding 24. Panel and card radius 20, inner tiles and grid cards 14, inputs and
  buttons 12, chips 8, pills fully round.
- Cards: `surface` fill plus a 1 px `line` border. No drop shadows.
- Motion: 180–240 ms ease-out on state changes (colour, ring). Pages open and close with Android's zoom
  transition (the new page grows in from slightly smaller while fading in, the old one grows a touch and
  fades; both are snapshotted while moving). The back gesture and button just play the closing motion.
  Nothing loops except the connecting ring and the tiny spinner of a ping that is still being measured.
- Dialogs: centred, radius 20, `surface` with a `line` border, at most 340 wide, over a `bg` barrier at
  70 %. A 40 px tinted circle with a line icon, a 16 / 700 title, body text, and two equal buttons
  (secondary left, primary right; stacked, primary first, at large text). The primary button takes
  focus first, Tab stays inside, Esc closes, focus returns to what opened it. Dialogs float, so they
  never move anything underneath.

## Mark
- Fox-head shield from `lib/brand_geometry.dart` (two ears, chin point, a visor line cut through
  the face). Drawn with a CustomPainter in the app and rendered into the `.ico` by
  `tool/generate_icon.dart`. App icon: mint mark on a `bg` rounded square. In the UI the mark is
  `text` / `textDim`, never mint.

## Flags
- Real flags, as SVG art from the `country_flags` package (MIT; flag artwork from flag-icons, MIT),
  because Windows can't draw flag emoji. Both licenses are on the Licenses page.
- Shapes: **circle** (28–32 px) on the Home panel and the Locations grid; a 32 × 24 rounded rectangle
  (radius 6) is available for tight places. Always clipped, with a 1 px `line` hairline so white
  flags (Japan) don't vanish on black.
- Unknown or invalid code: the same shape with the two-letter code (12 / 800). Recommended: the fox mark.

## Screens

### 1. Sign in
- Large mark (64 px) top-left aligned with content, then the headline **"Private by default."**,
  then one dim line: "Sign in with your Firefox account to use its free monthly VPN data."
- Email, Password (with a show/hide eye, reachable by Tab), primary mint button "Sign in"
  (full width, 48 px).
- Code step: same layout, headline "Check your email", a dim line with the email address,
  one wide code field (letter-spaced, centred), "Confirm", and a text button "Use a different account".
- Errors: inline under the button in `danger`, short friendly sentences.
- Footer caption: "Unofficial client · not affiliated with Mozilla".

### 2. Home (the main screen)
Top to bottom:
1. Title bar.
2. **Top row:** caption on the left with only the data left ("11.0 GB left"; zero is "No data left" in
   `danger`; the reset date lives on the Account page), round avatar button on the right (the email's
   first letter, or a line person glyph when the email is unknown) → Account. Left of the avatar sits a **reserved 40 px slot**: while another proxy or
   VPN is active it holds a `warn` alert icon in a circle like the avatar's (tooltip "Another proxy or
   VPN is active") that reopens the conflict dialog. The slot is always there, so the icon appearing
   moves nothing.
3. **Big session timer** `00:41:51` (46 / 700, tabular). `00:00:00` in `textFaint` when there is no session.
   Each digit that changes rolls like an odometer (460 ms ease-out: the old digit drops out below, the
   new one rolls in from above, inside the digit's own clip). Ticks on whole seconds of the session.
4. **Status pill** directly under it, text only (no icons):
   - protected: `accent` at ~14 % fill, mint text "Protected"
   - not protected: neutral `surface` pill with a `line` border, "Not protected"
   - connecting / reconnecting: `warn` pill
   - dropped: `danger` pill ("Not protected"), and the hint under the switch reads "Click to reconnect"
5. **The power switch**, centred in the remaining space: 168 px. Idle: `surface` disc, 1 px `line` ring,
   a hairline ring just outside it, power glyph in `textDim`. Connecting: a thin `warn` arc rotating
   around it. Connected: 2 px `accent` ring, glyph in `accent`, and the one faint radial glow behind.
   Click anywhere on it to connect / disconnect. A small hint underneath ("Click to connect" …) in `textDim`.
6. **Bottom panel**, one card (radius 20, `surface`, `line` border), constant height in every state:
   - Location row: circular flag, country name (700), and underneath in `textDim` the city, or the
     exit IP while connected (falls back to the city when not known yet). On the right the ping
     ("31 ms", no signal bars) and "Change ›", which opens Locations. The ping is always there; no reply
     reads "No reply", still measuring is a tiny spinner. While connected it shows the last ping
     measured before connecting (a ping through the tunnel would mean nothing; refresh is off while
     connected and late replies are ignored). While connected the flag follows the real exit country.
   - Two inner tiles side by side (`surfaceHi`, radius 14), **Upload** and **Download**: a line icon in a
     32 px rounded square, a `textDim` label, the live speed (17 / 700, tabular, e.g. "1.2 MB/s"), and a
     tiny `textFaint` session total ("12.4 MB total"). Not connected: "—" dimmed.
- **Nothing on Home ever shifts.** The switch, timer, pill, avatar and panel sit at the same place in
  idle, connecting, connected, dropped and with conflicts (a test asserts it). The only inline notice
  is the error notice, a small `danger` box above the panel for a failed connect; it floats in the
  free space and only at large text does the switch shrink (down to 100 px) to make room for it.
- **Conflict dialog** (modal, no layout change): opens once per distinct set of conflicts per app run,
  after startup or when a connect starts and finds new ones. Title "Another proxy or VPN is active"
  (`warn` info icon), the full sentences as a bulleted list, a caption saying FoxyVPN never changes
  these settings, **Check again** (secondary, busy spinner, turns into "No conflicts found" when
  clean) and **Got it** (primary). The warn icon in the top row reopens it.
- **Dropped connection** (modal, no banner): opens once per drop. `danger` alert icon, title
  "VPN disconnected", "You're not protected right now." and the reason (at most 3 lines).
  **Reconnect** (primary, mint) connects and closes; **Dismiss** clears the error and closes. Esc or
  a click outside closes it and leaves the dropped state on Home (danger pill, "Click to reconnect").
- Never two dialogs: a drop closes an open conflict dialog first, and a conflict dialog waits until
  the drop dialog is gone. Dialogs open over whichever page is showing.

### 3. Locations
- Header: back arrow, title "Locations", refresh icon (disabled while connected).
- Search field (filters by country or city). Esc clears it, a second Esc goes back.
- **Recommended** first, full width: the fox mark, "Recommended", and a line "24 ms · Fastest ·
  Sweden". It connects to the **fastest location right now** (lowest ping among the real locations);
  only when none answered does it use Mozilla's own pick ("Mozilla's pick"). Its ping is that
  location's ping, so it is never slower than a card below it. Then an "ALL LOCATIONS" label and a
  **2-column grid** (10 px gaps), sorted by ping, no reply last.
- Each card (radius 14, `surface`, `line` border, 12 px padding) is one compact row: a 30 px circular
  flag, then the country name (15 / 700) over the ping ("31 ms", tabular, 13 / 600 `textDim`) and,
  for countries with several cities, " · City". No dead space: the card is exactly as tall as its
  two lines.
- **The ping is always visible**, on every card including the selected one and Recommended. No reply:
  "No reply" in `textFaint`. Still being measured: a tiny spinner. Refresh: every ping turns into a spinner at
  once and the refresh icon turns; each figure fades in as it arrives, the ping line keeps one text line's
  height (nothing on the card moves), and the grid holds its order until every reply is in, then reorders once.
- **Selection state:** `surfaceHi` fill plus a 1 px `textDim` border. No tick.
  **Hover:** a lighter fill and `lineHi` hairline (so it never looks selected). Keyboard focus: the
  neutral focus ring.
- Card height follows the text scale; every card is a Tab stop in reading order (Enter picks it).
- Flags are rasterised once per size and cached (the vector art is never re-parsed while scrolling);
  Home draws them in the background, a frame apart, as soon as the list arrives.
- Tap/click selects and goes back. While connected: picking a different location reconnects to it.

### 4. Account
- Header: back arrow, title "Account".
- Identity card (radius 20): avatar letter, email, caption "Firefox account".
- Data card: a slim 6 px bar of remaining / total in `accent` on `line`, "11.0 GB left of 50 GB",
  "Resets 1 Nov". Hide the parts Mozilla didn't send.
- "Allow apps the VPN can't carry" switch row (track `line` off / `accent` on), applies on the next connect.
- List rows: "Open log", "Licenses" (Flutter's `LicensePage`, styled dark, includes Urbanist and the flags),
  and at the bottom a `danger` text row "Sign out" (disabled while connected, with a caption saying why).
- Version caption at the very bottom.

## States that must look right
Preparing (startup cleanup), loading locations, locations failed (inline retry), no ping yet,
connecting, connected, reconnecting, disconnecting, quota used up, dropped (modal and Home), signed
out, a conflict (modal and the top-row icon), a location with no ping reply, a ping still being
measured, large text (1.3×).

## Android
The same app on phones (Android 8+, `com.foxyvpn.app`). The look is the same; only the shell differs.

**Layout.** No title bar and no window management. Edge to edge with dark system bars; the content stays
inside the safe area (status bar, navigation / gesture bar, cutout) and is at most 480 wide, centred, on
larger screens. Portrait. Designed and tested from 360 × 640 to 412 × 915 dp (and 1.3× text): on Home the
power switch flexes (168 down to 100) between the timer and the panel, and the panel stays anchored above
the bottom inset. The back gesture or button goes back a page. Touch wording says "Tap" where Windows
says "Click" (`Host.clickVerb`). "Open log" opens an in-app page (monospace text, Copy). The
"Allow apps the VPN can't carry" switch is not offered on Android.

**How the tunnel works.** Everything above the TUN layer is the shared Dart code. The TUN layer is a
Kotlin `VpnService` that creates the TUN (198.18.0.1/15, fd66:6f78:7976::1/64, routes 0.0.0.0/0 and ::/0,
DNS 198.18.0.2, MTU 1500; on Android 13+ the local ranges 10/8, 172.16/12, 192.168/16, 100.64/10,
169.254/16 and multicast are excluded) and runs **hev-socks5-tunnel** (MIT, built with the NDK, vendored
in `android/app/src/main/jni`) on it, pointed at the app's own SOCKS5 server on 127.0.0.1. hev sends UDP
as SOCKS5 UDP ASSOCIATE, so DNS (port 53) is answered by our server over DoH exactly as on Windows (hev's
mapdns is off). The app's own package is a disallowed application of the VPN, so the upstream connection
to Mozilla, the control-plane API and the pings never enter the tunnel: no loops, no `protect()`, no
bypass routes. Always-on VPN and "Block connections without VPN" work (the service answers the
`android.net.VpnService` action; the app then connects by itself).

**Process model (engine lifetime).** The tunnel core runs in one Flutter engine that does not belong to the
Activity: it lives in `FlutterEngineCache` (`FoxyEngine`), the Activity only attaches to it, and the
foreground service (ongoing notification, readable collapsed: title "Austria", line "↓ 1.2 MB/s   ↑ 84 KB/s   ·   312 MB" from hev's own counters, refreshed each second only while the screen is on; Disconnect action; type
`specialUse`) keeps the process, and so the engine, alive. Swiping the app away or turning the screen off
does not stop the VPN; reopening the app attaches to the running engine. With the VPN off, the engine is
destroyed when the Activity finishes. No wake lock. Dart and Kotlin talk over one MethodChannel
(`foxyvpn/vpn`) and one EventChannel (`foxyvpn/vpn/events`). The sign-in tokens are encrypted with an
Android Keystore AES-GCM key (`SecureStore`), the Android twin of the Windows DPAPI file.
**Quick Settings tile.** `FoxyTileService` (`vpn/FoxyTileService.kt`, label "FoxyVPN", icon
`ic_stat_foxy`, `BIND_QUICK_SETTINGS_TILE`). Tap while off: pings every location and connects to the
fastest. Tap while connecting or connected: disconnects. Subtitle: "Tap for fastest" (inactive), "Connecting…"
or "Austria" (active; connecting stays active so the tile reads "on" and a tap switches it off),
"Disconnecting…", and "Sign in first" when signed out (inactive, not unavailable: Android drops taps on an
unavailable tile, and the tap is what opens the app to sign in).
It is a *passive* tile (no `ACTIVE_TILE`): the system binds it every time the panel opens, so
`onStartListening` reads fresh status even if the process was killed; while the panel is open
`TileStatus.set` pushes changes. Kotlin keeps the phase and label in memory (`TileStatus`; a dead process
means no VPN) and "signed in" in SharedPreferences (the tile can be shown with no Dart running). Dart reports
both with `setTileState({signedIn, phase, label})` from `VpnController._syncTile` (called from `_notify`, only
when something changed, so it covers startup, sign-in and sign-out, connect, reconnect, disconnect); Windows
has no bridge and sends nothing.
Tap flow: not signed in, or `VpnService.prepare() != null` (consent needs an Activity) opens `MainActivity`
(`startActivityAndCollapse`: PendingIntent on API 34+, Intent below), with `EXTRA_QUICK_CONNECT` for the
consent case so it connects right after the user says yes. Otherwise a connected/connecting tile calls
`FoxyVpnService.requestDisconnect()` (the notification's Disconnect path; asks Dart directly if the service
is not up yet), and an off tile does `startForegroundService(ACTION_QUICK_CONNECT =
"com.foxyvpn.app.QUICK_CONNECT_FASTEST")`, a user interaction Android allows to start a foreground service
(specialUse has no extra while-in-use limits); if Android refuses anyway the app is opened instead. The
service enters the foreground at once, starts the shared engine without an Activity (`FoxyEngine.ensure`, the
always-on path), and emits a `quickConnect` event (queued in the Bridge backlog until Dart listens). Dart's
`VpnController.quickConnectFastest()`: signed in and idle only; measures again if the locations are older
than 2 minutes (or waits for pings still running), at most 6 s; picks the lowest ping among non-Recommended
locations, else Recommended, else the last selected; `select()` (saved) then `connect()`. If nothing comes
of it the service is told to stop (as for Always-on). A `disconnectRequested` while it is still pinging
cancels it. The VPN consent is the only step needing an Activity, and it is already granted after the first
connect; the notification permission is optional (the foreground service works without it).
