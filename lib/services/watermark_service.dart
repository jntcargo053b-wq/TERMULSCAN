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

  /// Menggambar panel dengan alpha blending eksplisit ke piksel foto.
  /// Ini menghindari alpha diabaikan saat gambar sumber berformat RGB/JPEG.
  static void _fillRectBlended(
    img.Image image, {
    required int x1,
    required int y1,
    required int x2,
    required int y2,
    required img.Color color,
  }) {
    final left = x1.clamp(0, image.width - 1).toInt();
    final top = y1.clamp(0, image.height - 1).toInt();
    final right = x2.clamp(0, image.width - 1).toInt();
    final bottom = y2.clamp(0, image.height - 1).toInt();
    if (right < left || bottom < top) return;

    final alpha = (color.a.toDouble() / 255.0).clamp(0.0, 1.0);
    if (alpha >= 1.0) {
      img.fillRect(
        image,
        x1: left,
        y1: top,
        x2: right,
        y2: bottom,
        color: img.ColorRgb8(
          color.r.toInt(),
          color.g.toInt(),
          color.b.toInt(),
        ),
      );
      return;
    }
    if (alpha <= 0.0) return;

    final inverseAlpha = 1.0 - alpha;
    final red = color.r.toDouble();
    final green = color.g.toDouble();
    final blue = color.b.toDouble();

    for (var y = top; y <= bottom; y++) {
      for (var x = left; x <= right; x++) {
        final pixel = image.getPixel(x, y);
        image.setPixelRgb(
          x,
          y,
          (red * alpha + pixel.r.toDouble() * inverseAlpha).round(),
          (green * alpha + pixel.g.toDouble() * inverseAlpha).round(),
          (blue * alpha + pixel.b.toDouble() * inverseAlpha).round(),
        );
      }
    }
  }

  /// Rounded rectangle dengan alpha blending eksplisit untuk gambar RGB/JPEG.
  static void _fillRoundedRectBlended(
    img.Image image, {
    required int x1,
    required int y1,
    required int x2,
    required int y2,
    required int radius,
    required img.Color color,
  }) {
    final left = x1.clamp(0, image.width - 1).toInt();
    final top = y1.clamp(0, image.height - 1).toInt();
    final right = x2.clamp(0, image.width - 1).toInt();
    final bottom = y2.clamp(0, image.height - 1).toInt();
    if (right < left || bottom < top) return;
    final r = radius.clamp(0, math.min((right - left) ~/ 2, (bottom - top) ~/ 2));
    final alpha = (color.a.toDouble() / 255.0).clamp(0.0, 1.0);
    if (alpha <= 0) return;
    final inverseAlpha = 1.0 - alpha;
    final red = color.r.toDouble();
    final green = color.g.toDouble();
    final blue = color.b.toDouble();
    final radiusSquared = r * r;
    for (var y = top; y <= bottom; y++) {
      for (var x = left; x <= right; x++) {
        if (r > 0) {
          var dx = 0;
          var dy = 0;
          if (x < left + r && y < top + r) {
            dx = left + r - x; dy = top + r - y;
          } else if (x > right - r && y < top + r) {
            dx = x - (right - r); dy = top + r - y;
          } else if (x < left + r && y > bottom - r) {
            dx = left + r - x; dy = y - (bottom - r);
          } else if (x > right - r && y > bottom - r) {
            dx = x - (right - r); dy = y - (bottom - r);
          }
          if (dx * dx + dy * dy > radiusSquared) continue;
        }
        if (alpha >= 1.0) {
          image.setPixelRgb(x, y, red.round(), green.round(), blue.round());
        } else {
          final pixel = image.getPixel(x, y);
          image.setPixelRgb(
            x, y,
            (red * alpha + pixel.r.toDouble() * inverseAlpha).round(),
            (green * alpha + pixel.g.toDouble() * inverseAlpha).round(),
            (blue * alpha + pixel.b.toDouble() * inverseAlpha).round(),
          );
        }
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
      final lineHeight = image.width < 1280
          ? 18
          : image.width < 2560
              ? 30
              : 56;
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
      // Sisakan ruang untuk jarak label/value agar teks tidak melewati panel.
      final labelExtraGap = (4 * scale).round();
      final maxTextWidth = ((image.width * maxTextRatio).round() - (2 * padding) - labelExtraGap)
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

      if (wrappedLines.isNotEmpty) {
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
        final iconGutter = (markerRadiusForLineHeight(lineHeight) * 2) + (8 * scale).round();
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

        // Gunakan warna RGB solid supaya aksen benar-benar terlihat pada
        // hasil JPEG; alpha pada panel lama membuat semua gaya tampak hitam.
        final panelColor = switch (style) {
          // Panel transparan menjaga detail foto tetap terlihat.
          'classic' => img.ColorRgba8(25, 48, 78, 150), // navy
          'compact' => img.ColorRgba8(20, 78, 67, 145), // hijau teal
          'top' => img.ColorRgba8(104, 35, 54, 145), // burgundy
          'modern' => img.ColorRgba8(12, 39, 61, 158), // midnight blue
          'minimal' => img.ColorRgba8(42, 74, 77, 112), // muted teal
          'badge' => img.ColorRgba8(244, 185, 66, 172), // amber
          _ => img.ColorRgba8(25, 48, 78, 150),
        };
        _fillRoundedRectBlended(
          image,
          x1: panelX,
          y1: barY,
          x2: panelRight,
          y2: (barY + barHeight - 1).clamp(0, image.height - 1).toInt(),
          radius: (12 * scale).round().clamp(6, 30).toInt(),
          color: panelColor,
        );

        // Header/aksen memakai warna solid dan bentuk berbeda per template.
        if (style == 'modern') {
          final accentWidth = (5 * scale).round().clamp(3, 8).toInt();
          img.fillRect(
            image,
            x1: panelX,
            y1: barY,
            x2: (panelX + accentWidth - 1).clamp(panelX, panelRight).toInt(),
            y2: (barY + barHeight - 1).clamp(0, image.height - 1).toInt(),
            color: img.ColorRgb8(0, 205, 220),
          );
          final headerHeight = (6 * scale).round().clamp(4, 10).toInt();
          img.fillRect(
            image,
            x1: panelX,
            y1: barY,
            x2: panelRight,
            y2: (barY + headerHeight - 1).clamp(barY, image.height - 1).toInt(),
            color: img.ColorRgb8(0, 145, 170),
          );
        } else if (style == 'minimal') {
          final accentWidth = (3 * scale).round().clamp(2, 5).toInt();
          img.fillRect(
            image,
            x1: panelX,
            y1: barY,
            x2: (panelX + accentWidth - 1).clamp(panelX, panelRight).toInt(),
            y2: (barY + barHeight - 1).clamp(0, image.height - 1).toInt(),
            color: img.ColorRgb8(100, 205, 180),
          );
        } else if (style == 'badge') {
          final accentHeight = (5 * scale).round().clamp(3, 8).toInt();
          img.fillRect(
            image,
            x1: panelX,
            y1: barY,
            x2: panelRight,
            y2: (barY + accentHeight - 1).clamp(barY, image.height - 1).toInt(),
            color: img.ColorRgb8(255, 224, 145),
          );
        } else if (style == 'compact') {
          final accentWidth = (4 * scale).round().clamp(2, 6).toInt();
          img.fillRect(
            image,
            x1: panelRight - accentWidth + 1,
            y1: barY,
            x2: panelRight,
            y2: (barY + barHeight - 1).clamp(0, image.height - 1).toInt(),
            color: img.ColorRgb8(93, 220, 174),
          );
        } else if (style == 'top') {
          final headerHeight = (5 * scale).round().clamp(3, 8).toInt();
          img.fillRect(
            image,
            x1: panelX,
            y1: barY,
            x2: panelRight,
            y2: (barY + headerHeight - 1).clamp(barY, image.height - 1).toInt(),
            color: img.ColorRgb8(218, 92, 111),
          );
        } else {
          final accentHeight = (4 * scale).round().clamp(2, 6).toInt();
          img.fillRect(
            image,
            x1: panelX,
            y1: (barY + barHeight - accentHeight).clamp(barY, image.height - 1).toInt(),
            x2: panelRight,
            y2: (barY + barHeight - 1).clamp(0, image.height - 1).toInt(),
            color: img.ColorRgb8(91, 153, 220),
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
        final labelColor = style == 'badge'
            ? img.ColorRgb8(92, 60, 12)
            : style == 'classic'
                ? img.ColorRgb8(130, 195, 255)
                : style == 'compact'
                    ? img.ColorRgb8(112, 240, 190)
                    : style == 'top'
                        ? img.ColorRgb8(255, 160, 175)
                        : style == 'minimal'
                            ? img.ColorRgb8(150, 240, 220)
                            : img.ColorRgb8(105, 235, 255);
        var rowIndex = 0;
        for (final line in wrappedLines) {
          if (textY + lineHeight > image.height) break;

          // Penanda kecil berwarna memberi setiap baris identitas visual,
          // seperti metadata terstruktur pada aplikasi timestamp/POD.
          final markerColor = style == 'badge'
              ? img.ColorRgb8(92, 60, 12)
              : style == 'classic'
                  ? img.ColorRgb8(130, 195, 255)
                  : style == 'compact'
                      ? img.ColorRgb8(112, 240, 190)
                      : style == 'top'
                          ? img.ColorRgb8(255, 160, 175)
                          : style == 'minimal'
                              ? img.ColorRgb8(150, 240, 220)
                              : img.ColorRgb8(105, 235, 255);
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
              color: panelColor,
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
              color: labelColor, shadowOffset: scale >= 1.5 ? 2 : 1,
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
        }      } else if (resizedLogo != null) {
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
