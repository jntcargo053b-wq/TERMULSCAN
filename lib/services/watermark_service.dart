import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Payload untuk isolate background.
class WatermarkBurnRequest {
  final String sourcePath;
  final String destPath;
  final List<String> lines;
  final Uint8List? logoBytes;

  const WatermarkBurnRequest({
    required this.sourcePath,
    required this.destPath,
    required this.lines,
    this.logoBytes,
  });
}

/// Membakar watermark yang adaptif, terbaca, dan tidak menumpuk dengan logo.
class WatermarkService {
  static const int _jpegQuality = 90;
  static const int _maxWorkingDimension = 1920;
  static const int _logoMaxSize = 88;

  static Future<void> burn({
    required String sourcePath,
    required String destPath,
    required List<String> lines,
    Uint8List? logoBytes,
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
      ),
    );
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
      final largest = image.width > image.height ? image.width : image.height;
      if (largest > _maxWorkingDimension) {
        final scale = _maxWorkingDimension / largest;
        image = img.copyResize(
          image,
          width: (image.width * scale).round().clamp(1, _maxWorkingDimension),
          height: (image.height * scale).round().clamp(1, _maxWorkingDimension),
        );
      }

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
      final scale = (image.width / 1080).clamp(0.55, 1.65);
      final padding = (16 * scale).round().clamp(8, 28);
      final lineGap = (5 * scale).round().clamp(3, 10);
      final font = image.width < 760 ? img.arial14 : img.arial24;
      final lineHeight = image.width < 760 ? 18 : 30;
      final maxTextWidth = (image.width - (2 * padding)).clamp(10, image.width);

      final wrappedLines = <String>[];
      if (hasText) {
        for (final line in req.lines) {
          wrappedLines.addAll(_wrapText(line, font, maxTextWidth));
        }
      }

      final logo = decodedLogo;
      img.Image? resizedLogo;
      if (logo != null) {
        final maxLogo = (image.width * 0.12).round().clamp(36, _logoMaxSize);
        final ratio = maxLogo / (logo.width > logo.height ? logo.width : logo.height);
        resizedLogo = img.copyResize(
          logo,
          width: (logo.width * ratio).round().clamp(1, maxLogo),
          height: (logo.height * ratio).round().clamp(1, maxLogo),
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
        final barY = (image.height - barHeight).clamp(0, image.height - 1);

        img.fillRect(
          image,
          x1: 0,
          y1: barY,
          x2: image.width - 1,
          y2: image.height - 1,
          color: img.ColorRgba8(0, 0, 0, 178),
        );

        if (resizedLogo != null) {
          img.compositeImage(
            image,
            resizedLogo,
            dstX: (image.width - resizedLogo.width - padding).clamp(0, image.width - 1),
            dstY: (barY + padding).clamp(0, image.height - 1),
          );
        }

        var textY = barY + padding + logoHeaderHeight + headerGap;
        for (final line in wrappedLines) {
          if (textY + lineHeight > image.height) break;
          img.drawString(
            image,
            line,
            font: font,
            x: padding,
            y: textY,
            color: img.ColorRgb8(255, 255, 255),
          );
          textY += lineHeight + lineGap;
        }
      } else if (resizedLogo != null) {
        // Jika pengguna hanya memakai logo, pertahankan penempatan sudut
        // kanan bawah dengan batas aman pada foto kecil.
        final padding = (12 * scale).round().clamp(5, 20);
        img.compositeImage(
          image,
          resizedLogo,
          dstX: (image.width - resizedLogo.width - padding).clamp(0, image.width - 1),
          dstY: (image.height - resizedLogo.height - padding).clamp(0, image.height - 1),
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
        if (destination.existsSync()) destination.deleteSync();
        tempFile.renameSync(req.destPath);
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
