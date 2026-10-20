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
- Motion: 180–240 ms ease-out on state changes (colour, ring, page slide). Nothing loops except the
  connecting ring and the tiny spinner of a ping that is still being measured.
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
   first letter) → Account. Left of the avatar sits a **reserved 40 px slot**: while another proxy or
   VPN is active it holds a `warn` alert icon in a circle like the avatar's (tooltip "Another proxy or
   VPN is active") that reopens the conflict dialog. The slot is always there, so the icon appearing
   moves nothing.
3. **Big session timer** `00:41:51` (46 / 700, tabular). `00:00:00` in `textFaint` when there is no session.
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

### 3. Locations (slides in from the right)
- Header: back arrow, title "Locations", refresh icon (disabled while connected).
- Search field (filters by country or city). Esc clears it, a second Esc goes back.
- **Recommended** first, full width, with the fox mark and its ping on the right. Then an
  "ALL LOCATIONS" label and a **2-column grid** (352 px = 2 × 170 + 12 gap), sorted by ping, no reply last.
- Each card (radius 14, `surface`, `line` border, 12 px padding): a circular flag top-left; top-right
  the ping ("31 ms", tabular, 13 / 600 `textDim`); the country name (600/700)
  at the bottom, and under it the city in `textDim`, only for countries with several cities (one card
  per city). With a single city that line stays empty, so every card has the same height and the
  names line up.
- **The ping is always visible**, on every card including the selected one and Recommended. No reply:
  "No reply" in `textFaint`. Still being measured: a tiny spinner. Every location, Recommended included, is pinged at its first server.
- **Selection state:** `surfaceHi` fill plus a 1 px `textDim` border. No tick.
  **Hover:** a lighter fill only, no border change (so it never looks selected). Keyboard focus: the
  neutral focus ring. The two states are told apart by the border, hover by the fill.
- Card height follows the text scale; every card is a Tab stop in reading order (Enter picks it).
- No signal bars anywhere: the ping figure alone carries the information.
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
