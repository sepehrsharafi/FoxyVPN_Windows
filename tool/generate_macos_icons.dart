// Renders FoxyVPN's macOS icons.
//
//   dart run tool/generate_macos_icons.dart
//
// Writes into macos/Runner/Assets.xcassets:
//  * AppIcon.appiconset/app_icon_<size>.png (16 to 1024 px): the mint fox mark on
//    the near-black rounded square, like the Windows icon but with the ~10 %
//    transparent margin macOS icons have;
//  * StatusIconOff.imageset and StatusIconOn.imageset: the menu bar icon as a
//    template image (black on transparent; macOS tints it for light and dark menu
//    bars), 18 pt at 1x and 2x. Off is the fox outlined, On is the fox filled.
//
// The shapes come from lib/brand_geometry.dart, the numbers the app draws its mark
// with, and the drawing helpers from tool/generate_icon.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:foxyvpn/brand_geometry.dart';
import 'package:image/image.dart' as img;

import 'generate_icon.dart' show Pt, distanceToSegment, insidePolygon, insideRoundedSquare, roundedPolygon;

const _appIconSizes = [16, 32, 64, 128, 256, 512, 1024];

/// The rounded square is this much of the icon; the rest is transparent margin.
const _bodyFraction = 0.80;
const _bodyRadius = 0.2237; // of the body, Apple's icon grid
const _markFill = 0.70; // of the body, as in the Windows icon
const _visorStroke = 0.07; // of the body

/// The mark's outline spans x 0.14..0.86 and y 0.12..0.90 of its unit square.
const _boxHeight = 0.90 - 0.12;
const _boxCenter = (0.50, 0.51);

/// Each pixel is the average of this many samples per side.
const _supersample = 4;

const _statusPoints = 18; // menu bar icon size in points
const _statusFill = 0.92; // of the icon height
const _statusOutline = 0.09; // outline stroke of the "off" icon, of its size
const _statusVisor = 0.10; // visor stroke, of the icon size

void main() {
  final catalog = Directory('${_projectRoot().path}/macos/Runner/Assets.xcassets');

  final appIcon = Directory('${catalog.path}/AppIcon.appiconset')..createSync(recursive: true);
  for (final size in _appIconSizes) {
    File('${appIcon.path}/app_icon_$size.png').writeAsBytesSync(img.encodePng(renderAppIcon(size)));
  }
  File('${appIcon.path}/Contents.json').writeAsStringSync(_appIconContents());

  for (final (name, filled) in [('StatusIconOff', false), ('StatusIconOn', true)]) {
    final dir = Directory('${catalog.path}/$name.imageset')..createSync(recursive: true);
    for (final scale in [1, 2]) {
      File('${dir.path}/${name}_${scale}x.png').writeAsBytesSync(
        img.encodePng(renderStatusIcon(_statusPoints * scale, filled: filled)),
      );
    }
    File('${dir.path}/Contents.json').writeAsStringSync(_statusContents(name));
  }

  stdout.writeln('Wrote the macOS icons into ${catalog.path}');
}

Directory _projectRoot() => File.fromUri(Platform.script).parent.parent;

// ---------------------------------------------------------------------------
// Asset catalog files
// ---------------------------------------------------------------------------

