import 'package:flutter/material.dart';

import 'account.dart';
import 'fxa.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.account, required this.onSignedIn});

  final Account account;
  final VoidCallback onSignedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  String? _pendingSession;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() => _run(() async {
        final step = await widget.account.startLogin(_email.text, _password.text);
        switch (step) {
          case LoginDone():
            widget.onSignedIn();
          case LoginNeedsCode(:final sessionToken):
            setState(() => _pendingSession = sessionToken);
        }
      });

  Future<void> _submitCode() => _run(() async {
        await widget.account.submitCode(_pendingSession!, _code.text);
        widget.onSignedIn();
      });

  @override
  Widget build(BuildContext context) {
    final needsCode = _pendingSession != null;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('FoxyVPN', style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    needsCode
                        ? 'Mozilla emailed you a code. Enter it below.'
                        : 'Sign in with your Firefox account',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (!needsCode) ...[
                    TextField(
                      controller: _email,
                      decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      enabled: !_busy,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      enabled: !_busy,
                      onSubmitted: (_) => _signIn(),
                    ),
                  ] else
                    TextField(
                      controller: _code,
                      decoration: const InputDecoration(labelText: 'Code from email', border: OutlineInputBorder()),
                      autofocus: true,
                      enabled: !_busy,
                      onSubmitted: (_) => _submitCode(),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : (needsCode ? _submitCode : _signIn),
                    child: _busy
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(needsCode ? 'Confirm' : 'Sign in'),
                  ),
                  if (needsCode)
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _pendingSession = null),
                      child: const Text('Back'),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error), textAlign: TextAlign.center),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
