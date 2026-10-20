import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart' show rootBundle;

/// Colour tokens from DESIGN.md. Dark only, on a true black base.
///
/// Rule: [accent] never decorates. If something is mint, you are protected
/// (or it is the one button to press).
abstract final class FoxyColors {
  static const bg = Color(0xFF000000);
  static const surface = Color(0xFF0E0F11);
  static const surfaceHi = Color(0xFF16171A);
  static const line = Color(0xFF212327);
  static const text = Color(0xFFF5F6F8);
  static const textDim = Color(0xFF9BA0A9);

  /// 5.34:1 on bg, 4.88:1 on surface, 4.56:1 on surfaceHi; clearly dimmer than textDim.
  static const textFaint = Color(0xFF7A818B);
  static const accent = Color(0xFF3DDC97);
  static const accentInk = Color(0xFF06120C);
  static const warn = Color(0xFFF5B544);
  static const danger = Color(0xFFE5484D);

  /// Slightly lighter / darker mint for the primary button's hover / pressed.
  static const accentHover = Color(0xFF58E8AA);
  static const accentPressed = Color(0xFF31C586);

  /// A step above surfaceHi: pressed fill, and hover on an already-selected item.
  static const pressed = Color(0xFF1E2024);

  /// A step above line: hover borders, switch track.
  static const lineHi = Color(0xFF2E3136);

  /// Keyboard focus ring: neutral, so it never competes with the mint signal.
  static const focus = Color(0xFFC9CED6);
}

/// Spacing and shape constants (8 pt grid).
abstract final class FoxySpace {
  static const double screen = 24;
  static const double panelRadius = 20;
  static const double cardRadius = 20;
  static const double tileRadius = 14;
  static const double controlRadius = 12;
  static const double chipRadius = 8;
  static const double titleBar = 40;
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration page = Duration(milliseconds: 220);
  static const Duration modalIn = Duration(milliseconds: 240);
  static const Duration modalOut = Duration(milliseconds: 180);
}

/// Urbanist, bundled (SIL OFL 1.1). Only Medium to ExtraBold are shipped:
/// nothing in the app is lighter than 500.
const foxyFontFamily = 'Urbanist';
const foxyFontFallback = ['Segoe UI', 'Arial'];

TextStyle _s(double size, FontWeight weight, Color color, {double letterSpacing = 0, double? height}) => TextStyle(
  fontFamily: foxyFontFamily,
  fontFamilyFallback: foxyFontFallback,
  fontSize: size,
  fontWeight: weight,
  color: color,
  letterSpacing: letterSpacing,
  height: height,
  decoration: TextDecoration.none,
);

/// Text styles. Urbanist has no tabular figures, so changing numbers go through
/// `TabularText` (fixed-width digit cells) instead of a font feature.
abstract final class FoxyText {
  /// 30 / 800: the sign-in headline.
  static final display = _s(30, FontWeight.w800, FoxyColors.text, height: 1.15, letterSpacing: -0.3);

  /// 16 / 700: titles.
  static final title = _s(16, FontWeight.w700, FoxyColors.text, height: 1.3);

  /// 15 / 500: body.
  static final body = _s(15, FontWeight.w500, FoxyColors.text, height: 1.4);

  /// 15 / 600: row labels.
  static final label = _s(15, FontWeight.w600, FoxyColors.text, height: 1.3);

  /// 13 / 500: captions.
  static final caption = _s(13, FontWeight.w500, FoxyColors.textDim, letterSpacing: 0.1, height: 1.35);

  /// 12 / 700, +1.2 tracking: tiny uppercase section labels.
  static final section = _s(12, FontWeight.w700, FoxyColors.textFaint, letterSpacing: 1.2);

  /// Big session timer: 46 / 700.
  static final timer = _s(46, FontWeight.w700, FoxyColors.text, letterSpacing: -0.5, height: 1.1);

  /// Fallback country code badge: 12 / 800.
  static final badge = _s(12, FontWeight.w800, FoxyColors.text, letterSpacing: 0.3);

  /// Button label: 16 / 700.
  static final button = _s(16, FontWeight.w700, FoxyColors.text, height: 1.2);
}

/// Raises every weight to at least 500, including the Material text theme the
/// license page and tooltips draw from.
TextStyle? _min500(TextStyle? s) {
  if (s == null) return null;
  final w = s.fontWeight;
  return (w == null || w.value < 500) ? s.copyWith(fontWeight: FontWeight.w500) : s;
}

TextTheme _heavyTextTheme(TextTheme t) => TextTheme(
  displayLarge: _min500(t.displayLarge),
  displayMedium: _min500(t.displayMedium),
  displaySmall: _min500(t.displaySmall),
  headlineLarge: _min500(t.headlineLarge),
  headlineMedium: _min500(t.headlineMedium),
  headlineSmall: _min500(t.headlineSmall),
  titleLarge: _min500(t.titleLarge),
  titleMedium: _min500(t.titleMedium),
  titleSmall: _min500(t.titleSmall),
  bodyLarge: _min500(t.bodyLarge),
  bodyMedium: _min500(t.bodyMedium),
  bodySmall: _min500(t.bodySmall),
  labelLarge: _min500(t.labelLarge),
  labelMedium: _min500(t.labelMedium),
  labelSmall: _min500(t.labelSmall),
);

bool _licensesRegistered = false;

