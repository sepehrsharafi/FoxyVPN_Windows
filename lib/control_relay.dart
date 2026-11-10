// A Cloudflare Worker that forwards the app's own HTTPS (Guardian, Firefox
// Accounts, the server list) to Mozilla, for regions where Mozilla's edge
// answers HTTP 451. See relay/cloudflare/worker.js and lib/http_util.dart.
//
// The relay URL carries a secret in its query, so it is never logged: only its
// host is ([logName]).

import 'app_log.dart';

class ControlRelay {
  ControlRelay._();

  /// The relay the release was built with (--dart-define=FOXY_RELAY_URL=...), or empty.
  static const builtIn = String.fromEnvironment('FOXY_RELAY_URL');

  /// What the user typed in Account; wins over [builtIn] when not empty.
  static String userUrl = '';

  /// Tests only: lets a relay on a local plain-http server count as valid.
  static bool allowInsecure = false;

  /// How long requests go through the relay first once it was needed and worked.
  static const relayFirstFor = Duration(minutes: 10);

  /// Replaced in tests.
  static DateTime Function() clock = DateTime.now;

  static DateTime? _relayFirstUntil;

  /// [raw] as a relay URL, or null when it is not one (https only).
  static Uri? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme == 'https' || (allowInsecure && uri.scheme == 'http')) return uri;
    return null;
  }

  static bool get hasBuiltIn => parse(builtIn) != null;

  /// The relay in use: the user's, else the built-in one, else null.
  static Uri? get active {
    final user = userUrl.trim();
    return parse(user.isNotEmpty ? user : builtIn);
  }

  /// Whether requests to [target] may go through the relay. Firefox Accounts
  /// (sign-in, token refresh, its edge challenge) never does: its edge judges the
  /// client by its IP and the cookie a passed challenge earned from that IP, and
  /// from a Cloudflare Worker's IP it asks for a captcha (HTTP 406) the app cannot
  /// answer. Only Guardian and the server list need the relay.
  static bool carries(Uri target) {
    final host = target.host.toLowerCase();
    return host != 'firefox.com' && !host.endsWith('.firefox.com');
  }

  /// The relay's host (to pin while the VPN is up), or null without a relay.
  static String? get host => active?.host;

  /// The relay's address for [target]: its own query (the secret) plus `url=<target>`.
  static Uri forTarget(Uri relay, Uri target) => relay.replace(
    queryParameters: {...relay.queryParametersAll, 'url': [target.toString()]},
  );

  /// The headers the Worker adds to what it forwarded. A reply without one came
  /// from Cloudflare itself (quota used up, Worker error), not from Mozilla.
  static const markerHeaders = ['x-arman-relay', 'x-foxy-relay'];

  static bool get relayFirst {
    final until = _relayFirstUntil;
    if (until == null) return false;
    if (clock().isBefore(until)) return true;
    endRelayFirst();
    return false;
  }

  /// The relay got a request through that direct could not: go there first for a while.
  /// A window already running is not extended, so direct gets another try every 10 minutes.
  static void relayWorked(Uri relay) {
    if (relayFirst) return;
    _relayFirstUntil = clock().add(relayFirstFor);
    AppLog.write('Using the relay ${logName(relay)} first for the next 10 minutes');
  }

  static void endRelayFirst() {
    if (_relayFirstUntil == null) return;
    _relayFirstUntil = null;
    AppLog.write('Trying Mozilla directly again');
  }

  /// Forgets the window without a log line (a new network, sign-out, new relay).
  static void reset() => _relayFirstUntil = null;

  /// Host only: the query holds the secret.
  static String logName(Uri relay) => relay.host;
}
