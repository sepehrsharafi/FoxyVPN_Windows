// Test build only: signs in on Mozilla's own page (email, password and code are
// typed there), then checks each later step and shows which ones Mozilla
// refuses. Nothing is saved; the app's real sign-in is unchanged.
//
// The sign-in page part follows Vauth/FoxyVPN v1.0.8 (BrowserLoginScreen.kt):
// the page is told it runs in Firefox and hands the session over through
// Firefox's WebChannel messages.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app_log.dart';
import '../../fxa.dart';
import '../../guardian.dart';
import '../../http_util.dart';
import '../../mozilla_page.dart';
import '../../vpn_controller.dart';
import '../theme.dart';
import '../widgets/app_button.dart';
import '../widgets/page_header.dart';

const _signInUrl = 'https://accounts.firefox.com/?context=fx_desktop_v3&service=sync&action=email';
const _firefoxAndroidUa = 'Mozilla/5.0 (Android 14; Mobile; rv:132.0) Gecko/132.0 Firefox/132.0';
final _sessionHex = RegExp(r'^[0-9a-f]{64}$');

/// Forwards the page's WebChannel messages to the app, lets the app answer them,
/// and reports when the page shows that the sign-in finished.
const _hookJs = r'''
(function() {
  if (window.__foxyHooked) return;
  window.__foxyHooked = true;
  var send = function (o) { try { FoxyChannel.postMessage(JSON.stringify(o)); } catch (e) {} };
  var forward = function (detail) {
    var host = window.location.hostname;
    if (host !== 'accounts.firefox.com' && !host.endsWith('.firefox.com')) return;
    send({t: 'msg', payload: typeof detail === 'string' ? detail : JSON.stringify(detail)});
  };
  window.addEventListener('WebChannelMessageToChrome', function (e) { forward(e.detail); });
  document.addEventListener('WebChannelMessageToChrome', function (e) { forward(e.detail); });
  window.__foxyReply = function (channelId, messageId, command, dataJson) {
    var envelope = {id: channelId, message: {messageId: messageId, command: command, data: JSON.parse(dataJson)}};
    [envelope, JSON.stringify(envelope)].forEach(function (detail) {
      var ev = new CustomEvent('WebChannelMessageToContent', {detail: detail});
      window.dispatchEvent(ev);
      document.dispatchEvent(ev);
    });
  };
  var verifyUrl = function (u) {
    u = String((u && u.url) || u || '').toLowerCase();
    return u.indexOf('/verify') !== -1 || u.indexOf('/totp') !== -1 || u.indexOf('/session/verify') !== -1;
  };
  if (window.fetch) {
    var origFetch = window.fetch;
    window.fetch = function () {
      var url = arguments[0];
      return origFetch.apply(this, arguments).then(function (res) {
        if (res && res.ok && verifyUrl(url)) send({t: 'verified'});
        return res;
      });
    };
  }
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.addEventListener('load', function () {
      if (this.status >= 200 && this.status < 300 && verifyUrl(url)) send({t: 'verified'});
    });
    return origOpen.apply(this, arguments);
  };
})();
''';

bool _isSuccessUrl(String? url) {
  final u = (url ?? '').toLowerCase();
  return u.contains('/signin/confirmed') ||
      u.contains('/connect_another_device') ||
      u.contains('/pair') ||
      u.contains('/settings') ||
      u.contains('/complete') ||
      u.contains('success');
}

enum _Outcome { running, ok, failed, info }

class _Step {
  _Step(this.label);
  final String label;
  _Outcome outcome = _Outcome.running;
  String detail = '';
}

class PageSignInTestScreen extends StatefulWidget {
  const PageSignInTestScreen({super.key, required this.controller});

  final VpnController controller;

  @override
  State<PageSignInTestScreen> createState() => _PageSignInTestScreenState();
}

class _PageSignInTestScreenState extends State<PageSignInTestScreen> {
  // The app-wide page (hosted by AndroidFrame), the same one later token
  // refreshes use; a page of its own only if that is off.
  final _page = MozillaPage.enabled ? MozillaPage.obtain() : MozillaPage();
  final _signIn = WebViewController();
  final _steps = <_Step>[];
  String? _pendingSession;
  String? _email;
  bool _started = false;
  bool _waiting = false;
  bool _runNow = false;

  /// Set once every check passed: these tokens can sign the app in.
  AuthTokens? _usable;

