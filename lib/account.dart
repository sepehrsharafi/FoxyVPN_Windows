import 'fxa.dart';
import 'guardian.dart';
import 'token_store.dart';

/// Ties sign-in, saved tokens, and the Mozilla VPN entitlement together.
class Account {
  Account({FxaClient? fxa, TokenStore? store, GuardianClient? guardian})
      : _fxa = fxa ?? FxaClient(),
        _store = store ?? TokenStore(),
        _guardian = guardian ?? GuardianClient();

  final FxaClient _fxa;
  final TokenStore _store;
  final GuardianClient _guardian;
  AuthTokens? _tokens;

  bool get hasSavedSignIn => (_tokens ??= _store.load()) != null;

  Future<LoginStep> startLogin(String email, String password) async {
    final step = await _fxa.startLogin(email, password);
    if (step is LoginDone) _remember(step.tokens);
    return step;
  }

  Future<void> submitCode(String sessionToken, String code) async {
    _remember(await _fxa.submitCode(sessionToken, code));
  }

  /// Tokens obtained outside the email/password form (Mozilla's page sign-in).
  void adopt(AuthTokens tokens) => _remember(tokens);

  /// A valid access token, refreshing it if it has expired.
  Future<String> accessToken() async {
    final current = _tokens ??= _store.load();
    if (current == null) throw FxaError('Not signed in.', statusCode: 401);
    if (current.isFresh) return current.accessToken;
    try {
      final renewed = await _fxa.refresh(current);
      _remember(renewed);
      return renewed.accessToken;
    } on FxaError catch (e) {
      if (e.isPermanent) signOut();
      rethrow;
    }
  }

  /// Fetches a proxy pass; also confirms the account can use the free VPN.
  Future<ProxyPass> proxyPass() async => _guardian.proxyPass(await accessToken());

  void signOut() {
    _tokens = null;
    _store.clear();
  }

  void _remember(AuthTokens tokens) {
    _tokens = tokens;
    _store.save(tokens);
  }
}
