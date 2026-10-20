import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../errors.dart' show friendlyError;
import '../../fxa.dart' show LoginDone, LoginNeedsCode;
import '../../vpn_controller.dart';
import '../theme.dart';
import '../widgets/app_button.dart';
import '../widgets/fox_mark.dart';
import '../widgets/foxy_icon.dart';
import '../widgets/foxy_text_field.dart';
import '../widgets/pressable.dart';

/// Sign in with a Firefox account; a second step takes the emailed code.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.controller});

  final VpnController controller;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _codeFocus = FocusNode();

  String? _pendingSession;
  String? _pendingEmail;
  String? _error;
  bool _busy = false;
  bool _showPassword = false;

  bool get _needsCode => _pendingSession != null;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _canSignIn => _email.text.trim().isNotEmpty && _password.text.isNotEmpty;
  bool get _canConfirm => _code.text.trim().isNotEmpty;

  Future<void> _signIn() async {
    if (!_canSignIn) return;
    await _run(() async {
      final email = _email.text.trim();
      final step = await widget.controller.startLogin(email, _password.text);
      switch (step) {
        case LoginDone():
          break; // the controller flips to signed in; the app swaps the screen
        case LoginNeedsCode(:final sessionToken):
          if (mounted) {
            setState(() {
              _pendingSession = sessionToken;
              _pendingEmail = email;
              _code.clear();
            });
            _focusAfterBuild(_codeFocus);
          }
      }
    });
  }

  Future<void> _confirm() async {
    final session = _pendingSession;
    if (session == null || !_canConfirm) return;
    await _run(() => widget.controller.submitCode(session, _code.text.trim()));
  }

  void _back() {
    if (_busy) return;
    setState(() {
      _pendingSession = null;
      _pendingEmail = null;
      _error = null;
      _code.clear();
      _password.clear();
    });
    _focusAfterBuild(_emailFocus);
  }

  /// Autofocus only works on first build, and the old step is still in the tree
  /// while it fades out, so ask for focus explicitly.
  void _focusAfterBuild(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) node.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {if (_needsCode) const SingleActivator(LogicalKeyboardKey.escape): _back},
      child: Scaffold(
        backgroundColor: FoxyColors.bg,
        body: AutofillGroup(
          child: CustomScrollView(
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 24, FoxySpace.screen, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: FoxMark(size: 64, color: FoxyColors.text),
                      ),
                      const SizedBox(height: 28),
                      AnimatedSwitcher(
                        duration: FoxySpace.base,
                        switchInCurve: Curves.easeOut,
                        layoutBuilder: (current, previous) =>
                            Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                        child: _needsCode
                            ? _CodeStep(
                                key: const ValueKey('code'),
                                email: _pendingEmail ?? '',
                                controller: _code,
                                focusNode: _codeFocus,
                                busy: _busy,
                                error: _error,
                                onChanged: () => setState(() {}),
                                onConfirm: _canConfirm ? _confirm : null,
                                onBack: _busy ? null : _back,
                              )
                            : _CredentialsStep(
                                key: const ValueKey('credentials'),
                                email: _email,
                                emailFocus: _emailFocus,
                                password: _password,
                                passwordFocus: _passwordFocus,
                                showPassword: _showPassword,
                                busy: _busy,
                                error: _error,
                                onToggleShow: () => setState(() => _showPassword = !_showPassword),
                                onChanged: () => setState(() {}),
                                onSubmit: _canSignIn ? _signIn : null,
                              ),
                      ),
                      const Spacer(),
                      const SizedBox(height: 16),
                      Text(
                        'Unofficial client · not affiliated with Mozilla',
                        textAlign: TextAlign.center,
                        style: FoxyText.caption.copyWith(color: FoxyColors.textFaint),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.title, required this.subtitle});

  final String title;
  final Widget subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: FoxyText.display),
        const SizedBox(height: 12),
        subtitle,
        const SizedBox(height: 32),
      ],
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.error);

  final String? error;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: FoxySpace.base,
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: error == null
          ? const SizedBox(width: double.infinity)
          : Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  error!,
                  textAlign: TextAlign.center,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: FoxyText.body.copyWith(color: FoxyColors.danger, fontSize: 13, height: 1.4),
                ),
              ),
            ),
    );
  }
}

class _CredentialsStep extends StatelessWidget {
  const _CredentialsStep({
    super.key,
    required this.email,
    required this.emailFocus,
    required this.password,
    required this.passwordFocus,
    required this.showPassword,
    required this.busy,
    required this.error,
    required this.onToggleShow,
    required this.onChanged,
    required this.onSubmit,
  });

  final TextEditingController email;
  final FocusNode emailFocus;
  final TextEditingController password;
  final FocusNode passwordFocus;
  final bool showPassword;
  final bool busy;
  final String? error;
  final VoidCallback onToggleShow;
  final VoidCallback onChanged;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Headline(
          title: 'Private by default.',
          subtitle: Text(
            'Sign in with your Firefox account to use its free monthly VPN data.',
            style: FoxyText.body.copyWith(color: FoxyColors.textDim),
          ),
        ),
        FoxyTextField(
          label: 'Email',
          controller: email,
          focusNode: emailFocus,
          readOnly: busy,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.email],
          onChanged: (_) => onChanged(),
          onSubmitted: (_) => passwordFocus.requestFocus(),
        ),
        const SizedBox(height: 16),
        FoxyTextField(
          label: 'Password',
          controller: password,
          focusNode: passwordFocus,
          readOnly: busy,
          obscure: !showPassword,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.password],
          onChanged: (_) => onChanged(),
          onSubmitted: (_) => onSubmit?.call(),
          suffix: Pressable(
            onTap: onToggleShow,
            semanticLabel: showPassword ? 'Hide password' : 'Show password',
            tooltip: showPassword ? 'Hide password' : 'Show password',
            builder: (context, s) => SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: PressableBox(
                  state: s,
                  radius: 10,
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  child: FoxyIcon(
                    showPassword ? FoxyIcons.eyeOff : FoxyIcons.eye,
                    size: 20,
                    color: s.hovered ? FoxyColors.text : FoxyColors.textDim,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        AppButton(label: 'Sign in', busy: busy, onPressed: onSubmit),
        _ErrorText(error),
      ],
    );
  }
}

class _CodeStep extends StatelessWidget {
  const _CodeStep({
    super.key,
    required this.email,
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.error,
    required this.onChanged,
    required this.onConfirm,
    required this.onBack,
  });

  final String email;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final String? error;
  final VoidCallback onChanged;
  final VoidCallback? onConfirm;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Headline(
          title: 'Check your email',
          subtitle: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Enter the code Mozilla sent to '),
                TextSpan(
                  text: email,
                  style: const TextStyle(color: FoxyColors.text, fontWeight: FontWeight.w500),
                ),
                const TextSpan(text: '.'),
              ],
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: FoxyText.body.copyWith(color: FoxyColors.textDim),
          ),
        ),
        FoxyTextField(
          controller: controller,
          focusNode: focusNode,
          readOnly: busy,
          autofocus: true,
          hint: 'Code',
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          style: FoxyText.title.copyWith(
            fontSize: 22,
            letterSpacing: 6,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          onChanged: (_) => onChanged(),
          onSubmitted: (_) => onConfirm?.call(),
        ),
        const SizedBox(height: 24),
        AppButton(label: 'Confirm', busy: busy, onPressed: onConfirm),
        _ErrorText(error),
        const SizedBox(height: 8),
        Center(
          child: AppButton(label: 'Use a different account', kind: AppButtonKind.text, onPressed: onBack),
        ),
      ],
    );
  }
}