  @override
  void initState() {
    super.initState();
    _signIn
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_firefoxAndroidUa)
      ..addJavaScriptChannel('FoxyChannel', onMessageReceived: (m) => _onPageMessage(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final host = Uri.tryParse(request.url)?.host ?? '';
          return host == 'accounts.firefox.com' || host.endsWith('.firefox.com')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onPageStarted: (url) => _hookPage(url),
        onPageFinished: (url) => _hookPage(url),
        onUrlChange: (change) {
          if (_isSuccessUrl(change.url)) _sessionVerified();
        },
      ))
      ..loadRequest(Uri.parse(_signInUrl));
  }

  void _hookPage(String url) {
    unawaited(_signIn.runJavaScript(_hookJs).catchError((_) {}));
    if (_isSuccessUrl(url)) _sessionVerified();
  }

  void _onPageMessage(String raw) {
    Map<String, dynamic> wrapper;
    try {
      wrapper = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (wrapper['t'] == 'verified') return _sessionVerified();
    Map<String, dynamic> message;
    try {
      final envelope = jsonDecode(wrapper['payload'] as String) as Map<String, dynamic>;
      message = (envelope['message'] as Map?)?.cast<String, dynamic>() ?? {};
    } catch (_) {
      return;
    }
    final command = message['command'] as String? ?? '';
    final data = (message['data'] as Map?)?.cast<String, dynamic>() ?? {};
    final messageId = '${message['messageId'] ?? ''}';
    String token() => ('${data['sessionToken'] ?? data['token'] ?? ''}').trim().toLowerCase();

    switch (command) {
      case 'fxaccounts:fxa_status':
        _reply(messageId, command, {'capabilities': {}, 'signedInUser': null});
      case 'fxaccounts:can_link_account':
        _reply(messageId, command, {'ok': true});
      case 'fxaccounts:login' || 'fxaccounts:oauth_login':
        if (data['email'] is String) _email = data['email'] as String;
        if (_sessionHex.hasMatch(token())) {
          _pendingSession = token();
          if (data['verified'] != false) _sessionVerified();
        }
        if (messageId.isNotEmpty) _reply(messageId, command, {'ok': true});
      default:
        if (command.toLowerCase().contains('verified')) {
          if (_sessionHex.hasMatch(token())) _pendingSession = token();
          _sessionVerified();
        }
        if (messageId.isNotEmpty) _reply(messageId, command, {'ok': true});
    }
  }

  void _reply(String messageId, String command, Map<String, dynamic> data) {
    final args = [jsonEncode('account_updates'), jsonEncode(messageId), jsonEncode(command), jsonEncode(jsonEncode(data))];
    unawaited(_signIn.runJavaScript('window.__foxyReply && window.__foxyReply(${args.join(', ')});').catchError((_) {}));
  }

  /// The page says the sign-in is done, but that can come before Mozilla has
  /// accepted the emailed code. The checks start once Mozilla confirms the
  /// session; meanwhile the page stays usable for typing the code.
  void _sessionVerified() {
    final session = _pendingSession;
    if (session == null || _started) return;
    _started = true;
    unawaited(_waitForConfirmedSession(session));
  }

  Future<void> _waitForConfirmedSession(String session) async {
    if (mounted) setState(() => _waiting = true);
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    String? lastSeen;
    var confirmed = false;
    while (mounted && DateTime.now().isBefore(deadline)) {
      String seen;
      try {
        final request = sessionStatusRequest(session);
        final r = await _page.send('GET', request.uri, request.headers, null);
        final data = r.status == 200 ? jsonDecode(r.body) as Map<String, dynamic> : null;
        confirmed = data?['sessionVerified'] == true;
        seen = data == null ? 'HTTP ${r.status} ${_excerpt(r.body)}' : 'sessionVerified=${data['sessionVerified']}';
      } catch (e) {
        seen = '$e';
      }
      if (seen != lastSeen) AppLog.write('Page sign-in test: session status: $seen');
      lastSeen = seen;
      if (confirmed || _runNow) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    if (!mounted) return;
    setState(() => _waiting = false);
    if (!confirmed && _runNow) AppLog.write('Page sign-in test: checks started by hand, last status: $lastSeen');
    if (confirmed || _runNow) {
      unawaited(_runChecks(session));
    } else {
      _finish(_add('Mozilla confirmed the sign-in'), _Outcome.failed, 'Not confirmed within 10 minutes: $lastSeen');
    }
  }

  Future<void> _runChecks(String session) async {
    final signedIn = _add('Signed in on Mozilla\'s page, sign-in confirmed')
      ..outcome = _Outcome.ok
      ..detail = _email ?? '';
    _log(signedIn);

    // Vauth's way: the app sends the token request itself. Expected to fail here.
    final direct = _add('Token request sent by the app itself (Vauth\'s way)');
    final directRequest = credentialsTokenRequest(session);
    try {
      final r = await sendJson('POST', directRequest.uri,
          body: utf8.encode(directRequest.body), headers: {'authorization': directRequest.headers['authorization']!});
      _finish(direct, _Outcome.info, 'HTTP ${r.statusCode}');
    } on BrowserCheckRequired {
      _finish(direct, _Outcome.info, 'HTTP 406, as expected for an app on this network');
    } catch (e) {
      _finish(direct, _Outcome.info, '$e');
    }

    final viaPage = _add('Token request sent from Mozilla\'s page');
    AuthTokens? tokens;
    // Mozilla may take a moment after confirming before the session counts as
    // confirmed here too ("Unconfirmed session", errno 138): retry a few times.
    for (var attempt = 1; attempt <= 4; attempt++) {
      try {
        final request = credentialsTokenRequest(session);
        final r = await _page.post(request.uri, request.headers, request.body);
        if (r.status == 200) {
          tokens = tokensFromResponse(jsonDecode(r.body) as Map<String, dynamic>);
          _finish(viaPage, _Outcome.ok, 'HTTP 200, got the VPN tokens${attempt > 1 ? ' (try $attempt)' : ''}');
          break;
        }
        final unconfirmed = r.status == 400 && r.body.contains('"errno":138');
        _finish(viaPage, unconfirmed && attempt < 4 ? _Outcome.running : _Outcome.failed,
            'HTTP ${r.status} ${_excerpt(r.body)}${unconfirmed && attempt < 4 ? ' (trying again)' : ''}');
        if (!unconfirmed) break;
      } catch (e) {
        _finish(viaPage, _Outcome.failed, '$e');
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    if (tokens == null) return;

    final pass = _add('VPN pass from vpn.mozilla.org');
    var passOk = false;
    try {
      final p = await GuardianClient().proxyPass(tokens.accessToken);
      passOk = true;
      _finish(pass, _Outcome.ok,
          p.quotaRemaining == null ? 'Got a pass' : 'Got a pass; ${p.quotaRemaining} of ${p.quotaMax} bytes left');
    } catch (e) {
      _finish(pass, _Outcome.failed, '$e');
    }
    if (passOk && mounted) setState(() => _usable = tokens);

    final refresh = _add('Daily token refresh from Mozilla\'s page');
    final refreshToken = tokens.refreshToken;
    if (refreshToken == null) {
      _finish(refresh, _Outcome.failed, 'Mozilla gave no refresh token');
      return;
    }
    try {
      final request = refreshTokenRequest(refreshToken);
      final r = await _page.post(request.uri, request.headers, request.body);
      _finish(refresh, r.status == 200 ? _Outcome.ok : _Outcome.failed, 'HTTP ${r.status} ${_excerpt(r.body)}');
    } catch (e) {
      _finish(refresh, _Outcome.failed, '$e');
    }
  }

  String _excerpt(String body) => body.length > 160 ? '${body.substring(0, 160)}...' : body;

  _Step _add(String label) {
    final step = _Step(label);
    if (mounted) setState(() => _steps.add(step));
    return step;
  }

  void _finish(_Step step, _Outcome outcome, String detail) {
    step
      ..outcome = outcome
      ..detail = detail;
    _log(step);
    if (mounted) setState(() {});
  }

  void _log(_Step step) => AppLog.write('Page sign-in test: ${step.label}: ${step.outcome.name} ${step.detail}');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FoxyColors.bg,
      body: SafeArea(
        child: Stack(
          children: [
            if (!MozillaPage.enabled) _page.host(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const PageHeader(title: 'Test Mozilla sign-in'),
                if (_waiting)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 0, FoxySpace.screen, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Waiting for Mozilla to confirm the sign-in. If the page asks for the code '
                          'from your email, enter it there; if the email has a confirm link instead, open it.',
                          style: FoxyText.caption,
                        ),
                        Center(
                          child: AppButton(
                            label: 'Run the checks now',
                            kind: AppButtonKind.text,
                            onPressed: () => setState(() => _runNow = true),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_steps.isEmpty)
                  Expanded(child: WebViewWidget(controller: _signIn))
                else
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(FoxySpace.screen),
                      children: [
                        for (final step in _steps) _StepRow(step),
                        if (_usable case final tokens?) ...[
                          const SizedBox(height: 8),
                          Text(
                            'It works. You can sign the app in with this account now; later token '
                            'refreshes also go through Mozilla\'s page.',
                            style: FoxyText.caption,
                          ),
                          const SizedBox(height: 12),
                          AppButton(
                            label: 'Sign in with this',
                            onPressed: () {
                              widget.controller.adoptSignIn(tokens, _email);
                              Navigator.of(context).maybePop();
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow(this.step);
  final _Step step;

  @override
  Widget build(BuildContext context) {
    final (mark, color) = switch (step.outcome) {
      _Outcome.running => ('…', FoxyColors.textDim),
      _Outcome.ok => ('✓', FoxyColors.accent),
      _Outcome.failed => ('✗', FoxyColors.danger),
      _Outcome.info => ('•', FoxyColors.warn),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 24, child: Text(mark, style: FoxyText.title.copyWith(color: color))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.label, style: FoxyText.title),
                if (step.detail.isNotEmpty)
                  SelectableText(step.detail, style: FoxyText.body.copyWith(color: FoxyColors.textDim)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
