// Turns exceptions into short, plain-English sentences for the UI.

import 'dart:async';
import 'dart:io';

import 'fxa.dart' show FxaError;
import 'guardian.dart' show GuardianError;
import 'control_relay.dart' show ControlRelay;
import 'http_util.dart' show BrowserCheckRequired, ControlPlane;
import 'tunnel/vpn_session.dart' show VpnStartError;
import 'tunnel/windows_tun.dart' show TunError;

/// Errors that already carry a readable message of their own keep it
/// ([QuotaExceeded] is a [GuardianError]).
String friendlyError(Object e) {
  if (e is TunError) return e.message;
  if (e is VpnStartError) return e.message;
  if (e is GuardianError) return e.message;
  if (e is FxaError) return e.message;
  if (e is BrowserCheckRequired) return e.toString();
  if (e is TimeoutException) {
    return 'The server took too long to answer. Check your internet connection and try again.';
  }
  if (e is TlsException) {
    return 'A secure connection could not be set up. Check that your PC\'s date and time are right, '
        'and that no program is intercepting your connection.';
  }
  if (e is SocketException) {
    if (_isMozillaConnectFailure(e)) {
      return ControlRelay.active == null
          ? 'Can\'t reach Mozilla\'s VPN service from this network. Set a relay server in Account.'
          : 'Can\'t reach Mozilla\'s VPN service, directly or through the relay.';
    }
    return 'Could not reach the server. Check your internet connection and try again.';
  }
  if (e is HttpException || e is FormatException) {
    return 'The server sent an unexpected answer. Please try again in a moment.';
  }
  return 'Something went wrong. Open the log for details.';
}

const _mozillaControlHosts = ['vpn.mozilla.org', 'firefox.settings.services.mozilla.com'];

/// A failed connect (timeout or refusal) to one of Mozilla's control-plane hosts.
/// Connections go to pinned addresses, so the error may name only the IP.
bool _isMozillaConnectFailure(SocketException e) {
  final text = '${e.message} ${e.address?.host ?? ''} ${e.osError?.message ?? ''}'.toLowerCase();
  final ip = e.address?.address;
  final named = _mozillaControlHosts.any(text.contains) ||
      (ip != null &&
          _mozillaControlHosts.any((h) => (ControlPlane.pinned[h] ?? const []).any((a) => a.address == ip)));
  if (!named) return false;
  final code = e.osError?.errorCode;
  return const {10060, 10061, 110, 111, 60, 61}.contains(code) ||
      text.contains('timed out') ||
      text.contains('refused');
}
