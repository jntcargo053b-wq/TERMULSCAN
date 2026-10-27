import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Payload untuk isolate background.
class WatermarkBurnRequest {
  final String sourcePath;
  final String destPath;
  final List<String> lines;
  final Uint8List? logoBytes;
  final String style;

  const WatermarkBurnRequest({
    required this.sourcePath,
    required this.destPath,
    required this.lines,
    this.logoBytes,
    this.style = 'classic',
  });
}

/// Membakar watermark yang adaptif, terbaca, dan tidak menumpuk dengan logo.
class WatermarkService {
  static const int _jpegQuality = 90;

  static Future<void> burn({
    required String sourcePath,
    required String destPath,
    required List<String> lines,
    Uint8List? logoBytes,
    String style = 'classic',
  }) async {
    final nonEmptyLines = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    await compute(
      _burnIsolate,
      WatermarkBurnRequest(
        sourcePath: sourcePath,
        destPath: destPath,
        lines: nonEmptyLines,
        logoBytes: logoBytes,
        style: style,
      ),
    );
  }

  /// Rounded rectangle anti-aliased dengan alpha blending dan gradasi opsional.
  /// clip* membatasi area gambar tanpa mengubah geometri sudut panel; ini juga
  /// dipakai untuk aksen agar ujungnya selalu mengikuti lengkungan panel.
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
      final red = color.r.toDouble() +
          (end.r.toDouble() - color.r.toDouble()) * t;
      final green = color.g.toDouble() +
          (end.g.toDouble() - color.g.toDouble()) * t;
      final blue = color.b.toDouble() +
          (end.b.toDouble() - color.b.toDouble()) * t;
      final baseAlpha = (color.a.toDouble() +
              (end.a.toDouble() - color.a.toDouble()) * t) /
          255.0;

