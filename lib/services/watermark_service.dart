import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

/// Overlay PNG berukuran panel + posisinya pada foto.
class WatermarkOverlay {
  final Uint8List png;
  final int x;
  final int y;
  const WatermarkOverlay(this.png, this.x, this.y);
}

/// Payload untuk isolate background.
class WatermarkBurnRequest {
  final String sourcePath;
  final String destPath;
  final List<String> lines;
  final Uint8List? logoBytes;
  final String style;
  final String position;
  final Uint8List? textOverlayBytes;

  /// Overlay TTF (TextPainter) yang dirender di main isolate. Dipakai hanya
  /// jika dimensi foto setelah bake EXIF cocok; jika tidak, isolate memakai
  /// renderer bitmap sebagai cadangan.
  final List<WatermarkOverlay> overlays;
  final int expectedWidth;
  final int expectedHeight;

  const WatermarkBurnRequest({
    required this.sourcePath,
    required this.destPath,
    required this.lines,
    this.logoBytes,
    this.style = 'classic',
    this.position = 'bottomRight',
    this.textOverlayBytes,
    this.overlays = const [],
    this.expectedWidth = 0,
    this.expectedHeight = 0,
  });
}

typedef _TimeInfo = ({String time, String dateText, String dayText});

class _Parsed {
  String? rawTime, address, gps, awb, custom;
  final extras = <String>[];
}

class _Row {
  final String kind; // clock | pin | gps | tag | dot
  final String? label;
  final String value;
  const _Row(this.kind, this.label, this.value);
}

class _RowPlan {
  final _Row row;
  final int labelW;
  final List<String> lines;
  const _RowPlan(this.row, this.labelW, this.lines);
}

class _Theme {
  final img.Color top, bottom, accent, icon, primary, muted, divider;
  final bool light;
  _Theme(this.top, this.bottom, this.accent, this.icon, this.primary,
      this.muted, this.divider, this.light);
}

// ═════════════════════ Abstraksi kanvas (layout dipakai bersama) ═════════════════════

abstract class _Cv {
  int tw(String t, double em, {bool bold = false});
  int lh(double em);

  /// Tinggi visual angka (cap-height) untuk ukuran em tertentu.
  int digitH(double em) => (em * 0.72).round();

  /// Menggambar angka/jam yang pusat visualnya tepat di garis [cy]
  /// (berdasarkan baseline & cap-height, bukan kotak baris).
  void timeText(String t,
      {required double em,
      required int x,
      required int cy,
      required img.Color color,
      bool shadow = true});
  void region(int x, int y, int w, int h);
  void rrect(int x1, int y1, int x2, int y2, int radius, img.Color color,
      {img.Color? bottom, int? cx1, int? cy1, int? cx2, int? cy2});
  void rect(int x1, int y1, int x2, int y2, img.Color color);
  void text(String t,
      {required double em,
      required int x,
      required int y,
      required img.Color color,
      bool bold = false,
      bool shadow = true});
  void icon(String kind, int cx, int cy, int size, img.Color color);
  void logoTile(img.Image logo, int x, int y, int logoW, int logoH, int tp,
      int radius, img.Color tile);

  List<String> wrap(String text, double em, int maxPx, {bool bold = false}) =>
      WatermarkService._wrapBy(text, maxPx, (s) => tw(s, em, bold: bold));
}

/// Renderer bitmap (pure Dart, aman di isolate). Cadangan jika TTF gagal.
class _ImgCv extends _Cv {
  final img.Image image;
  _ImgCv(this.image);

  @override
  int tw(String t, double em, {bool bold = false}) =>
      (WatermarkService._textWidth(t, WatermarkService._font) *
              WatermarkService._s(em))
          .round();

  @override
  int lh(double em) =>
      (WatermarkService._font.lineHeight * WatermarkService._s(em)).round();

  @override
  void timeText(String t,
      {required double em,
      required int x,
      required int cy,
      required img.Color color,
      bool shadow = true}) {
    // Pada font bitmap arial48, pusat angka ≈ 55% tinggi baris dari atas.
    WatermarkService._text(image, t,
        em: em, x: x, y: cy - (lh(em) * 0.55).round(),
        color: color, bold: true, shadow: shadow);
  }

  @override
  void region(int x, int y, int w, int h) {}

  @override
  void rrect(int x1, int y1, int x2, int y2, int radius, img.Color color,
      {img.Color? bottom, int? cx1, int? cy1, int? cx2, int? cy2}) {
    WatermarkService._fillRoundedRectBlended(image,
        x1: x1, y1: y1, x2: x2, y2: y2, radius: radius, color: color,
        colorBottom: bottom,
        clipX1: cx1, clipY1: cy1, clipX2: cx2, clipY2: cy2);
  }

  @override
  void rect(int x1, int y1, int x2, int y2, img.Color color) =>
      img.fillRect(image, x1: x1, y1: y1, x2: x2, y2: y2, color: color);

  @override
  void text(String t,
          {required double em,
          required int x,
          required int y,
          required img.Color color,
          bool bold = false,
          bool shadow = true}) =>
      WatermarkService._text(image, t,
          em: em, x: x, y: y, color: color, bold: bold, shadow: shadow);

  @override
  void icon(String kind, int cx, int cy, int size, img.Color color) =>
      WatermarkService._icon(image, kind, cx, cy, size, color);

  @override
  void logoTile(img.Image logo, int x, int y, int logoW, int logoH, int tp,
          int radius, img.Color tile) =>
      WatermarkService._logoTile(image, logo, x, y, logoW, logoH, tp, radius, tile);
}

class _Region {
  final int x, y, w, h;
  final ops = <void Function(ui.Canvas)>[];
  _Region(this.x, this.y, this.w, this.h);
}

/// Renderer TTF (TextPainter + Canvas): huruf vektor antialias penuh,
/// ikon berbasis path, gradasi asli. Hanya di main isolate (dart:ui).
class _UiCv extends _Cv {
  final int W, H;
  final ui.Image? logoUi;
  final regions = <_Region>[];
  final _cache = <String, TextPainter>{};
  _UiCv(this.W, this.H, this.logoUi);

  static ui.Color _c(img.Color c) =>
      ui.Color.fromARGB(c.a.toInt(), c.r.toInt(), c.g.toInt(), c.b.toInt());

  TextStyle _style(double em, bool bold,
          {ui.Color color = const ui.Color(0xFFFFFFFF), List<ui.Shadow>? shadows}) =>
      TextStyle(
        fontSize: em,
        height: 1.2,
        fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
        // Angka lebar-sama (tabular) agar jam rapi dan stabil.
        fontFeatures: const [ui.FontFeature.tabularFigures()],
        letterSpacing: bold ? em * 0.01 : 0,
        color: color,
        shadows: shadows,
      );

