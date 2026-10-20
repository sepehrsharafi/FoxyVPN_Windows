# Local patches to http2 3.1.0

Vendored from pub.dev (`http2-3.1.0`, BSD-3-Clause, see LICENSE). Only `lib/`,
`LICENSE`, `README.md`, `CHANGELOG.md`, `AUTHORS` and `pubspec.yaml` are kept;
tests/examples were dropped. Wired in through `dependency_overrides` in the
app's `pubspec.yaml`.

Why: the stock connection-level receive window is fixed at 65535 bytes and its
credit is only returned when data is handed to an *unpaused* stream, so one
proxied flow whose app stops reading stalls every other flow on the connection.

Changes (all marked `PATCH(foxyvpn)`):

1. `lib/src/connection.dart`: the connection-level receive window starts at
   16 MiB (`_kConnectionWindowSize`) instead of 65535.
2. `lib/src/connection.dart` (`_setupConnection`): right after the initial
   SETTINGS frame, a connection-level WINDOW_UPDATE of `16 MiB - 65535` tells
   the peer about the larger window.
3. `lib/src/flowcontrol/connection_queues.dart`: `processDataFrame` returns
   connection-level credit (`dataProcessed`) as soon as a DATA frame is
   received, and `_tryDispatch` no longer returns it on delivery to the
   stream. Per-stream windows (credit still returned on delivery) continue to
   bound how much data can be buffered per stream.
4. `lib/transport.dart` + `lib/src/connection.dart`: new
   `ClientTransportConnection.isDraining` (true once a GOAWAY was received, the
   connection is finishing, or it was terminated). `isOpen` is also false while
   the peer's MAX_CONCURRENT_STREAMS is reached, so it cannot tell "full" from
   "will never accept streams again".
5. `lib/src/flowcontrol/window_handler.dart` (`dataProcessed`): never sends a
   WINDOW_UPDATE with increment 0. Because of (3) every DATA frame now returns
   credit, including empty ones (a bare END_STREAM), and a zero increment on
   stream 0 is a connection-level PROTOCOL_ERROR for the peer (RFC 9113 6.9).
6. `lib/src/settings/settings.dart`, `lib/src/connection.dart`,
   `lib/src/streams/stream_handler.dart`, `window_handler.dart`: upstream bug,
   exposed because the app sets `streamWindowSize`. When the peer ACKed *our*
   SETTINGS_INITIAL_WINDOW_SIZE, stock 3.1.0 added the difference to the
   *send* windows of every open stream (as if the peer had changed its
   setting), so a stream opened before the ACK could send ~1 MiB more than the
   peer allows (FLOW_CONTROL_ERROR). Now the ACK adjusts those streams'
   receive windows instead; only the peer's own setting changes send windows.