/// Adds the licenses of what the UI bundles (the Urbanist font, the flag art)
/// to the page behind Account > Licenses. Safe to call more than once.
void registerUiLicenses() {
  if (_licensesRegistered) return;
  _licensesRegistered = true;
  LicenseRegistry.addLicense(() async* {
    try {
      final ofl = await rootBundle.loadString('assets/fonts/urbanist/OFL.txt');
      yield LicenseEntryWithLineBreaks(['Urbanist (font)'], ofl);
    } catch (_) {
      // Missing in a stripped test bundle; nothing to show.
    }
    yield const LicenseEntryWithLineBreaks(
      ['flag-icons (flag artwork, via country_flags)'],
      'MIT License\n\nCopyright (c) 2013 Panayiotis Lipis\n\n'
      'Permission is hereby granted, free of charge, to any person obtaining a copy of this software and '
      'associated documentation files (the "Software"), to deal in the Software without restriction, including '
      'without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell '
      'copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the '
      'following conditions:\n\n'
      'The above copyright notice and this permission notice shall be included in all copies or substantial '
      'portions of the Software.\n\n'
      'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT '
      'LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO '
      'EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER '
      'IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE '
      'USE OR OTHER DEALINGS IN THE SOFTWARE.',
    );
  });
}

ThemeData buildFoxyTheme() {
  const scheme = ColorScheme.dark(
    primary: FoxyColors.accent,
    onPrimary: FoxyColors.accentInk,
    secondary: FoxyColors.textDim,
    onSecondary: FoxyColors.bg,
    error: FoxyColors.danger,
    onError: FoxyColors.text,
    surface: FoxyColors.surface,
    onSurface: FoxyColors.text,
    onSurfaceVariant: FoxyColors.textDim,
    outline: FoxyColors.line,
    outlineVariant: FoxyColors.line,
    surfaceContainerLowest: FoxyColors.bg,
    surfaceContainerLow: FoxyColors.surface,
    surfaceContainer: FoxyColors.surface,
    surfaceContainerHigh: FoxyColors.surfaceHi,
    surfaceContainerHighest: FoxyColors.surfaceHi,
    surfaceTint: Colors.transparent,
    inverseSurface: FoxyColors.text,
    onInverseSurface: FoxyColors.bg,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: foxyFontFamily,
    fontFamilyFallback: foxyFontFallback,
  );

  final textTheme = _heavyTextTheme(
    base.textTheme
        .apply(
          bodyColor: FoxyColors.text,
          displayColor: FoxyColors.text,
          fontFamily: foxyFontFamily,
          fontFamilyFallback: foxyFontFallback,
        )
        .copyWith(
          bodyLarge: FoxyText.body,
          bodyMedium: FoxyText.body,
          bodySmall: FoxyText.caption,
          titleMedium: FoxyText.title,
          titleLarge: FoxyText.title,
          labelLarge: FoxyText.button,
          labelMedium: FoxyText.caption,
          labelSmall: FoxyText.caption,
        ),
  );

  OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(FoxySpace.controlRadius),
    borderSide: BorderSide(color: color, width: width),
  );

  return base.copyWith(
    scaffoldBackgroundColor: FoxyColors.bg,
    canvasColor: FoxyColors.bg,
    cardColor: FoxyColors.surface,
    dividerColor: FoxyColors.line,
    dividerTheme: const DividerThemeData(color: FoxyColors.line, thickness: 1, space: 1),
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    // No ripples anywhere: surfaces use hover and pressed fills instead.
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.white.withValues(alpha: 0.04),
    focusColor: Colors.white.withValues(alpha: 0.08),
    visualDensity: VisualDensity.standard,
    iconTheme: const IconThemeData(color: FoxyColors.textDim, size: 20),
    appBarTheme: AppBarThemeData(
      backgroundColor: FoxyColors.bg,
      foregroundColor: FoxyColors.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: FoxyText.title,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: FoxyColors.surface,
      hoverColor: FoxyColors.surfaceHi,
      isDense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: FoxyText.body.copyWith(color: FoxyColors.textFaint),
      errorStyle: FoxyText.caption.copyWith(color: FoxyColors.danger),
      border: border(FoxyColors.line),
      enabledBorder: border(FoxyColors.line),
      disabledBorder: border(FoxyColors.line),
      focusedBorder: border(FoxyColors.textDim, 1.5),
      errorBorder: border(FoxyColors.danger),
      focusedErrorBorder: border(FoxyColors.danger, 1.5),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: FoxyColors.text,
      selectionColor: FoxyColors.textDim.withValues(alpha: 0.35),
      selectionHandleColor: FoxyColors.textDim,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(4),
      radius: const Radius.circular(2),
      crossAxisMargin: 3,
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.dragged) || states.contains(WidgetState.hovered)
            ? FoxyColors.textFaint
            : FoxyColors.lineHi,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      showDuration: const Duration(seconds: 3),
      preferBelow: true,
      verticalOffset: 22,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: FoxyColors.surfaceHi,
        borderRadius: BorderRadius.circular(FoxySpace.chipRadius),
        border: Border.all(color: FoxyColors.line),
      ),
      textStyle: FoxyText.caption.copyWith(color: FoxyColors.text),
    ),
    listTileTheme: ListTileThemeData(
      textColor: FoxyColors.text,
      iconColor: FoxyColors.textDim,
      tileColor: Colors.transparent,
      titleTextStyle: FoxyText.body,
      subtitleTextStyle: FoxyText.caption,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: FoxyColors.textDim,
      linearTrackColor: FoxyColors.line,
      circularTrackColor: Colors.transparent,
    ),
  );
}
