// Turns exceptions into short, plain-English sentences for the UI.

import 'dart:async';
import 'dart:io';

import 'fxa.dart' show FxaError;
import 'guardian.dart' show GuardianError;
import 'http_util.dart' show BrowserCheckRequired;
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
    return 'Could not reach the server. Check your internet connection and try again.';
  }
  if (e is HttpException || e is FormatException) {
    return 'The server sent an unexpected answer. Please try again in a moment.';
  }
  return 'Something went wrong. Open the log for details.';
}
