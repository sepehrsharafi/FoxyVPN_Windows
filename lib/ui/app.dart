import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

import '../vpn_controller.dart';
import 'screens/home_screen.dart';
import 'screens/sign_in_screen.dart';
import 'theme.dart';
import 'widgets/foxy_route.dart';
import 'widgets/title_bar.dart';

/// Largest text scale the app honours (Windows 'Make text bigger' / display scaling).
const maxTextScale = 1.3;

/// The whole app: dark theme, custom title bar, sign-in or home.
class FoxyApp extends StatelessWidget {
  const FoxyApp({super.key, required this.controller});

  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    registerUiLicenses();
    return MaterialApp(
      title: 'FoxyVPN',
      debugShowCheckedModeBanner: false,
      theme: buildFoxyTheme(),
      themeMode: ThemeMode.dark,
      scrollBehavior: const _FoxyScrollBehavior(),
      // The first page appears instantly; pushed pages slide in from the right.
      onGenerateRoute: (settings) =>
          foxyRoute<void>((_) => _Gate(controller: controller), settings: settings, instant: true),
      builder: (context, child) {
        // The window is a fixed 400 x 720, so the text scale is capped where the
        // layouts are verified to hold.
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(textScaler: media.textScaler.clamp(maxScaleFactor: maxTextScale)),
          child: ColoredBox(
            color: FoxyColors.bg,
            child: Column(
              children: [
                const TitleBar(),
                Expanded(child: ClipRect(child: child ?? const SizedBox.shrink())),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FoxyScrollBehavior extends MaterialScrollBehavior {
  const _FoxyScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
  };

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

/// Shows sign-in or home depending on the controller, and drops any pushed
/// pages (Account, Locations, ...) when the user signs out.
class _Gate extends StatefulWidget {
  const _Gate({required this.controller});

  final VpnController controller;

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  bool _wasSignedIn = false;

  @override
  void initState() {
    super.initState();
    _wasSignedIn = widget.controller.signedIn;
    widget.controller.addListener(_onChange);
  }

  @override
  void didUpdateWidget(_Gate old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
      _wasSignedIn = widget.controller.signedIn;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final signedIn = widget.controller.signedIn;
    if (_wasSignedIn && !signedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      });
    }
    if (signedIn != _wasSignedIn) setState(() {});
    _wasSignedIn = signedIn;
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = widget.controller.signedIn;
    return AnimatedSwitcher(
      duration: FoxySpace.page,
      switchInCurve: Curves.easeOut,
      child: signedIn
          ? HomeScreen(key: const ValueKey('home'), controller: widget.controller)
          : SignInScreen(key: const ValueKey('sign-in'), controller: widget.controller),
    );
  }
}
