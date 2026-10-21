import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:country_flags/country_flags.dart' show FlagCode;
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show rootBundle;
import 'package:jovial_svg/jovial_svg.dart';

import '../theme.dart';
import 'fox_mark.dart';

enum FlagShape {
  /// A round flag with a hairline ring: the Home panel and the Locations grid.
  circle,

  /// A 32 x 24 rounded rectangle (radius 6) with a hairline border.
  rounded,
}

/// A country flag as SVG art (Windows can't draw flag emoji), clipped to a
/// circle or a rounded rectangle with a 1 px `line` hairline so white flags
/// don't vanish on black.
///
/// An unknown or invalid code falls back to the two-letter code in the same
/// shape. [recommended] shows the fox mark instead.
class FlagBadge extends StatelessWidget {
  const FlagBadge({
    super.key,
    required this.code,
    this.recommended = false,
    this.size = 32,
    this.shape = FlagShape.circle,
  });

  final String code;
  final bool recommended;

  /// Diameter for [FlagShape.circle]; the rounded shape is always 32 x 24.
  final double size;
  final FlagShape shape;


  /// Whether we have flag art for [code].
  static bool hasFlag(String code) => code.length == 2 && FlagCode.fromCountryCode(code) != null;

  @override
  Widget build(BuildContext context) {
    final circle = shape == FlagShape.circle;
    final w = circle ? size : 32.0;
    final h = circle ? size : 24.0;
    final radius = circle ? BorderRadius.circular(size / 2) : BorderRadius.circular(6);

    final Widget face;
    if (recommended) {
      face = ColoredBox(
        color: FoxyColors.surfaceHi,
        child: Center(
          child: FoxMark(size: (circle ? size : 24) * 0.56, color: FoxyColors.text),
        ),
      );
    } else if (hasFlag(code)) {
      face = FlagImage(code: code, width: w, height: h);
    } else {
      face = ColoredBox(
        color: FoxyColors.surfaceHi,
        child: Center(
          child: Text(
            code.toUpperCase(),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            textScaler: TextScaler.noScaling,
            style: FoxyText.badge.copyWith(fontSize: circle ? size * 0.36 : 12),
          ),
        ),
      );
    }

    return ExcludeSemantics(
      child: SizedBox(
        width: w,
        height: h,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: radius,
            shape: BoxShape.rectangle,
            border: Border.all(color: FoxyColors.line),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: SizedBox(width: w, height: h, child: face),
          ),
        ),
      ),
    );
  }
}

/// Flag art drawn once per code and pixel size, then kept for the app's life
/// (a few KB each). The package's own widget re-reads and re-parses the vector
/// file every time a flag is built (its cache size is 0), which made scrolling
/// the locations grid stutter on phones.
abstract final class FlagCache {
  static final _images = <String, ui.Image>{};
  static final _pending = <String, Future<ui.Image?>>{};
  static final _art = <String, Future<ScalableImage?>>{};

  static String _key(String code, int w, int h) => '${code.toUpperCase()}:$w:$h';

  /// The image if it is ready.
  static ui.Image? peek(String code, int w, int h) => _images[_key(code, w, h)];

  static Future<ui.Image?> load(String code, int w, int h) {
    final key = _key(code, w, h);
    final ready = _images[key];
    if (ready != null) return SynchronousFuture(ready);
    return _pending[key] ??= _draw(code, w, h).then((img) {
      _pending.remove(key);
      if (img != null) _images[key] = img;
      return img;
    });
  }

  /// Draws the given flags one after another, a frame apart, so the Locations
  /// page finds them ready without one long stall.
  static Future<void> warmUp(Iterable<(String code, int w, int h)> flags) async {
    for (final f in flags) {
      if (!FlagBadge.hasFlag(f.$1) || peek(f.$1, f.$2, f.$3) != null) continue;
      await load(f.$1, f.$2, f.$3);
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  static Future<ui.Image?> _draw(String code, int w, int h) async {
    final flagCode = FlagCode.fromCountryCode(code);
    if (flagCode == null || w <= 0 || h <= 0) return null;
    final art = await (_art[flagCode] ??= ScalableImage.fromSIAsset(
      rootBundle,
      'packages/country_flags/res/si/$flagCode.si',
    ).then<ScalableImage?>((a) => a, onError: (Object _) => null));
    if (art == null) return null;
    final bounds = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, bounds);
    // Cover: fill the box, centred, cropping the longer side.
    final vp = art.viewport;
    final scale = math.max(w / vp.width, h / vp.height);
    canvas
      ..translate(w / 2, h / 2)
      ..scale(scale)
      ..translate(-vp.center.dx, -vp.center.dy);
    art.paint(canvas);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(w, h);
    } finally {
      picture.dispose();
    }
  }
}

/// A flag (cover-fit) from [FlagCache] at the screen's pixel density; empty
/// until it is ready, which takes a frame or so the first time.
class FlagImage extends StatefulWidget {
  const FlagImage({super.key, required this.code, required this.width, required this.height});

  final String code;
  final double width;
  final double height;

  @override
  State<FlagImage> createState() => _FlagImageState();
}

class _FlagImageState extends State<FlagImage> {
  ui.Image? _image;
  String? _wanted;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(FlagImage old) {
    super.didUpdateWidget(old);
    _resolve();
  }

  void _resolve() {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = (widget.width * dpr).round();
    final h = (widget.height * dpr).round();
    final wanted = '${widget.code}:$w:$h';
    if (wanted == _wanted) return;
    _wanted = wanted;
    _image = FlagCache.peek(widget.code, w, h);
    if (_image != null) return;
    unawaited(
      FlagCache.load(widget.code, w, h).then((img) {
        if (mounted && _wanted == wanted) setState(() => _image = img);
      }),
    );
  }

  @override
  Widget build(BuildContext context) => RawImage(
    image: _image,
    width: widget.width,
    height: widget.height,
    fit: BoxFit.cover,
    filterQuality: FilterQuality.medium,
  );
}

