import 'package:flutter/material.dart';

import '../theme.dart';
import 'tabular_text.dart';

/// The ping as shown everywhere a location appears: "31 ms" (tabular,
/// 13 / 600 `textDim`). It never disappears: no reply reads "No reply", still
/// measuring is a tiny spinner.
class PingReadout extends StatelessWidget {
  const PingReadout({super.key, required this.ms, this.measuring = false});

  final int? ms;
  final bool measuring;

  /// What a screen reader says for a ping state.
  static String describe(int? ms, bool measuring) =>
      ms != null ? '$ms ms' : (measuring ? 'measuring ping' : 'no reply');

  @override
  Widget build(BuildContext context) {
    final value = ms;
    final style = FoxyText.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: FoxyColors.textDim);
    final Widget figure;
    if (value != null) {
      figure = TabularText('$value ms', style: style);
    } else if (measuring) {
      figure = const SizedBox.square(
        dimension: 11,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: FoxyColors.textFaint, strokeCap: StrokeCap.round),
      );
    } else {
      figure = Text('No reply', maxLines: 1, style: style.copyWith(color: FoxyColors.textFaint));
    }
    return Semantics(label: describe(value, measuring), excludeSemantics: true, child: figure);
  }
}