      for (var x = left; x <= right; x++) {
        if (clipX1 != null && x < clipX1) continue;
        if (clipX2 != null && x > clipX2) continue;

        var coverage = 1.0;
        if (r > 0) {
          final cx =
              x < left + r ? left + r : (x > right - r ? right - r : x);
          final cy =
              y < top + r ? top + r : (y > bottom - r ? bottom - r : y);
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

  static void _drawStringCrisp(
    img.Image image,
    String text, {
    required img.BitmapFont font,
    required int x,
    required int y,
    required img.Color color,
    int shadowOffset = 1,
  }) {
    img.drawString(
      image, text, font: font, x: x + shadowOffset, y: y + shadowOffset,
      color: img.ColorRgb8(8, 12, 18),
    );
    img.drawString(image, text, font: font, x: x, y: y, color: color);
  }

  static int markerRadiusForLineHeight(int lineHeight) =>
      (lineHeight * 0.30).round().clamp(5, 16).toInt();

  static void _drawScaledBitmapText(
    img.Image image,
    String text, {
    required img.BitmapFont font,
    required int x,
    required int y,
    required img.Color color,
    required double factor,
    int shadowOffset = 1,
  }) {
    if (text.isEmpty) return;
    final sourceWidth = _textWidth(text, font).clamp(1, image.width).toInt();
    final sourceHeight = font.lineHeight.clamp(1, image.height).toInt();
    final layer = img.Image(width: sourceWidth + 2, height: sourceHeight + 2);
    img.fill(layer, color: img.ColorRgba8(0, 0, 0, 0));
    img.drawString(layer, text, font: font, x: 1, y: 1,
      color: color,);
    final targetWidth = ((sourceWidth + 2) * factor).round().clamp(1, image.width).toInt();
    final targetHeight = ((sourceHeight + 2) * factor).round().clamp(1, image.height).toInt();
    final scaled = img.copyResize(layer, width: targetWidth, height: targetHeight,
      interpolation: img.Interpolation.linear);
    img.compositeImage(image, scaled, dstX: x, dstY: y);
  }

  /// Layout timestamp profesional dengan waktu dominan dan metadata bertingkat.
  static bool _drawClassicTimestampLayout(
    img.Image image, {
    required List<String> lines,
    required img.Image? logo,
    required double scale,
  }) {
    String? rawTime;
    String? address;
    String? gps;
    String? photoCode;
    final extras = <String>[];
    for (final line in lines) {
      final split = line.indexOf(':');
      final key = (split < 0 ? line : line.substring(0, split)).trim().toUpperCase();
      final value = split < 0 ? line.trim() : line.substring(split + 1).trim();
      if (key == 'WAKTU' || key == 'TIME' || key == 'TIMESTAMP' || key == 'TANGGAL') {
        rawTime = value;
      } else if (RegExp(r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}').hasMatch(line) ||
          RegExp(r'^\d{2}[/-]\d{2}[/-]\d{4}[ T]\d{2}:\d{2}').hasMatch(line)) {
        rawTime = line.trim();
      } else if (key == 'ALAMAT' || key == 'LOKASI' || key == 'ADDRESS') {
        address = value;
      } else if (key == 'GPS' || key == 'KOORDINAT') {
        gps = value;
      } else if (key == 'KODE FOTO' || key == 'PHOTO CODE' || key == 'AWB') {
        photoCode = value;
      } else {
        extras.add(line);
      }
    }
    if (rawTime == null) return false;
    final isoMatch = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})').firstMatch(rawTime);
    final localMatch = RegExp(r'^(\d{2})[/-](\d{2})[/-](\d{4})[ T](\d{2}):(\d{2})').firstMatch(rawTime);
    if (isoMatch == null && localMatch == null) return false;
    final year = int.parse((isoMatch ?? localMatch)!.group(isoMatch != null ? 1 : 3)!);
    final month = int.parse((isoMatch ?? localMatch)!.group(isoMatch != null ? 2 : 2)!);
    final day = int.parse((isoMatch ?? localMatch)!.group(isoMatch != null ? 3 : 1)!);
    final hour = (isoMatch ?? localMatch)!.group(4)!;
    final minute = (isoMatch ?? localMatch)!.group(5)!;
    const months = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni',
      'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'];
    const weekdays = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
    final date = DateTime(year, month, day);
    final dateText = '$day ${months[month - 1]} $year';
    final dayText = weekdays[date.weekday - 1];
    // Font bitmap image package tersedia dalam ukuran tetap; pilih ukuran lebih
    // besar agar hasil kamera mendekati referensi, terutama pada foto 1080p.
    // Pada foto kecil, gunakan font dasar lebih kecil dan faktor skala yang
    // adaptif. Membesarkan font bitmap 48 px secara paksa pada foto 320 px
    // membuat waktu, tanggal, dan logo saling bertabrakan serta tampak kasar.
    final small = image.width < 720 ? img.arial14 : img.arial24;
    final large = image.width < 720 ? img.arial24 : img.arial48;
    final timeScale = (image.width / 1152 * 1.85).clamp(0.72, 2.35).toDouble();
    final pad = (16 * scale).round().clamp(8, 48).toInt();
    final gap = (8 * scale).round().clamp(4, 20).toInt();
    final lineH = small.lineHeight + gap;
    final timeH = (large.lineHeight * timeScale).round() + gap;
    // Ukuran panel mengikuti konten, bukan pita dengan lebar tetap.
    // Sisakan ruang untuk logo di header agar tidak bertumpuk dengan tanggal.
    final panelRatio = 0.86;
    final logoMax = (image.width * 0.075).round().clamp(12, 96).toInt();
    final logoWidth = logo == null
        ? 0
        : logoMax;
    final headerWidthEstimate = (_textWidth('$hour:$minute', large) * timeScale).round() +
        gap + (3 * scale).round().clamp(2, 5).toInt() + gap +
        math.max(_textWidth(dateText, small), _textWidth(dayText, small)) +
        (logoWidth > 0 ? gap + logoWidth : 0);
    final maxWidth = (image.width * panelRatio).round() - pad * 2;
    final content = <String>[];
    // Semua metadata dibungkus pada batas panel, bukan hanya alamat. Koordinat,
    // nomor AWB, atau nama operator yang panjang tidak boleh terpotong di tepi.
    if (address != null && address.isNotEmpty) {
      content.addAll(_wrapText(address, small, maxWidth));
    }
    if (gps != null && gps.isNotEmpty) {
      content.addAll(_wrapText('GPS: $gps', small, maxWidth));
    }
    for (final extra in extras) {
      content.addAll(_wrapText(extra, small, maxWidth));
    }
    final codeText = photoCode == null || photoCode.isEmpty
        ? <String>[]
        : _wrapText('Kode Foto: $photoCode', small, maxWidth);
    var contentWidth = headerWidthEstimate;
    for (final line in content) {
      contentWidth = math.max(contentWidth, _textWidth(line, small));
    }
    for (final line in codeText) {
      contentWidth = math.max(contentWidth, _textWidth(line, small));
    }
    final left = (16 * scale).round().clamp(4, 48).toInt();
    final rightMargin = left;
    // Panel harus menyisakan margin di kedua sisi foto. Batas sebelumnya hanya
    // menghitung persentase lebar foto, sehingga pada foto kecil/teks panjang
    // sisi kanan panel dapat terpotong setelah posisi kiri ditambahkan.
    final panelMaxWidth = math.min(
      (image.width * panelRatio).round(),
      image.width - left - rightMargin,
    ).clamp(1, image.width).toInt();
    final panelWidth = (contentWidth + pad * 2).clamp(1, panelMaxWidth).toInt();
    final totalHeight = pad + timeH + lineH + gap + content.length * lineH +
        (codeText.isEmpty ? 0 : codeText.length * lineH + gap) + pad;
    final top = (image.height - totalHeight - (12 * scale).round()).clamp(0, image.height - 1).toInt();
    final right = (left + panelWidth - 1).clamp(left, image.width - 1).toInt();
    final bottom = (top + totalHeight).clamp(top, image.height - 1).toInt();
    _fillRoundedRectBlended(image, x1: left, y1: top, x2: right, y2: bottom,
      radius: (12 * scale).round().clamp(3, 32).toInt(),
      color: img.ColorRgba8(22, 27, 28, 145),
      colorBottom: img.ColorRgba8(18, 22, 23, 178));