String _appIconContents() {
  // (point size, scale) -> the PNG that holds those pixels.
  final entries = <Map<String, String>>[
    for (final (points, scale) in [
      (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
    ])
      {
        'size': '${points}x$points',
        'idiom': 'mac',
        'filename': 'app_icon_${points * scale}.png',
        'scale': '${scale}x',
      },
  ];
  return const JsonEncoder.withIndent('  ').convert({
    'images': entries,
    'info': {'version': 1, 'author': 'xcode'},
  });
}

String _statusContents(String name) => const JsonEncoder.withIndent('  ').convert({
  'images': [
    for (final scale in [1, 2]) {'idiom': 'universal', 'filename': '${name}_${scale}x.png', 'scale': '${scale}x'},
  ],
  'info': {'version': 1, 'author': 'xcode'},
  'properties': {'template-rendering-intent': 'template'},
});

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

img.Image renderAppIcon(int size) {
  final body = size * _bodyFraction;
  final offset = (size - body) / 2;
  final scale = _markFill * body / _boxHeight; // size of the mark's unit square, in pixels
  Pt place(Pt p) => (
    body / 2 + (p.$1 - _boxCenter.$1) * scale,
    body / 2 + (p.$2 - _boxCenter.$2) * scale,
  );
  final outline = roundedPolygon([for (final p in foxMarkOutline) place(p)], foxMarkCornerRadius * scale);
  final visorA = place(foxMarkVisor.$1);
  final visorB = place(foxMarkVisor.$2);
  final halfStroke = _visorStroke * body / 2;
  final radius = _bodyRadius * body;

  (int, int, int) rgb(int argb) => ((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
  final bg = rgb(brandBackground);
  final mint = rgb(brandAccent);

  final image = img.Image(width: size, height: size, numChannels: 4);
  const n = _supersample;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var r = 0.0, g = 0.0, b = 0.0, covered = 0;
      for (var sy = 0; sy < n; sy++) {
        for (var sx = 0; sx < n; sx++) {
          final p = (x + (sx + 0.5) / n - offset, y + (sy + 0.5) / n - offset);
          if (!insideRoundedSquare(p, body, radius)) continue;
          var c = bg;
          if (insidePolygon(p, outline)) {
            c = distanceToSegment(p, visorA, visorB) <= halfStroke ? bg : mint;
          }
          r += c.$1;
          g += c.$2;
          b += c.$3;
          covered++;
        }
      }
      if (covered == 0) {
        image.setPixelRgba(x, y, 0, 0, 0, 0);
      } else {
        image.setPixelRgba(
          x,
          y,
          (r / covered).round(),
          (g / covered).round(),
          (b / covered).round(),
          (255 * covered / (n * n)).round(),
        );
      }
    }
  }
  return image;
}

/// A menu bar template image: black with the shape as alpha. [filled]: the whole fox
/// with the visor cut out; otherwise only the fox's outline and the visor line.
img.Image renderStatusIcon(int size, {required bool filled}) {
  final scale = _statusFill * size / _boxHeight;
  Pt place(Pt p) => (
    size / 2 + (p.$1 - _boxCenter.$1) * scale,
    size / 2 + (p.$2 - _boxCenter.$2) * scale,
  );
  final outline = roundedPolygon([for (final p in foxMarkOutline) place(p)], foxMarkCornerRadius * scale);
  final visorA = place(foxMarkVisor.$1);
  final visorB = place(foxMarkVisor.$2);
  final halfVisor = _statusVisor * size / 2;
  final halfOutline = _statusOutline * size / 2;

  bool lit(Pt p) {
    final onVisor = distanceToSegment(p, visorA, visorB) <= halfVisor;
    if (filled) return insidePolygon(p, outline) && !onVisor;
    return onVisor && insidePolygon(p, outline) || _distanceToOutline(p, outline) <= halfOutline;
  }

  final image = img.Image(width: size, height: size, numChannels: 4);
  const n = _supersample;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var covered = 0;
      for (var sy = 0; sy < n; sy++) {
        for (var sx = 0; sx < n; sx++) {
          if (lit((x + (sx + 0.5) / n, y + (sy + 0.5) / n))) covered++;
        }
      }
      image.setPixelRgba(x, y, 0, 0, 0, (255 * covered / (n * n)).round());
    }
  }
  return image;
}

double _distanceToOutline(Pt p, List<Pt> poly) {
  var best = double.infinity;
  for (var i = 0; i < poly.length; i++) {
    best = math.min(best, distanceToSegment(p, poly[i], poly[(i + 1) % poly.length]));
  }
  return best;
}