  TextPainter _measure(String t, double em, bool bold) {
    final key = '$t|$em|$bold';
    return _cache.putIfAbsent(key, () {
      return TextPainter(
        text: TextSpan(text: t, style: _style(em, bold)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
    });
  }

  @override
  int tw(String t, double em, {bool bold = false}) =>
      _measure(t, em, bold).width.ceil();

  @override
  int lh(double em) => _measure('Hg', em, false).height.round();

  @override
  int digitH(double em) => (em * 0.714).round(); // cap-height Roboto

  @override
  void timeText(String t,
      {required double em,
      required int x,
      required int cy,
      required img.Color color,
      bool shadow = true}) {
    final m = _measure(t, em, true);
    final baseline = m.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    // Baseline diletakkan agar angka (cap-height) simetris terhadap cy.
    final top = cy + em * 0.357 - baseline;
    final painter = TextPainter(
      text: TextSpan(
        text: t,
        style: _style(
          em, true,
          color: _c(color),
          shadows: shadow
              ? [
                  ui.Shadow(
                    color: const ui.Color(0xA8000000),
                    blurRadius: em * 0.10,
                    offset: ui.Offset(em * 0.025, em * 0.04),
                  )
                ]
              : null,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _add((c) => painter.paint(c, ui.Offset(x.toDouble(), top)));
  }

  void _add(void Function(ui.Canvas) op) {
    if (regions.isEmpty) return;
    regions.last.ops.add(op);
  }

  @override
  void region(int x, int y, int w, int h) {
    // Batasi overlay tepat pada kotak watermark. Margin ekstra membuat blur
    // shadow teks bisa merembes ke piksel tepi foto, terutama pada foto sempit.
    final x0 = x.clamp(0, W).toInt();
    final y0 = y.clamp(0, H).toInt();
    final x1 = (x + w).clamp(x0 + 1, W).toInt();
    final y1 = (y + h).clamp(y0 + 1, H).toInt();
    regions.add(_Region(x0, y0, math.max(1, x1 - x0), math.max(1, y1 - y0)));
  }

  @override
  void rrect(int x1, int y1, int x2, int y2, int radius, img.Color color,
      {img.Color? bottom, int? cx1, int? cy1, int? cx2, int? cy2}) {
    final rect = ui.Rect.fromLTRB(x1.toDouble(), y1.toDouble(), x2 + 1.0, y2 + 1.0);
    final rr = ui.RRect.fromRectAndRadius(rect, ui.Radius.circular(radius.toDouble()));
    final paint = ui.Paint()..isAntiAlias = true;
    if (bottom == null) {
      paint.color = _c(color);
    } else {
      paint.shader = ui.Gradient.linear(
        ui.Offset(0, y1.toDouble()),
        ui.Offset(0, y2 + 1.0),
        [_c(color), _c(bottom)],
      );
    }
    final clipped = cx1 != null || cy1 != null || cx2 != null || cy2 != null;
    final clip = ui.Rect.fromLTRB(
      (cx1 ?? x1).toDouble(), (cy1 ?? y1).toDouble(),
      (cx2 ?? x2) + 1.0, (cy2 ?? y2) + 1.0,
    );
    _add((c) {
      if (clipped) {
        c.save();
        c.clipRect(clip);
      }
      c.drawRRect(rr, paint);
      if (clipped) c.restore();
    });
  }

  @override
  void rect(int x1, int y1, int x2, int y2, img.Color color) {
    final r = ui.Rect.fromLTRB(x1.toDouble(), y1.toDouble(), x2 + 1.0, y2 + 1.0);
    final p = ui.Paint()..color = _c(color);
    _add((c) => c.drawRect(r, p));
  }

  @override
  void text(String t,
      {required double em,
      required int x,
      required int y,
      required img.Color color,
      bool bold = false,
      bool shadow = true}) {
    if (t.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: t,
        style: _style(
          em, bold,
          color: _c(color),
          shadows: shadow
              ? [
                  ui.Shadow(
                    color: const ui.Color(0xA8000000),
                    blurRadius: em * 0.14,
                    offset: ui.Offset(em * 0.03, em * 0.05),
                  )
                ]
              : null,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _add((c) => painter.paint(c, ui.Offset(x.toDouble(), y.toDouble())));
  }

  @override
  void icon(String kind, int cx, int cy, int size, img.Color color) {
    final s = size.toDouble();
    final ox = cx.toDouble(), oy = cy.toDouble();
    final fill = ui.Paint()..color = _c(color)..isAntiAlias = true;
    final stroke = ui.Paint()
      ..color = _c(color)
      ..isAntiAlias = true
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = s * 0.11
      ..strokeCap = ui.StrokeCap.round;
    _add((c) {
      switch (kind) {
        case 'clock':
          c.drawCircle(ui.Offset(ox, oy), s * 0.40, stroke);
          c.drawLine(ui.Offset(ox, oy), ui.Offset(ox, oy - s * 0.24), stroke);
          c.drawLine(ui.Offset(ox, oy), ui.Offset(ox + s * 0.18, oy + s * 0.06), stroke);
        case 'pin':
          final head = ui.Path()
            ..addOval(ui.Rect.fromCircle(center: ui.Offset(ox, oy - s * 0.12), radius: s * 0.30));
          final tip = ui.Path()
            ..moveTo(ox - s * 0.26, oy - s * 0.02)
            ..lineTo(ox, oy + s * 0.46)
            ..lineTo(ox + s * 0.26, oy - s * 0.02)
            ..close();
          final hole = ui.Path()
            ..addOval(ui.Rect.fromCircle(center: ui.Offset(ox, oy - s * 0.12), radius: s * 0.11));
          final outer = ui.Path.combine(ui.PathOperation.union, head, tip);
          c.drawPath(ui.Path.combine(ui.PathOperation.difference, outer, hole), fill);
        case 'gps':
          c.drawCircle(ui.Offset(ox, oy), s * 0.32, stroke);
          c.drawCircle(ui.Offset(ox, oy), s * 0.11, fill);
          for (final d in const [ui.Offset(0, -1), ui.Offset(0, 1), ui.Offset(-1, 0), ui.Offset(1, 0)]) {
            c.drawLine(ui.Offset(ox + d.dx * s * 0.38, oy + d.dy * s * 0.38),
                ui.Offset(ox + d.dx * s * 0.50, oy + d.dy * s * 0.50), stroke);
          }
        case 'tag':
          c.drawRRect(
              ui.RRect.fromRectAndRadius(
                  ui.Rect.fromCenter(center: ui.Offset(ox, oy), width: s * 0.84, height: s * 0.64),
                  ui.Radius.circular(s * 0.07)),
              stroke);
          final bar = ui.Paint()
            ..color = _c(color)
            ..strokeWidth = s * 0.07
            ..isAntiAlias = true;
          for (final dx in const [-0.15, 0.0, 0.15]) {
            c.drawLine(ui.Offset(ox + dx * s, oy - s * 0.12), ui.Offset(ox + dx * s, oy + s * 0.12), bar);
          }
        default:
          c.drawCircle(ui.Offset(ox, oy), s * 0.26, fill);
      }
    });
  }

  @override
  void logoTile(img.Image logo, int x, int y, int logoW, int logoH, int tp,
      int radius, img.Color tile) {
    final tileRect = ui.RRect.fromRectAndRadius(
      ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), logoW + tp * 2.0, logoH + tp * 2.0),
      ui.Radius.circular(radius.toDouble()),
    );
    final tilePaint = ui.Paint()..color = _c(tile)..isAntiAlias = true;
    final src = logoUi;
    final dst = ui.Rect.fromLTWH(x + tp.toDouble(), y + tp.toDouble(),
        logoW.toDouble(), logoH.toDouble());
    _add((c) {
      c.drawRRect(tileRect, tilePaint);
      if (src != null) {
        c.drawImageRect(
          src,
          ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
          dst,
          ui.Paint()..filterQuality = ui.FilterQuality.high..isAntiAlias = true,
        );
      }
    });
  }

  Future<List<WatermarkOverlay>> render() async {
    final out = <WatermarkOverlay>[];
    for (final r in regions) {
      if (r.ops.isEmpty) continue;
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      canvas.translate(-r.x.toDouble(), -r.y.toDouble());
      for (final op in r.ops) {
        op(canvas);
      }
      final pic = rec.endRecording();
      final image = await pic.toImage(r.w, r.h);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      pic.dispose();
      if (data == null) throw StateError('Gagal encode overlay watermark.');
      out.add(WatermarkOverlay(
        Uint8List.fromList(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)),
        r.x,
        r.y,
      ));
    }
    for (final p in _cache.values) {
      p.dispose();
    }
    return out;
  }
}

/// Watermark foto standar aplikasi profesional (timestamp/GPS camera).
/// Jalur utama: teks TTF antialias + ikon path + gradasi asli (dart:ui).
/// Jalur cadangan: renderer bitmap supersampling di isolate.
class WatermarkService {
  static const int _jpegQuality = 92;

  static Future<void> burn({
    required String sourcePath,
    required String destPath,
    required List<String> lines,
    Uint8List? logoBytes,
    String style = 'classic',
    String position = 'bottomRight',
  }) async {
    final nonEmptyLines = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);

    var overlays = const <WatermarkOverlay>[];
    var ew = 0, eh = 0;
    if (nonEmptyLines.isNotEmpty) {
      try {
        final r = await _renderTtfOverlays(
            sourcePath, nonEmptyLines, logoBytes, style, position);
        if (r != null) {
          overlays = r.$1;
          ew = r.$2;
          eh = r.$3;
        }
      } catch (e, st) {
        debugPrint('Watermark TTF gagal, memakai renderer cadangan: $e\n$st');
      }
    }

    await compute(
      _burnIsolate,
      WatermarkBurnRequest(
        sourcePath: sourcePath,
        destPath: destPath,
        lines: nonEmptyLines,
        logoBytes: logoBytes,
        style: style,
        position: position,
        overlays: overlays,
        expectedWidth: ew,
        expectedHeight: eh,
      ),
    );
  }

  static const _styles = {
    'classic', 'timemark', 'compact', 'top', 'modern', 'minimal', 'badge'
  };

  /// Dimensi foto setelah orientasi EXIF (tanpa decode piksel penuh).
  static Future<(int, int)?> _probeSize(Uint8List bytes) async {
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null) return null;
    var w = info.width, h = info.height;
    var orientation = 1;
    try {
      orientation = img.decodeJpgExif(bytes)?.imageIfd.orientation ?? 1;
    } catch (_) {}
    if (orientation >= 5 && orientation <= 8) {
      final t = w;
      w = h;
      h = t;
    }
    return (w, h);
  }

  static Future<(List<WatermarkOverlay>, int, int)?> _renderTtfOverlays(
    String sourcePath,
    List<String> lines,
    Uint8List? logoBytes,
    String style,
    String position,
  ) async {
    final bytes = await File(sourcePath).readAsBytes();
    final size = await _probeSize(bytes);
    if (size == null) return null;
    final (w, h) = size;

    img.Image? logoImg;
    ui.Image? logoUi;
    if (logoBytes != null) {
      final decoded = img.decodeImage(logoBytes);
      if (decoded != null) {
        logoImg = _removeConnectedDarkLogoBackground(decoded);
        final codec = await ui.instantiateImageCodec(
            Uint8List.fromList(img.encodePng(logoImg)));
        logoUi = (await codec.getNextFrame()).image;
        codec.dispose();
      }
    }
    try {
      final cv = _UiCv(w, h, logoUi);
      final ok = _drawCard(cv, w, h,
          lines: lines,
          logo: logoImg,
          style: _styles.contains(style) ? style : 'classic',
          position: position);
      if (!ok) return null; // jalur cadangan melaporkan error yang jelas
      return (await cv.render(), w, h);
    } finally {
      logoUi?.dispose();
    }
  }

  static int markerRadiusForLineHeight(int lineHeight) =>
      (lineHeight * 0.30).round().clamp(5, 16).toInt();

  // ───────────────────────── Primitif bitmap (cadangan) ─────────────────────────

  static int _ci(num v, int lo, int hi) => v.round().clamp(lo, hi).toInt();

  /// Skala watermark mengikuti sisi terpendek foto (setelah EXIF dibakar),
  /// sehingga ukuran relatif sama pada foto portrait maupun landscape.
  static double _unit(int width, int height) =>
      (math.min(width, height) / 1080).clamp(0.35, 3.75).toDouble();

  static void _fillRoundedRectBlended(
    img.Image image, {
    required int x1,
    required int y1,
    required int x2,
    required int y2,
    required int radius,
    required img.Color color,
    img.Color? colorBottom,
    int? clipX1,
    int? clipY1,
    int? clipX2,
    int? clipY2,
  }) {
    final left = x1.clamp(0, image.width - 1).toInt();
    final top = y1.clamp(0, image.height - 1).toInt();
    final right = x2.clamp(0, image.width - 1).toInt();
    final bottom = y2.clamp(0, image.height - 1).toInt();
    if (right < left || bottom < top) return;

    final r = radius
        .clamp(0, math.min((right - left) ~/ 2, (bottom - top) ~/ 2))
        .toInt();
    final span = math.max(1, bottom - top).toDouble();
    final end = colorBottom ?? color;

    for (var y = top; y <= bottom; y++) {
      if (clipY1 != null && y < clipY1) continue;
      if (clipY2 != null && y > clipY2) continue;
      final t = (y - top) / span;
      final red = color.r.toDouble() + (end.r.toDouble() - color.r.toDouble()) * t;
      final green = color.g.toDouble() + (end.g.toDouble() - color.g.toDouble()) * t;
      final blue = color.b.toDouble() + (end.b.toDouble() - color.b.toDouble()) * t;
      final baseAlpha =
          (color.a.toDouble() + (end.a.toDouble() - color.a.toDouble()) * t) / 255.0;

      for (var x = left; x <= right; x++) {
        if (clipX1 != null && x < clipX1) continue;
        if (clipX2 != null && x > clipX2) continue;

        var coverage = 1.0;
        if (r > 0) {
          final cx = x < left + r ? left + r : (x > right - r ? right - r : x);
          final cy = y < top + r ? top + r : (y > bottom - r ? bottom - r : y);
          final dx = x - cx;
          final dy = y - cy;
          if (dx != 0 || dy != 0) {
            final dist = math.sqrt((dx * dx + dy * dy).toDouble());
            coverage = (r + 0.5 - dist).clamp(0.0, 1.0).toDouble();
            if (coverage <= 0) continue;
          }
        }

        final a = (baseAlpha * coverage).clamp(0.0, 1.0);
        if (a <= 0) continue;
        final p = image.getPixel(x, y);
        image.setPixelRgb(
          x,
          y,
          (red * a + p.r.toDouble() * (1 - a)).round(),
          (green * a + p.g.toDouble() * (1 - a)).round(),
          (blue * a + p.b.toDouble() * (1 - a)).round(),
        );
      }
    }
  }

  static img.BitmapFont get _font => img.arial48;

  static int _textWidth(String text, img.BitmapFont font) {
    var width = 0;
    for (final rune in text.runes) {
      width += font.characterXAdvance(String.fromCharCode(rune));
    }
    return width;
  }

  static double _s(double em) => (em / 48.0).clamp(0.2, 4.0).toDouble();

  /// Teks antialias bitmap: render 48px lalu perkecil (area-average).
  static void _text(
    img.Image dst,
    String text, {
    required double em,
    required int x,
    required int y,
    required img.Color color,
    bool bold = false,
    bool shadow = true,
  }) {
    if (text.isEmpty) return;
    final s = _s(em);
    const p = 6;
    final w48 = _textWidth(text, _font);
    final lw = w48 + p * 2 + 4;
    final lh = _font.lineHeight + p * 2 + 4;
    final layer = img.Image(width: lw, height: lh, numChannels: 4);
    img.fill(layer,
        color: img.ColorRgba8(color.r.toInt(), color.g.toInt(), color.b.toInt(), 0));
    if (shadow) {
      img.drawString(layer, text,
          font: _font, x: p + 2, y: p + 2, color: img.ColorRgba8(0, 0, 0, 165));
    }
    img.drawString(layer, text, font: _font, x: p, y: p, color: color);
    if (bold) {
      img.drawString(layer, text, font: _font, x: p + 2, y: p, color: color);
      img.drawString(layer, text, font: _font, x: p + 1, y: p + 1, color: color);
    }
    final tw = (lw * s).round().clamp(1, dst.width).toInt();
    final th = (lh * s).round().clamp(1, dst.height).toInt();
    final scaled = img.copyResize(layer,
        width: tw,
        height: th,
        interpolation: s < 1 ? img.Interpolation.average : img.Interpolation.cubic);
    img.compositeImage(dst, scaled,
        dstX: math.max(0, x - (p * s).round()),
        dstY: math.max(0, y - (p * s).round()));
  }

  static double _seg(double px, double py, double ax, double ay, double bx, double by) {
    final dx = bx - ax, dy = by - ay;
    final l2 = dx * dx + dy * dy;
    var t = l2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / l2;
    t = t.clamp(0.0, 1.0).toDouble();
    final cx = ax + t * dx, cy = ay + t * dy;
    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }

  static bool _hit(String kind, double x, double y) {
    final r = math.sqrt(x * x + y * y);
    switch (kind) {
      case 'clock':
        return (r < 0.46 && r > 0.34) ||
            _seg(x, y, 0, 0, 0, -0.24) < 0.045 ||
            _seg(x, y, 0, 0, 0.18, 0.06) < 0.045;
      case 'pin':
        final c = math.sqrt(x * x + (y + 0.12) * (y + 0.12));
        final head = c < 0.30;
        final tip = y > -0.10 && y < 0.46 && x.abs() <= 0.27 * (0.46 - y) / 0.56;
        return (head || tip) && c >= 0.11;
      case 'gps':
        return (r < 0.40 && r > 0.28) ||
            r < 0.11 ||
            (x.abs() < 0.035 && y.abs() > 0.34 && y.abs() < 0.5) ||
            (y.abs() < 0.035 && x.abs() > 0.34 && x.abs() < 0.5);
      case 'tag':
        final ax = x.abs(), ay = y.abs();
        final outer = ax < 0.42 && ay < 0.32;
        final inner = ax < 0.32 && ay < 0.22;
        final bars = ay < 0.14 &&
            ((x + 0.15).abs() < 0.03 || x.abs() < 0.03 || (x - 0.15).abs() < 0.03);
        return (outer && !inner) || bars;
      default:
        return r < 0.26;
    }
  }

  static void _icon(img.Image dst, String kind, int cx, int cy, int size, img.Color c) {
    if (size < 4) return;
    const ss = 4;
    final n = size * ss;
    final layer = img.Image(width: n, height: n, numChannels: 4);
    final r = c.r.toInt(), g = c.g.toInt(), b = c.b.toInt();
    img.fill(layer, color: img.ColorRgba8(r, g, b, 0));
    for (var yy = 0; yy < n; yy++) {
      for (var xx = 0; xx < n; xx++) {
        if (_hit(kind, (xx + 0.5) / n - 0.5, (yy + 0.5) / n - 0.5)) {
          layer.setPixelRgba(xx, yy, r, g, b, 255);
        }
      }
    }
    final scaled = img.copyResize(layer,
        width: size, height: size, interpolation: img.Interpolation.average);
    img.compositeImage(dst, scaled,
        dstX: math.max(0, cx - size ~/ 2), dstY: math.max(0, cy - size ~/ 2));
  }

  static void _logoTile(
    img.Image dst,
    img.Image logo,
    int x,
    int y,
    int logoW,
    int logoH,
    int tp,
    int radius,
    img.Color tileColor,
  ) {
    _fillRoundedRectBlended(dst,
        x1: x,
        y1: y,
        x2: x + logoW + tp * 2 - 1,
        y2: y + logoH + tp * 2 - 1,
        radius: radius,
        color: tileColor);
    final resized = img.copyResize(logo,
        width: math.max(1, logoW),
        height: math.max(1, logoH),
        interpolation: img.Interpolation.average);
    img.compositeImage(dst, resized, dstX: x + tp, dstY: y + tp);
  }

  /// Menghapus latar hitam yang menempel pada tepi logo.
  static img.Image _removeConnectedDarkLogoBackground(img.Image input) {
    final source = input.numChannels == 4 ? input : input.convert(numChannels: 4);
    if (source.width < 2 || source.height < 2) return source;
    final total = source.width * source.height;
    final visited = List<bool>.filled(total, false);
    final queue = <int>[];
    bool isDark(int x, int y) {
      final p = source.getPixel(x, y);
      return p.r < 42 && p.g < 42 && p.b < 42 && p.a > 0;
    }

    void add(int x, int y) {
      if (x < 0 || y < 0 || x >= source.width || y >= source.height) return;
      final index = y * source.width + x;
      if (visited[index] || !isDark(x, y)) return;
      visited[index] = true;
      queue.add(index);
    }

    for (var x = 0; x < source.width; x++) {
      add(x, 0);
      add(x, source.height - 1);
    }
    for (var y = 1; y < source.height - 1; y++) {
      add(0, y);
      add(source.width - 1, y);
    }
    var head = 0;
    while (head < queue.length) {
      final index = queue[head++];
      final x = index % source.width;
      final y = index ~/ source.width;
      source.getPixel(x, y).a = 0;
      add(x - 1, y);
      add(x + 1, y);
      add(x, y - 1);
      add(x, y + 1);
    }
    return source;
  }

  /// Pembungkus teks generik (memakai fungsi lebar dari kanvas aktif),
  /// termasuk memecah kata panjang seperti barcode/alamat tanpa spasi.
  static List<String> _wrapBy(String text, int maxWidth, int Function(String) width) {
    if (maxWidth <= 0) return [text];
    final result = <String>[];
    var current = '';
    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final candidate = current.isEmpty ? word : '$current $word';
      if (width(candidate) <= maxWidth) {
        current = candidate;
        continue;
      }
      if (current.isNotEmpty) {
        result.add(current);
        current = '';
      }
      var fragment = '';
      for (final rune in word.runes) {
        final char = String.fromCharCode(rune);
        final next = '$fragment$char';
        if (fragment.isNotEmpty && width(next) > maxWidth) {
          result.add(fragment);
          fragment = char;
        } else {
          fragment = next;
        }
      }
      current = fragment;
    }
    if (current.isNotEmpty) result.add(current);
    return result;
  }

  // ───────────────────────── Parsing metadata ─────────────────────────

  static final _isoRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})');
  static final _localRe = RegExp(r'^(\d{2})[/-](\d{2})[/-](\d{4})[ T](\d{2}):(\d{2})');

  static _Parsed _parse(List<String> lines) {
    final p = _Parsed();
    for (final line in lines) {
      final split = line.indexOf(':');
      final key = (split < 0 ? line : line.substring(0, split)).trim().toUpperCase();
      final value = split < 0 ? line.trim() : line.substring(split + 1).trim();
      if (key == 'WAKTU' || key == 'TIME' || key == 'TIMESTAMP' || key == 'TANGGAL') {
        p.rawTime = value;
      } else if (_isoRe.hasMatch(line) || _localRe.hasMatch(line)) {
        p.rawTime = line.trim();
      } else if (key == 'ALAMAT' || key == 'LOKASI' || key == 'ADDRESS') {
        p.address = value;
      } else if (key == 'GPS' || key == 'KOORDINAT') {
        p.gps = value;
      } else if (key == 'KODE FOTO' || key == 'PHOTO CODE' || key == 'AWB') {
        p.awb = value;
      } else if (key == 'CUSTOM_TEXT' || key == 'TEKS KUSTOM') {
        p.custom = value;
      } else {
        p.extras.add(line);
      }
    }
    return p;
  }

  static _TimeInfo? _parseTime(String? raw) {
    if (raw == null) return null;
    final iso = _isoRe.firstMatch(raw);
    final loc = _localRe.firstMatch(raw);
    if (iso == null && loc == null) return null;
    final m = (iso ?? loc)!;
    final year = int.parse(m.group(iso != null ? 1 : 3)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(iso != null ? 3 : 1)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    const months = [
      'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni',
      'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'
    ];
    const weekdays = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
    final date = DateTime(year, month, day);
    return (
      time: '${m.group(4)}:${m.group(5)}',
      dateText: '$day ${months[month - 1]} $year',
      dayText: weekdays[date.weekday - 1],
    );
  }

  static List<_Row> _rows(_Parsed p, {required bool includeCustom}) {
    final rows = <_Row>[];
    if (p.address != null && p.address!.isNotEmpty) rows.add(_Row('pin', null, p.address!));
    if (p.gps != null && p.gps!.isNotEmpty) rows.add(_Row('gps', null, p.gps!));
    for (final e in p.extras) {
      final i = e.indexOf(':');
      if (i > 0 && i < e.length - 1 && i <= 18) {
        rows.add(_Row('dot', e.substring(0, i).trim().toUpperCase(),
            e.substring(i + 1).trim()));
      } else {
        rows.add(_Row('dot', null, e));
      }
    }
    if (includeCustom && p.custom != null && p.custom!.trim().isNotEmpty) {
      rows.add(_Row('dot', null, p.custom!.trim()));
    }
    if (p.awb != null && p.awb!.isNotEmpty) rows.add(_Row('tag', 'AWB', p.awb!));
    return rows;
  }

  // ───────────────────────── Tema & posisi ─────────────────────────

  static _Theme _themeFor(String style) {
    img.Color c(int r, int g, int b, [int a = 255]) => img.ColorRgba8(r, g, b, a);
    final white = c(255, 255, 255);
    final div = c(255, 255, 255, 70);
    switch (style) {
      case 'compact':
        return _Theme(c(16, 64, 54, 186), c(8, 42, 36, 204), c(92, 230, 174),
            c(112, 240, 190), white, c(170, 222, 205), div, false);
      case 'top':
        return _Theme(c(84, 30, 44, 186), c(52, 18, 28, 204), c(255, 132, 150),
            c(255, 160, 175), white, c(232, 186, 194), div, false);
      case 'modern':
        return _Theme(c(10, 36, 58, 186), c(5, 22, 38, 204), c(0, 210, 225),
            c(105, 235, 255), white, c(170, 215, 225), div, false);
      case 'minimal':
        return _Theme(c(30, 54, 56, 164), c(18, 38, 40, 182), c(112, 220, 192),
            c(150, 240, 220), white, c(190, 225, 218), div, false);
      case 'badge':
        return _Theme(c(252, 214, 112, 228), c(238, 178, 56, 234), c(120, 74, 8),
            c(96, 62, 10), c(44, 34, 18), c(96, 68, 24), c(96, 68, 24, 90), true);
      default:
        return _Theme(c(18, 34, 58, 186), c(10, 20, 38, 204), c(255, 190, 55),
            c(255, 200, 80), white, c(186, 200, 222), div, false);
    }
  }

  static (int, int) _anchor(String position, int w0, int h0, int w, int h,
      int inset, String fallback) {
    const valid = {
      'topLeft', 'topCenter', 'topRight',
      'centerLeft', 'center', 'centerRight',
      'bottomLeft', 'bottomCenter', 'bottomRight',
    };
    final p = valid.contains(position) ? position : fallback;
    final hz = p == 'center' || p.endsWith('Center')
        ? 1
        : p.endsWith('Left')
            ? 0
            : 2;
    final vt = p.startsWith('top') ? 0 : (p.startsWith('center') ? 1 : 2);
    final x = hz == 0 ? inset : (hz == 1 ? (w0 - w) ~/ 2 : w0 - w - inset);
    final y = vt == 0 ? inset : (vt == 1 ? (h0 - h) ~/ 2 : h0 - h - inset);
    return (
      x.clamp(0, math.max(0, w0 - w)).toInt(),
      y.clamp(0, math.max(0, h0 - h)).toInt(),
    );
  }

  // ───────────────────────── Layout kartu (satu mesin, dua renderer) ─────────────────────────

  static bool _drawCard(
    _Cv cv,
    int W,
    int H, {
    required List<String> lines,
    required img.Image? logo,
    required String style,
    required String position,
  }) {
    final parsed = _parse(lines);
    final t = _parseTime(parsed.rawTime);
    if (style == 'timemark' && t != null) {
      for (final k in const [1.0, 0.85, 0.7, 0.58]) {
        if (_tryTimemark(cv, W, H, parsed, t, logo, position, k)) return true;
      }
      return false;
    }
    final st = style == 'timemark' ? 'classic' : style;
    final theme = _themeFor(st);
    for (final k in const [1.0, 0.85, 0.72, 0.6]) {
      if (_tryCard(cv, W, H, parsed, t, logo, theme, st, position, k)) return true;
    }    return false;
  }

  static bool _tryCard(
    _Cv cv,
    int W,
    int H,
    _Parsed parsed,
    _TimeInfo? t,
    img.Image? logo,
    _Theme theme,
    String style,
    String position,
    double k,
  ) {
    final u = _unit(W, H) * k;
    final timeEm = math.max(22.0, 76 * u);
    final dateEm = math.max(11.0, 26 * u);
    final dayEm = math.max(10.0, 21 * u);
    final bodyEm = math.max(11.0, 23 * u);
    final labelEm = bodyEm * 0.82;
    final pad = _ci(15 * u, 6, 44);
    final gap = _ci(9 * u, 4, 26);
    final radius = _ci(14 * u, 5, 36);
    final inset = _ci(14 * u, 6, 40);
    final tp = _ci(5 * u, 3, 12);
    final compact = style == 'compact' || style == 'badge';
    final maxPanelW = math.min((W * (compact ? 0.74 : 0.88)).round(), W - inset * 2);
    if (maxPanelW < 60) return false;

    var timeW = 0, dateW = 0, hh = 0;
    final sepW = math.max(2, _ci(3 * u, 2, 6));
    if (t != null) {
      timeW = cv.tw(t.time, timeEm, bold: true);
      dateW = math.max(cv.tw(t.dateText, dateEm, bold: true), cv.tw(t.dayText, dayEm));
      // Tinggi header mengikuti tinggi angka sebenarnya + napas atas/bawah.
      hh = math.max(cv.digitH(timeEm) + gap, cv.lh(dateEm) + cv.lh(dayEm));
    }

    var tileW = 0, tileH = 0, logoW = 0, logoH = 0;
    var ownRow = false;
    if (logo != null) {
      final base = t != null ? hh : cv.lh(bodyEm) * 2;
      logoH = math.max(6, base - 2 * tp);
      logoW = (logo.width * logoH / logo.height).round();
      final maxLogoW = math.max(16, (math.min(W, H) * 0.13).round());
      if (logoW > maxLogoW) {
        logoW = maxLogoW;
        logoH = math.max(4, (logo.height * logoW / logo.width).round());
      }
      tileW = logoW + 2 * tp;
      tileH = logoH + 2 * tp;
    }
    var headerW = t == null ? 0 : timeW + gap + sepW + gap + dateW;
    if (logo != null) {
      if (t != null && headerW + gap * 2 + tileW + 2 * pad <= maxPanelW) {
        headerW += gap * 2 + tileW;
      } else {
        ownRow = true;
      }
    }

    final bodyLH = cv.lh(bodyEm);
    final iconSize = math.max(8, (bodyLH * 0.78).round());
    final iconCol = iconSize + gap;
    final lineGap = math.max(1, _ci(3 * u, 1, 8));
    final plans = <_RowPlan>[];
    var rowsW = 0;
    for (final row in _rows(parsed, includeCustom: true)) {
      final labelW = row.label == null ? 0 : cv.tw('${row.label}', labelEm, bold: true) + gap;
      final avail = maxPanelW - 2 * pad - iconCol - labelW;
      if (avail < 24) return false;
      final wrapped = cv.wrap(row.value, bodyEm, avail);
      var lw = 0;
      for (final l in wrapped) {
        lw = math.max(lw, cv.tw(l, bodyEm));
      }
      rowsW = math.max(rowsW, iconCol + labelW + lw);
      plans.add(_RowPlan(row, labelW, wrapped));
    }

    int blockH(_RowPlan r) => math.max(
        iconSize, r.lines.length * bodyLH + (r.lines.length - 1) * lineGap);

    final divH = math.max(1, u.round());
    var contentH = 0;
    if (ownRow) contentH += tileH + gap;
    if (t != null) contentH += hh;
    if (t != null && plans.isNotEmpty) contentH += gap * 2 + divH;
    for (var i = 0; i < plans.length; i++) {
      contentH += blockH(plans[i]);
      if (i < plans.length - 1) contentH += gap;
    }
    final total = contentH + pad * 2;
    if (total > H - inset * 2) return false;

    final contentW = math.max(math.max(headerW, rowsW), ownRow ? tileW : 0);
    final panelW = math.min(maxPanelW, contentW + pad * 2);
    final (px, py) = _anchor(position, W, H, panelW, total, inset, 'bottomRight');
    final right = px + panelW - 1;
    final bottom = py + total - 1;
    cv.region(px, py, panelW, total);

    cv.rrect(px, py, right, bottom, radius, theme.top, bottom: theme.bottom);
    final ab = _ci(5 * u, 3, 10);
    void accent({int? cx1, int? cy1, int? cx2, int? cy2}) => cv.rrect(
        px, py, right, bottom, radius, theme.accent,
        cx1: cx1, cy1: cy1, cx2: cx2, cy2: cy2);
    switch (style) {
      case 'compact':
        accent(cx1: right - ab + 1);
      case 'top':
      case 'badge':
        accent(cy2: py + ab - 1);
      case 'minimal':
        cv.rect(px + pad ~/ 2, py + pad, px + pad ~/ 2 + math.max(1, ab ~/ 2),
            bottom - pad, theme.accent);
      case 'modern':
        accent(cx2: px + ab - 1);
        cv.rect(px + pad, bottom - math.max(1, ab ~/ 2), right - pad, bottom - 1,
            img.ColorRgba8(theme.accent.r.toInt(), theme.accent.g.toInt(),
                theme.accent.b.toInt(), 200));
      default:
        accent(cx2: px + ab - 1);
    }

    final shadow = !theme.light;
    final tileColor = img.ColorRgba8(255, 255, 255, 238);
    var y = py + pad;
    if (ownRow) {
      cv.logoTile(logo!, right - pad - tileW + 1, y, logoW, logoH, tp,
          math.max(3, radius ~/ 2), tileColor);
      y += tileH + gap;
    }
    if (t != null) {
      final x0 = px + pad;
      cv.timeText(t.time,
          em: timeEm, x: x0, cy: y + hh ~/ 2,
          color: theme.primary, shadow: shadow);
      final sepX = x0 + timeW + gap;
      final sepH = math.min(hh, (cv.digitH(timeEm) * 1.15).round());
      final sepY = y + (hh - sepH) ~/ 2;
      cv.rect(sepX, sepY, sepX + sepW - 1, sepY + sepH, theme.accent);
      final dateX = sepX + sepW + gap;
      final dateBlock = cv.lh(dateEm) + cv.lh(dayEm);
      final dy = y + (hh - dateBlock) ~/ 2;
      cv.text(t.dateText,
          em: dateEm, x: dateX, y: dy, color: theme.primary, bold: true, shadow: shadow);
      cv.text(t.dayText,
          em: dayEm, x: dateX, y: dy + cv.lh(dateEm), color: theme.muted, shadow: shadow);
      if (logo != null && !ownRow) {
        cv.logoTile(logo, right - pad - tileW + 1, y + (hh - tileH) ~/ 2,
            logoW, logoH, tp, math.max(3, radius ~/ 2), tileColor);
      }
      y += hh;
      if (plans.isNotEmpty) {
        y += gap;
        cv.rect(px + pad, y, right - pad, y + divH - 1, theme.divider);
        y += divH + gap;
      }
    }

    for (final r in plans) {
      final n = r.lines.length;
      final textH = n * bodyLH + (n - 1) * lineGap;
      final bh = blockH(r);
      final textTop = y + (bh - textH) ~/ 2;
      cv.icon(r.row.kind, px + pad + iconSize ~/ 2, textTop + bodyLH ~/ 2,
          iconSize, theme.icon);
      final tx = px + pad + iconCol;
      if (r.row.label != null) {
        cv.text(r.row.label!,
            em: labelEm, x: tx, y: textTop + (bodyLH - cv.lh(labelEm)) ~/ 2,
            color: theme.muted, bold: true, shadow: shadow);
      }
      for (var j = 0; j < n; j++) {
        cv.text(r.lines[j],
            em: bodyEm, x: tx + r.labelW, y: textTop + j * (bodyLH + lineGap),
            color: theme.primary, shadow: shadow);
      }
      y += bh + gap;
    }
    return true;
  }

  /// Gaya "timemark": kapsul jam putih, tanggal tebal, metadata tanpa panel.
  static bool _tryTimemark(
    _Cv cv,
    int W,
    int H,
    _Parsed p,
    _TimeInfo t,
    img.Image? logo,
    String position,
    double k,
  ) {
    final u = _unit(W, H) * k;
    final timeEm = math.max(22.0, 78 * u);
    final dateEm = math.max(13.0, 35 * u);
    final bodyEm = math.max(11.0, 24 * u);
    final pad = _ci(13 * u, 6, 36);
    final gap = _ci(8 * u, 3, 20);
    final inset = _ci(18 * u, 8, 48);
    final tp = _ci(4 * u, 2, 10);
    final timeLH = cv.digitH(timeEm);
    final timeW = cv.tw(t.time, timeEm, bold: true);

    var logoW = 0, logoH = 0;
    if (logo != null) {
      logoH = timeLH;
      logoW = (logo.width * logoH / logo.height).round();
      final mx = math.max(16, (math.min(W, H) * 0.11).round());
      if (logoW > mx) {
        logoW = mx;
        logoH = math.max(4, (logo.height * logoW / logo.width).round());
      }
    }
    final capH = math.max(timeLH, logo == null ? 0 : logoH + 2 * tp) + pad * 2;
    final capW = pad * 2 + timeW + (logo == null ? 0 : gap * 2 + logoW + 2 * tp);
    final maxText = math.min(W - inset * 2, (W * 0.82).round());

    final dateLines = cv.wrap('${t.dayText}, ${t.dateText}', dateEm, maxText - pad, bold: true);
    final meta = <String>[];
    for (final r in _rows(p, includeCustom: false)) {
      if (r.label == 'AWB') continue;
      meta.addAll(cv.wrap(r.label == null ? r.value : '${r.label}: ${r.value}',
          bodyEm, maxText - pad, bold: true));
    }
    final codes = p.awb == null || p.awb!.isEmpty
        ? <String>[]
        : cv.wrap('AWB: ${p.awb}', bodyEm, maxText - pad, bold: true);

    final dateLH = cv.lh(dateEm) + gap;
    final bodyLH = cv.lh(bodyEm) + _ci(7 * u, 3, 18);
    final detailsH = dateLines.length * dateLH +
        meta.length * bodyLH +
        (codes.isEmpty ? 0 : gap + codes.length * bodyLH);
    final total = capH + gap * 2 + detailsH;
    if (total >= H - inset) return false;

    var textW = 0;
    for (final l in dateLines) {
      textW = math.max(textW, cv.tw(l, dateEm, bold: true));
    }
    for (final l in [...meta, ...codes]) {
      textW = math.max(textW, cv.tw(l, bodyEm, bold: true));
    }
    final blockW = math.min(W - inset * 2, math.max(capW, textW + pad));
    final (x, y0) = _anchor(position, W, H, blockW, total, inset, 'bottomLeft');
    final top = position.startsWith('top');

    final custom = p.custom?.trim() ?? '';
    if (custom.isNotEmpty && !top && W >= 320) {
      final cl = cv
          .wrap(custom, bodyEm, math.min(W - inset * 2, (W * 0.72).round()), bold: true)
          .take(3)
          .toList();
      var cw = 0;
      for (final l in cl) {
        cw = math.max(cw, cv.tw(l, bodyEm, bold: true));
      }
      final lineH = cv.lh(bodyEm) + gap ~/ 2;
      cv.region(W - inset - cw, inset, cw, lineH * cl.length);
      var cy = inset;
      for (final l in cl) {
        cv.text(l,
            em: bodyEm, x: math.max(0, W - inset - cv.tw(l, bodyEm, bold: true)), y: cy,
            color: img.ColorRgb8(255, 255, 255), bold: true);
        cy += lineH;
      }
    }

    cv.region(x, y0, blockW, total);

    // Panel gelap semi-transparan khusus tanggal dan metadata. Timemark
    // tetap mempertahankan kapsul jam putih, tetapi alamat/GPS tidak lagi
    // bergantung pada bayangan teks saat latar foto terang atau ramai.
    cv.rrect(
      x,
      y0 + capH + gap,
      x + blockW - 1,
      y0 + total - 1,
      _ci(12 * u, 4, 30),
      img.ColorRgba8(8, 14, 24, 108),
    );

    cv.rrect(x, y0, x + capW - 1, y0 + capH - 1, _ci(12 * u, 4, 30),
        img.ColorRgba8(255, 255, 255, 244));
    cv.timeText(t.time,
        em: timeEm, x: x + pad, cy: y0 + capH ~/ 2,
        color: img.ColorRgb8(18, 55, 105), shadow: false);
    if (logo != null) {
      cv.logoTile(logo, x + capW - pad - logoW - 2 * tp,
          y0 + (capH - logoH - 2 * tp) ~/ 2, logoW, logoH, tp,
          _ci(6 * u, 3, 16), img.ColorRgba8(236, 238, 242, 255));
    }

    var y = y0 + capH + gap * 2;
    final tx = x + pad;
    for (final l in dateLines) {
      cv.text(l, em: dateEm, x: tx, y: y, color: img.ColorRgb8(255, 255, 255), bold: true);
      y += dateLH;
    }
    for (final l in meta) {
      cv.text(l, em: bodyEm, x: tx, y: y, color: img.ColorRgb8(255, 255, 255), bold: true);
      y += bodyLH;
    }
    if (codes.isNotEmpty) {
      y += gap;
      for (final l in codes) {
        cv.text(l, em: bodyEm, x: tx, y: y, color: img.ColorRgb8(205, 205, 205), bold: true);
        y += bodyLH;
      }
    }
    final lw = _ci(3 * u, 2, 8);
    cv.rect(x, y0 + capH + gap, x + lw - 1, math.min(H - 1, y - gap),
        img.ColorRgb8(255, 190, 55));
    return true;
  }

  // ───────────────────────── Isolate ─────────────────────────

  static void _burnIsolate(WatermarkBurnRequest req) {
    try {
      final bytes = File(req.sourcePath).readAsBytesSync();
      var image = img.decodeImage(bytes);
      if (image == null) {
        throw StateError('Gagal decode gambar: ${req.sourcePath}');
      }
      image = img.bakeOrientation(image);

      final hasText = req.lines.isNotEmpty;
      img.Image? logo;
      if (req.logoBytes != null) {
        final decoded = img.decodeImage(req.logoBytes!);
        if (decoded != null) logo = _removeConnectedDarkLogoBackground(decoded);
      }

      if (!hasText && logo == null && req.textOverlayBytes == null) {
        if (req.sourcePath != req.destPath) {
          File(req.sourcePath).copySync(req.destPath);
        }
        return;
      }
      File(req.destPath).parent.createSync(recursive: true);

      var done = false;
      // 1) Overlay TTF dari main isolate (kualitas terbaik).
      if (req.overlays.isNotEmpty) {
        if (image.width == req.expectedWidth && image.height == req.expectedHeight) {
          for (final o in req.overlays) {
            final layer = img.decodePng(o.png);
            if (layer == null) {
              throw StateError('Overlay watermark rusak.');
            }
            img.compositeImage(image, layer, dstX: o.x, dstY: o.y);
          }
          done = true;
        } else {
          debugPrint('Dimensi overlay ${req.expectedWidth}x${req.expectedHeight} '
              '!= foto ${image.width}x${image.height}; memakai renderer cadangan.');
        }
      }

      // 2) Overlay penuh lama (kompatibilitas).
      if (!done && req.textOverlayBytes != null) {
        final overlay = img.decodePng(req.textOverlayBytes!);
        if (overlay == null ||
            overlay.width != image.width ||
            overlay.height != image.height) {
          throw StateError('Overlay watermark tidak cocok dengan ukuran foto.');
        }
        img.compositeImage(image, overlay);
        done = true;
      }

      // 3) Renderer bitmap cadangan.
      if (!done) {
        final style = _styles.contains(req.style) ? req.style : 'classic';
        if (hasText) {
          final ok = _drawCard(_ImgCv(image), image.width, image.height,
              lines: req.lines, logo: logo, style: style, position: req.position);
          if (!ok) {
            throw StateError(
              'Metadata watermark terlalu panjang untuk tinggi foto '
              '${image.width}x${image.height}; kurangi jumlah/panjang baris.',
            );
          }
        } else if (logo != null) {
          final u = _unit(image.width, image.height);
          final tp = _ci(6 * u, 3, 14);
          final lw = _ci(math.min(image.width, image.height) * 0.12, 24, 220);
          final lh = math.max(4, (logo.height * lw / logo.width).round());
          final inset = _ci(14 * u, 6, 40);
          final (x, y) = _anchor(req.position, image.width, image.height,
              lw + 2 * tp, lh + 2 * tp, inset, 'bottomRight');
          _logoTile(image, logo, x, y, lw, lh, tp, _ci(8 * u, 3, 20),
              img.ColorRgba8(255, 255, 255, 238));
        }
      }

      final destLower = req.destPath.toLowerCase();
      final outBytes = destLower.endsWith('.png')
          ? img.encodePng(image)
          : img.encodeJpg(image, quality: _jpegQuality);

      final tempPath =
          '${req.destPath}.wm_tmp_${DateTime.now().microsecondsSinceEpoch}';
      final tempFile = File(tempPath);
      try {
        tempFile.writeAsBytesSync(outBytes, flush: true);
        if (!tempFile.existsSync() || tempFile.lengthSync() == 0) {
          throw Exception('File watermark sementara kosong');
        }
        final destination = File(req.destPath);
        final backupPath =
            '${req.destPath}.wm_backup_${DateTime.now().microsecondsSinceEpoch}';
        final backupFile = File(backupPath);
        var movedExistingDestination = false;
        try {
          if (destination.existsSync()) {
            destination.renameSync(backupPath);
            movedExistingDestination = true;
          }
          tempFile.renameSync(req.destPath);
          if (movedExistingDestination && backupFile.existsSync()) {
            try {
              backupFile.deleteSync();
            } catch (_) {}
          }
        } catch (_) {
          if (movedExistingDestination &&
              backupFile.existsSync() &&
              !destination.existsSync()) {
            backupFile.renameSync(req.destPath);
          }
          rethrow;
        }
      } finally {
        if (tempFile.existsSync()) {
          try {
            tempFile.deleteSync();
          } catch (_) {}
        }
      }
    } catch (e, stack) {
      debugPrint('Error di WatermarkService isolate: $e');
      debugPrint('$stack');
      rethrow;
    }
  }
}