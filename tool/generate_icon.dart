// Renders the FoxyVPN app icon: the mint fox mark on a dark rounded square.
//
//   dart run tool/generate_icon.dart
//
// Writes windows/runner/resources/app_icon.ico (16 to 256 px) and
// assets/brand/mark_256.png. The shapes come from lib/brand_geometry.dart, the
// same numbers the app draws its mark with.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:foxyvpn/brand_geometry.dart';
import 'package:image/image.dart' as img;

const _sizes = [16, 24, 32, 48, 64, 128, 256];

/// Each pixel is the average of this many samples per side.
const _supersample = 4;

/// The mark's outline spans x 0.14..0.86 and y 0.12..0.90 of its unit square.
/// It is scaled so that this box is [_markFill] of the icon, and centred.
const _markFill = 0.70;
const _boxHeight = 0.90 - 0.12;
const _boxCenter = (0.50, 0.51);

const _backgroundRadius = 0.22; // of the icon size
const _visorStroke = 0.07; // of the icon size

typedef Pt = (double, double);

void main() {
  final root = _projectRoot();
  final frames = {for (final s in _sizes) s: render(s)};

  final ico = File('${root.path}/windows/runner/resources/app_icon.ico');
  ico.parent.createSync(recursive: true);
  ico.writeAsBytesSync(encodeIco(frames));

  final png = File('${root.path}/assets/brand/mark_256.png');
  png.parent.createSync(recursive: true);
  png.writeAsBytesSync(img.encodePng(frames[256]!));

  stdout.writeln('Wrote ${ico.path} (${_sizes.join(', ')} px) and ${png.path}');
}

Directory _projectRoot() {
  // tool/generate_icon.dart -> project root
  final script = File.fromUri(Platform.script);
  return script.parent.parent;
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

img.Image render(int size) {
  final scale = _markFill * size / _boxHeight; // size of the mark's unit square, in pixels
  Pt place(Pt p) => (
    size / 2 + (p.$1 - _boxCenter.$1) * scale,
    size / 2 + (p.$2 - _boxCenter.$2) * scale,
  );
  final outline = roundedPolygon(
    [for (final p in foxMarkOutline) place(p)],
    foxMarkCornerRadius * scale,
  );
  final visorA = place(foxMarkVisor.$1);
  final visorB = place(foxMarkVisor.$2);
  final halfStroke = _visorStroke * size / 2;
  final cornerRadius = _backgroundRadius * size;

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
          final p = (x + (sx + 0.5) / n, y + (sy + 0.5) / n);
          if (!insideRoundedSquare(p, size.toDouble(), cornerRadius)) continue;
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

bool insideRoundedSquare(Pt p, double size, double radius) {
  final dx = math.max(math.max(radius - p.$1, p.$1 - (size - radius)), 0.0);
  final dy = math.max(math.max(radius - p.$2, p.$2 - (size - radius)), 0.0);
  return dx * dx + dy * dy <= radius * radius;
}

/// Even-odd point-in-polygon test.
bool insidePolygon(Pt p, List<Pt> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.$2 > p.$2) != (b.$2 > p.$2) &&
        p.$1 < (b.$1 - a.$1) * (p.$2 - a.$2) / (b.$2 - a.$2) + a.$1) {
      inside = !inside;
    }
  }
  return inside;
}

/// Distance to a segment: a "round-capped line" is everything within half the stroke of it.
double distanceToSegment(Pt p, Pt a, Pt b) {
  final abx = b.$1 - a.$1, aby = b.$2 - a.$2;
  final len2 = abx * abx + aby * aby;
  final t = len2 == 0
      ? 0.0
      : (((p.$1 - a.$1) * abx + (p.$2 - a.$2) * aby) / len2).clamp(0.0, 1.0);
  final cx = a.$1 + abx * t, cy = a.$2 + aby * t;
  return math.sqrt((p.$1 - cx) * (p.$1 - cx) + (p.$2 - cy) * (p.$2 - cy));
}

/// Replaces every corner by a small quadratic curve.
List<Pt> roundedPolygon(List<Pt> points, double radius, {int steps = 10}) {
  final out = <Pt>[];
  for (var i = 0; i < points.length; i++) {
    final prev = points[(i + points.length - 1) % points.length];
    final cur = points[i];
    final next = points[(i + 1) % points.length];
    Pt toward(Pt to) {
      final dx = to.$1 - cur.$1, dy = to.$2 - cur.$2;
      final len = math.sqrt(dx * dx + dy * dy);
      final r = math.min(radius, len / 2);
      return (cur.$1 + dx / len * r, cur.$2 + dy / len * r);
    }

    final start = toward(prev);
    final end = toward(next);
    for (var s = 0; s <= steps; s++) {
      final t = s / steps, u = 1 - t;
      out.add((
        u * u * start.$1 + 2 * u * t * cur.$1 + t * t * end.$1,
        u * u * start.$2 + 2 * u * t * cur.$2 + t * t * end.$2,
      ));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// ICO container: BMP entries for the small sizes, PNG for 256
// ---------------------------------------------------------------------------

Uint8List encodeIco(Map<int, img.Image> frames) {
  final entries = <(int, Uint8List)>[
    for (final e in frames.entries) (e.key, e.key >= 256 ? img.encodePng(e.value) : _bmpEntry(e.value)),
  ];
  final header = ByteData(6 + 16 * entries.length);
  header.setUint16(2, 1, Endian.little); // type: icon
  header.setUint16(4, entries.length, Endian.little);
  var offset = header.lengthInBytes;
  for (var i = 0; i < entries.length; i++) {
    final (size, data) = entries[i];
    final at = 6 + 16 * i;
    header.setUint8(at, size >= 256 ? 0 : size);
    header.setUint8(at + 1, size >= 256 ? 0 : size);
    header.setUint16(at + 4, 1, Endian.little); // planes
    header.setUint16(at + 6, 32, Endian.little); // bits per pixel
    header.setUint32(at + 8, data.length, Endian.little);
    header.setUint32(at + 12, offset, Endian.little);
    offset += data.length;
  }
  final out = BytesBuilder()..add(header.buffer.asUint8List());
  for (final (_, data) in entries) {
    out.add(data);
  }
  return out.toBytes();
}

/// A 32-bit DIB (bottom-up BGRA) plus the all-zero AND mask the format wants.
Uint8List _bmpEntry(img.Image image) {
  final w = image.width, h = image.height;
  final maskRow = ((w + 31) ~/ 32) * 4;
  final pixelBytes = w * h * 4;
  final data = ByteData(40 + pixelBytes + maskRow * h);
  data.setUint32(0, 40, Endian.little);
  data.setInt32(4, w, Endian.little);
  data.setInt32(8, h * 2, Endian.little);
  data.setUint16(12, 1, Endian.little);
  data.setUint16(14, 32, Endian.little);
  data.setUint32(20, pixelBytes + maskRow * h, Endian.little);
  var at = 40;
  for (var y = h - 1; y >= 0; y--) {
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x, y);
      data.setUint8(at++, p.b.toInt());
      data.setUint8(at++, p.g.toInt());
      data.setUint8(at++, p.r.toInt());
      data.setUint8(at++, p.a.toInt());
    }
  }
  return data.buffer.asUint8List();
}
