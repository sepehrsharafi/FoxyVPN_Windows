// Mozilla's own web page (accounts.firefox.com) loaded in a WebView, used to
// send requests as that page. On some networks Mozilla's edge answers
// /oauth/token with HTTP 406 to any app, yet answers the same request from its
// own page in a browser engine. Android only (the system WebView).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_log.dart';

const _pageUrl = 'https://accounts.firefox.com/';
const _loadTimeout = Duration(seconds: 30);
const _requestTimeout = Duration(seconds: 30);

/// What the page's fetch() got back.
class PageResponse {
  PageResponse(this.status, this.body);
  final int status;
  final String body;
}

class MozillaPage {
  /// Set by main() on Android. Off in tests, which have no WebView.
  static bool enabled = false;

  /// The app's one page while the app's window exists (AndroidFrame hosts it);
  /// null when the engine runs without a window (Android started the VPN).
  static final active = ValueNotifier<MozillaPage?>(null);

  static MozillaPage obtain() => active.value ??= MozillaPage();

  MozillaPage() {
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('FoxyFetch', onMessageReceived: (m) => _onReply(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          if (!_loaded.isCompleted && Uri.tryParse(url)?.host == 'accounts.firefox.com') _loaded.complete();
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame ?? true) AppLog.write('Mozilla page failed to load: ${error.description}');
        },
      ))
      ..loadRequest(Uri.parse(_pageUrl));
  }

  final controller = WebViewController();
  final _loaded = Completer<void>();
  final Map<int, Completer<PageResponse>> _pending = {};
  int _nextId = 0;

  /// Hosts the page off to the side (1x1, invisible): an Android WebView that is
  /// not in a window may not run the page's scripts.
  Widget host() => IgnorePointer(
        child: Opacity(opacity: 0, child: SizedBox(width: 1, height: 1, child: WebViewWidget(controller: controller))),
      );

  /// POSTs [body] to [uri] with fetch() from the page. Throws on a network error
  /// or timeout; any HTTP status is returned.
  Future<PageResponse> post(Uri uri, Map<String, String> headers, String body) => send('POST', uri, headers, body);

  /// [body] null sends none (GET).
  Future<PageResponse> send(String method, Uri uri, Map<String, String> headers, String? body) async {
    await _loaded.future.timeout(_loadTimeout,
        onTimeout: () => throw TimeoutException('Mozilla\'s page did not load'));
    final id = _nextId++;
    final reply = _pending[id] = Completer<PageResponse>();
    final init = {'method': method, 'headers': headers, 'body': ?body};
    // Default credentials, as the page itself uses for these endpoints.
    await controller.runJavaScript('''
(async () => {
  try {
    const r = await fetch(${jsonEncode(uri.toString())}, ${jsonEncode(init)});
    FoxyFetch.postMessage(JSON.stringify({id: $id, status: r.status, body: await r.text()}));
  } catch (e) {
    FoxyFetch.postMessage(JSON.stringify({id: $id, error: String(e)}));
  }
})();
''');
    try {
      return await reply.future.timeout(_requestTimeout);
    } finally {
      _pending.remove(id);
    }
  }

  void _onReply(String message) {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      final reply = _pending[data['id']];
      if (reply == null || reply.isCompleted) return;
      if (data['error'] != null) {
        reply.completeError(Exception('Mozilla page request failed: ${data['error']}'));
      } else {
        reply.complete(PageResponse(data['status'] as int, data['body'] as String? ?? ''));
      }
    } catch (_) {}
  }
}