    var y = top + pad;
    final timeText = '$hour:$minute';
    _drawScaledBitmapText(image, timeText, font: large, x: left + pad, y: y,
      color: img.ColorRgb8(255, 255, 255), factor: timeScale,
      shadowOffset: math.max(1, (scale * 1.2).round()));
    final timeWidth = (_textWidth(timeText, large) * timeScale).round();
    final separatorX = (left + pad + timeWidth + gap).clamp(left + pad, right - pad).toInt();
    img.fillRect(image, x1: separatorX, y1: y, x2: separatorX + (3 * scale).round().clamp(2, 5).toInt(),
      y2: y + timeH + lineH - gap, color: img.ColorRgb8(255, 190, 55));
    final dateX = separatorX + (10 * scale).round();
    _drawStringCrisp(image, dateText, font: small, x: dateX, y: y,
      color: img.ColorRgb8(255, 255, 255), shadowOffset: math.max(1, (scale * 1.2).round()));
    _drawStringCrisp(image, dayText, font: small, x: dateX, y: y + lineH,
      color: img.ColorRgb8(255, 255, 255), shadowOffset: math.max(1, (scale * 1.2).round()));
    if (logo != null) {
      final resized = img.copyResize(logo, width: logoMax,
        height: (logo.height * logoMax / logo.width).round().clamp(1, image.height).toInt());
      img.compositeImage(image, resized,
        dstX: (right - pad - resized.width).clamp(left + pad, right).toInt(),
        dstY: (top + pad).clamp(0, image.height - 1).toInt());
    }
    y += timeH + lineH + gap;
    for (final line in content) {
      if (y + small.lineHeight >= bottom - pad) break;
      _drawStringCrisp(image, line, font: small, x: left + pad, y: y,
        color: img.ColorRgb8(255, 255, 255), shadowOffset: math.max(1, (scale * 1.2).round()));
      y += lineH;
    }
    if (codeText.isNotEmpty && y + small.lineHeight < bottom) {
      final dividerY = (y - gap ~/ 2).clamp(top, bottom).toInt();
      img.fillRect(image, x1: left + pad, y1: dividerY, x2: right - pad, y2: dividerY,
        color: img.ColorRgba8(255, 255, 255, 85));
      y += gap;
      for (final line in codeText) {
        if (y + small.lineHeight >= bottom) break;
        _drawStringCrisp(image, line, font: small, x: left + pad, y: y,
          color: img.ColorRgb8(220, 225, 225), shadowOffset: math.max(1, (scale * 1.2).round()));
        y += lineH;
      }
    }
    return true;
  }

  static int _textWidth(String text, img.BitmapFont font) {
    var width = 0;
    for (final rune in text.runes) {
      width += font.characterXAdvance(String.fromCharCode(rune));
    }
    return width;
  }

  /// Membungkus teks panjang, termasuk barcode/alamat tanpa spasi.
  static List<String> _wrapText(
    String text,
    img.BitmapFont font,
    int maxWidth,
  ) {
    if (maxWidth <= 0) return [text];
    final result = <String>[];
    var current = '';

    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final candidate = current.isEmpty ? word : '$current $word';
      if (_textWidth(candidate, font) <= maxWidth) {
        current = candidate;
        continue;
      }

      if (current.isNotEmpty) {
        result.add(current);
        current = '';
      }

      // Pecah kata yang lebih panjang daripada lebar foto agar tidak
      // terpotong di tepi gambar.
      var fragment = '';
      for (final rune in word.runes) {
        final char = String.fromCharCode(rune);
        final next = '$fragment$char';
        if (fragment.isNotEmpty && _textWidth(next, font) > maxWidth) {
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

  static void _burnIsolate(WatermarkBurnRequest req) {
    try {
      final bytes = File(req.sourcePath).readAsBytesSync();
      var image = img.decodeImage(bytes);
      if (image == null) {
        throw Exception('Gagal decode gambar: ${req.sourcePath}');
      }

      // Bakar orientasi EXIF sebelum menghitung posisi watermark.
      image = img.bakeOrientation(image);
      // Pertahankan dimensi foto asli. Mengecilkan gambar di sini dapat
      // mengurangi detail bukti POD; ukuran watermark disesuaikan di bawah.
      final hasText = req.lines.isNotEmpty;
      final decodedLogo =
          req.logoBytes == null ? null : img.decodeImage(req.logoBytes!);

      final useClassicLayout = req.style == 'classic' && hasText &&
          _drawClassicTimestampLayout(
            image,
            lines: req.lines,
            logo: decodedLogo,
            scale: (image.width / 1080).clamp(0.55, 3.75).toDouble(),
          );

      if (!hasText && decodedLogo == null) {
        if (req.sourcePath != req.destPath) {
          File(req.sourcePath).copySync(req.destPath);
        }
        return;
      }

      File(req.destPath).parent.createSync(recursive: true);

      // Gunakan padding proporsional terhadap ukuran foto; jangan biarkan
      // padding tetap terlalu besar pada gambar kecil.
      final scale = (image.width / 1080).clamp(0.55, 3.75);
      final padding = (9 * scale).round().clamp(5, 18).toInt();
      final lineGap = (2 * scale).round().clamp(1, 6).toInt();
      // Naikkan ukuran font pada foto resolusi tinggi agar teks watermark
      // tetap proporsional setelah dimensi asli dipertahankan.
      final font = image.width < 1280
          ? img.arial14
          : image.width < 2560
              ? img.arial24
              : img.arial48;
      final lineHeight = font.lineHeight + (2 * scale).round();
      final style = const {
        'classic', 'compact', 'top', 'modern', 'minimal', 'badge',
      }.contains(req.style) ? req.style : 'classic';
      // Batasi lebar teks agar panel tidak membentang menutupi foto.
      final maxTextRatio = style == 'compact' || style == 'badge'
          ? 0.46
          : style == 'minimal'
              ? 0.50
              : style == 'classic'
                  ? 0.56
                  : style == 'top'
                      ? 0.60
                      : 0.62;
      // Alokasikan ruang untuk kolom ikon dan pemisah label/value sebelum wrapping.
      final labelExtraGap = (4 * scale).round();
      final iconGutter = (markerRadiusForLineHeight(lineHeight) * 2) +
          (8 * scale).round();
      final maxTextWidth = ((image.width * maxTextRatio).round() -
              (2 * padding) - iconGutter - labelExtraGap)
          .clamp(10, image.width).toInt();

      final wrappedLines = <String>[];
      if (hasText) {
        for (final line in req.lines) {
          wrappedLines.addAll(_wrapText(line, font, maxTextWidth));
        }
      }

      final logo = decodedLogo;
      img.Image? resizedLogo;
      if (logo != null) {
        final maxLogo = (image.width * 0.08).round().clamp(14, 160).toInt();
        final ratio = maxLogo / (logo.width > logo.height ? logo.width : logo.height);
        resizedLogo = img.copyResize(
          logo,
          width: (logo.width * ratio).round().clamp(1, maxLogo).toInt(),
          height: (logo.height * ratio).round().clamp(1, maxLogo).toInt(),
        );
      }

      if (wrappedLines.isNotEmpty && !useClassicLayout) {
        final textHeight = wrappedLines.length * lineHeight +
            (wrappedLines.length - 1) * lineGap;
        // Logo mendapat baris khusus di bagian atas panel. Teks dimulai
        // setelahnya, sehingga alamat/AWB tidak pernah tertutup logo.
        final logoHeaderHeight = resizedLogo == null
            ? 0
            : resizedLogo.height + (8 * scale).round();
        final headerGap = resizedLogo == null ? 0 : (6 * scale).round();
        final barHeight =
            (2 * padding) + logoHeaderHeight + headerGap + textHeight;
        // Jangan diam-diam membuang metadata yang tidak muat pada foto.
        // Validasi sebelum panel digambar atau file tujuan diganti, sehingga
        // foto hasil sebelumnya tetap aman jika metadata terlalu panjang.
        if (barHeight > image.height) {
          throw StateError(
            'Metadata watermark terlalu panjang untuk tinggi foto '
            '${image.width}x${image.height}; kurangi jumlah/panjang baris.',
          );
        }
        final insetStyles = const {'modern', 'minimal', 'badge'};
        final inset = insetStyles.contains(style)
            ? (10 * scale).round().clamp(5, 18).toInt()
            : 0;
        final barY = style == 'top'
            ? 0
            : (image.height - barHeight - inset)
                .clamp(0, image.height - 1).toInt();
        var contentWidth = 0;
        for (final line in wrappedLines) {
          final width = _textWidth(line, font);
          if (width > contentWidth) contentWidth = width;
        }
        if (resizedLogo != null && resizedLogo.width > contentWidth) {
          contentWidth = resizedLogo.width;
        }
        final textInset = style == 'modern' || style == 'minimal'
            ? (4 * scale).round()
            : 0;
        final maxPanelWidth = (image.width * maxTextRatio)
            .round()
            .clamp(1, image.width).toInt();
        final panelWidth = (contentWidth + 2 * padding + textInset + iconGutter)
            .clamp(1, maxPanelWidth).toInt();
        final panelRightInset = (style == 'modern' ||
                style == 'minimal' ||
                style == 'badge' ||
                style == 'compact')
            ? inset
            : 0;
        var panelX = style == 'compact' || style == 'badge'
            ? image.width - panelWidth - panelRightInset
            : (style == 'modern' || style == 'minimal')
                ? inset
                : 0;
        // Classic/modern/minimal/header kini memakai panel selebar konten,
        // bukan satu pita penuh yang menutupi objek foto.
        var panelRight = (panelX + panelWidth - 1)
            .clamp(panelX, image.width - 1 - panelRightInset).toInt();
        if (panelRight < panelX) {
          panelX = 0;
          panelRight = (panelWidth - 1).clamp(0, image.width - 1).toInt();
        }

        // Panel memakai gradasi halus; semua aksen dipotong menggunakan
        // geometri panel yang sama agar sudut tidak keluar dari lengkungan.
        final panelRadius = (12 * scale).round().clamp(6, 30).toInt();
        final panelBottomY =
            (barY + barHeight - 1).clamp(0, image.height - 1).toInt();
        final (panelTop, panelBottom) = switch (style) {
          'classic' => (
              img.ColorRgba8(32, 58, 92, 160),
              img.ColorRgba8(18, 36, 62, 175),
            ),
          'compact' => (
              img.ColorRgba8(26, 90, 78, 155),
              img.ColorRgba8(14, 62, 54, 170),
            ),
          'top' => (
              img.ColorRgba8(118, 42, 62, 155),
              img.ColorRgba8(84, 26, 42, 170),
            ),
          'modern' => (
              img.ColorRgba8(18, 48, 74, 168),
              img.ColorRgba8(8, 28, 46, 182),
            ),
          'minimal' => (
              img.ColorRgba8(46, 80, 84, 150),
              img.ColorRgba8(30, 58, 62, 165),
            ),
          'badge' => (
              img.ColorRgba8(250, 196, 84, 182),
              img.ColorRgba8(236, 170, 52, 192),
            ),
          _ => (
              img.ColorRgba8(32, 58, 92, 160),
              img.ColorRgba8(18, 36, 62, 175),
            ),
        };

        _fillRoundedRectBlended(
          image,
          x1: panelX,
          y1: barY,
          x2: panelRight,
          y2: panelBottomY,
          radius: panelRadius,
          color: panelTop,
          colorBottom: panelBottom,
        );

        void accent({
          required img.Color color,
          int? clipX1,
          int? clipY1,
          int? clipX2,
          int? clipY2,
        }) {
          _fillRoundedRectBlended(
            image!,
            x1: panelX,
            y1: barY,
            x2: panelRight,
            y2: panelBottomY,
            radius: panelRadius,
            color: color,
            clipX1: clipX1,
            clipY1: clipY1,
            clipX2: clipX2,
            clipY2: clipY2,
          );
        }

        switch (style) {
          case 'modern':
            final w = (5 * scale).round().clamp(3, 8).toInt();
            final h = (6 * scale).round().clamp(4, 10).toInt();
            accent(
              color: img.ColorRgb8(0, 145, 170),
              clipY2: barY + h - 1,
            );
            accent(
              color: img.ColorRgb8(0, 205, 220),
              clipX2: panelX + w - 1,
            );
          case 'minimal':
            final w = (3 * scale).round().clamp(2, 5).toInt();
            accent(
              color: img.ColorRgb8(100, 205, 180),
              clipX2: panelX + w - 1,
            );
          case 'badge':
            final h = (5 * scale).round().clamp(3, 8).toInt();
            accent(
              color: img.ColorRgb8(255, 224, 145),
              clipY2: barY + h - 1,
            );
          case 'compact':
            final w = (4 * scale).round().clamp(2, 6).toInt();
            accent(
              color: img.ColorRgb8(93, 220, 174),
              clipX1: panelRight - w + 1,
            );
          case 'top':
            final h = (5 * scale).round().clamp(3, 8).toInt();
            accent(
              color: img.ColorRgb8(218, 92, 111),
              clipY2: barY + h - 1,
            );
          default:
            final h = (4 * scale).round().clamp(2, 6).toInt();
            accent(
              color: img.ColorRgb8(91, 153, 220),
              clipY1: panelBottomY - h + 1,
            );
        }

        if (resizedLogo != null) {
          img.compositeImage(
            image,
            resizedLogo,
            dstX: (style == 'minimal' || style == 'modern' || style == 'top'
                ? panelX + padding
                : panelRight - resizedLogo.width - padding)
                .clamp(panelX, (panelRight - resizedLogo.width).clamp(panelX, image.width - 1).toInt()).toInt(),
            dstY: (barY + padding).clamp(0, image.height - 1).toInt(),
          );
        }

        final textX = panelX + padding +
            (markerRadiusForLineHeight(lineHeight) * 2) + (8 * scale).round();
        var textY = barY + padding + logoHeaderHeight + headerGap;
        final textColor = style == 'badge'
            ? img.ColorRgb8(42, 35, 22)
            : img.ColorRgb8(255, 255, 255);
        final accentLight = switch (style) {
          'badge' => img.ColorRgb8(92, 60, 12),
          'classic' => img.ColorRgb8(130, 195, 255),
          'compact' => img.ColorRgb8(112, 240, 190),
          'top' => img.ColorRgb8(255, 160, 175),
          'minimal' => img.ColorRgb8(150, 240, 220),
          _ => img.ColorRgb8(105, 235, 255),
        };
        final labelColor = accentLight;
        var rowIndex = 0;
        for (final line in wrappedLines) {
          if (textY + lineHeight > image.height) break;

          // Penanda kecil berwarna memberi setiap baris identitas visual,
          // seperti metadata terstruktur pada aplikasi timestamp/POD.
          final markerColor = accentLight;
          // Kolom ikon diperbesar dan dipisahkan secara konsisten dari teks.
          final markerRadius = markerRadiusForLineHeight(lineHeight);
          final markerX = (panelX + padding + markerRadius)
              .clamp(panelX, panelRight).toInt();
          final markerY = (textY + lineHeight / 2).round()
              .clamp(barY, image.height - 1).toInt();
          final markerLabel = line.toUpperCase();
          if (markerLabel.startsWith('WAKTU') ||
              markerLabel.startsWith('TIME') ||
              markerLabel.startsWith('TANGGAL')) {
            // Ikon jam: lingkaran dan dua jarum.
            img.drawCircle(
              image,
              x: markerX,
              y: markerY,
              radius: markerRadius,
              color: markerColor,
            );
            img.drawLine(
              image,
              x1: markerX,
              y1: markerY,
              x2: markerX,
              y2: markerY - (markerRadius * 0.55).round(),
              color: markerColor,
            );
            img.drawLine(
              image,
              x1: markerX,
              y1: markerY,
              x2: markerX + (markerRadius * 0.55).round(),
              y2: markerY,
              color: markerColor,
            );
          } else if (markerLabel.startsWith('GPS') ||
              markerLabel.startsWith('KOORDINAT')) {
            // Ikon target untuk koordinat GPS.
            img.drawCircle(
              image,
              x: markerX,
              y: markerY,
              radius: markerRadius,
              color: markerColor,
            );
            img.fillCircle(
              image,
              x: markerX,
              y: markerY,
              radius: (markerRadius / 2).round().clamp(1, markerRadius).toInt(),
              color: markerColor,
            );
          } else if (markerLabel.startsWith('ALAMAT') ||
              markerLabel.startsWith('LOKASI')) {
            // Ikon pin lokasi yang tetap sederhana di ukuran foto kecil.
            img.fillCircle(
              image,
              x: markerX,
              y: markerY - 1,
              radius: markerRadius,
              color: markerColor,
            );
            img.fillCircle(
              image,
              x: markerX,
              y: markerY - 1,
              radius: (markerRadius / 2).round().clamp(1, markerRadius).toInt(),
              color: panelBottom,
            );
            img.drawLine(
              image,
              x1: markerX - markerRadius + 1,
              y1: markerY + markerRadius - 1,
              x2: markerX,
              y2: markerY + markerRadius + 1,
              color: markerColor,
            );
            img.drawLine(
              image,
              x1: markerX,
              y1: markerY + markerRadius + 1,
              x2: markerX + markerRadius - 1,
              y2: markerY + markerRadius - 1,
              color: markerColor,
            );
          } else {
            // Penanda netral untuk AWB, operator, dan metadata lainnya.
            img.fillCircle(
              image,
              x: markerX,
              y: markerY,
              radius: markerRadius,
              color: markerColor,
            );
          }

          // Garis pemisah dan label berwarna membuat informasi lebih mudah
          // dipindai, tidak lagi berupa satu blok teks putih yang seragam.
          if (rowIndex > 0 && (style == 'modern' || style == 'classic' || style == 'badge')) {
            final dividerY = (textY - (lineGap ~/ 2)).clamp(barY, image.height - 1).toInt();
            img.fillRect(
              image,
              x1: textX,
              y1: dividerY,
              x2: (panelRight - padding).clamp(textX, image.width - 1).toInt(),
              y2: dividerY,
              color: style == 'badge'
                  ? img.ColorRgb8(190, 143, 48)
                  : img.ColorRgb8(90, 115, 135),
            );
          }

          final separator = line.indexOf(':');
          if (separator > 0 && separator < line.length - 1) {
            final label = line.substring(0, separator + 1);
            final value = line.substring(separator + 1).trimLeft();
            final labelWidth = _textWidth(label, font);
            _drawStringCrisp(
              image, label, font: font, x: textX, y: textY,
              color: labelColor, shadowOffset: math.max(1, (scale * 1.2).round()),
            );
            final valueX = textX + labelWidth + (4 * scale).round();
            if (valueX < image.width - padding) {
              _drawStringCrisp(
                image, value, font: font, x: valueX, y: textY,
                color: textColor, shadowOffset: scale >= 1.5 ? 2 : 1,
              );
            }
          } else {
            _drawStringCrisp(
              image, line, font: font, x: textX, y: textY,
              color: textColor, shadowOffset: scale >= 1.5 ? 2 : 1,
            );
          }
          textY += lineHeight + lineGap;
          rowIndex++;
        }      } else if (resizedLogo != null && !useClassicLayout) {
        // Jika pengguna hanya memakai logo, pertahankan penempatan sudut
        // kanan bawah dengan batas aman pada foto kecil.
        final padding = (12 * scale).round().clamp(5, 20).toInt();
        img.compositeImage(
          image,
          resizedLogo,
          dstX: (image.width - resizedLogo.width - padding).clamp(0, image.width - 1).toInt(),
          dstY: (image.height - resizedLogo.height - padding).clamp(0, image.height - 1).toInt(),
        );
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
          // Simpan hasil lama sementara agar kegagalan rename tidak
          // menghilangkan foto yang sebelumnya sudah tersimpan.
          if (destination.existsSync()) {
            destination.renameSync(backupPath);
            movedExistingDestination = true;
          }
          tempFile.renameSync(req.destPath);
          if (movedExistingDestination && backupFile.existsSync()) {
            // Penghapusan cadangan bukan bagian dari keberhasilan tulis;
            // kegagalannya tidak boleh melaporkan foto baru sebagai gagal.
            try {
              backupFile.deleteSync();
            } catch (_) {}
          }
        } catch (_) {
          // Jika penggantian gagal, pulihkan hasil lama bila memungkinkan.
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
