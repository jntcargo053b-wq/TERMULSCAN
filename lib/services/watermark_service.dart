import 'dart:io';
import 'dart:typed_data';
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

/// Service untuk membakar watermark teks dan logo secara permanen.
class WatermarkService {
  // Konfigurasi yang bisa disesuaikan
  static const int _padding = 16;
  static const int _lineGap = 8;
  static const int _lineHeight = 30; // Approx height for arial24
  static const int _logoMaxSize = 64;
  static const int _logoPadding = 16;
  static const int _barAlpha = 150;
  static const int _jpegQuality = 88;

  static Future<void> burn({
    required String sourcePath,
    required String destPath,
    required List<String> lines,
    Uint8List? logoBytes,
  }) async {
    final nonEmptyLines = lines.where((l) => l.trim().isNotEmpty).toList();
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

  /// Hitung lebar render sebuah string dalam [font], dalam satuan piksel.
  /// `BitmapFont` di package `image` TIDAK punya method `getStringBounds()`
  /// (itu bukan bagian dari API-nya — cuma ada `characterXAdvance`).
  /// Ini pendekatan yang sama dipakai `drawString()` secara internal untuk
  /// menghitung `stringWidth` sebelum centering teks.
  static int _textWidth(String text, img.BitmapFont font) {
    var width = 0;
    for (final rune in text.runes) {
      width += font.characterXAdvance(String.fromCharCode(rune));
    }
    return width;
  }

  /// Helper untuk memecah teks panjang agar tidak keluar dari batas gambar.
  static List<String> _wrapText(String text, img.BitmapFont font, int maxWidth) {
    if (maxWidth <= 0) return [text];
    final words = text.split(' ');
    final lines = <String>[];
    String currentLine = '';

    for (final word in words) {
      final testLine = currentLine.isEmpty ? word : '$currentLine $word';
      if (_textWidth(testLine, font) <= maxWidth) {
        currentLine = testLine;
      } else {
        if (currentLine.isNotEmpty) lines.add(currentLine);
        currentLine = word;
      }
    }
    if (currentLine.isNotEmpty) lines.add(currentLine);
    return lines;
  }

  static void _burnIsolate(WatermarkBurnRequest req) {
    try {
      // 1. Baca & decode
      final bytes = File(req.sourcePath).readAsBytesSync();
      var image = img.decodeImage(bytes);
      if (image == null) {
        throw Exception('Gagal decode gambar: ${req.sourcePath}');
      }

      // 2. Terapkan orientasi EXIF secara fisik — kamera Android biasanya
      // menyimpan foto potret dengan buffer piksel landscape + tag EXIF
      // rotate, bukan piksel yang sungguh diputar. Tanpa ini, posisi bar &
      // teks watermark dihitung relatif ke buffer mentah, lalu begitu file
      // ditampilkan/dibagikan (yang menghormati EXIF), watermark pindah ke
      // SAMPING gambar alih-alih di bawah.
      image = img.bakeOrientation(image);

      final hasText = req.lines.isNotEmpty;
      final hasLogo = req.logoBytes != null;

      // 3. Jika tidak ada watermark sama sekali, cukup copy file (hindari degradasi kualitas)
      if (!hasText && !hasLogo) {
        // Hindari copy ke dirinya sendiri
        if (req.sourcePath != req.destPath) {
          File(req.sourcePath).copySync(req.destPath);
        }
        return;
      }

      // Pastikan direktori tujuan ada
      File(req.destPath).parent.createSync(recursive: true);

      final font = img.arial24;
      // Minimal lebar teks 10 px agar tidak bermasalah saat padding besar
      final maxTextWidth = (image.width - (2 * _padding)).clamp(10, image.width);

      // 4. Proses teks: wrap agar tidak overflow
      List<String> wrappedLines = [];
      if (hasText) {
        for (final line in req.lines) {
          wrappedLines.addAll(_wrapText(line, font, maxTextWidth));
        }
      }

      // 5. Gambar bar hitam transparan & teks di bagian bawah
      if (wrappedLines.isNotEmpty) {
        final totalTextHeight = wrappedLines.length * _lineHeight +
            (wrappedLines.length - 1) * _lineGap;
        final barHeight = (2 * _padding) + totalTextHeight;
        // Pastikan bar tidak melewati batas atas (jika gambar sangat pendek)
        final barY = (image.height - barHeight).clamp(0, image.height);

        // Bar hitam semi-transparan
        img.fillRect(
          image,
          x1: 0,
          y1: barY,
          x2: image.width,
          y2: image.height,
          color: img.ColorRgba8(0, 0, 0, _barAlpha),
        );

        // Gambar teks baris per baris
        var textY = barY + _padding;
        for (final line in wrappedLines) {
          // Hentikan jika teks sudah keluar dari batas bawah
          if (textY + _lineHeight > image.height) break;

          img.drawString(
            image,
            line,
            font: font,
            x: _padding,
            y: textY,
            color: img.ColorRgb8(255, 255, 255),
          );
          textY += _lineHeight + _lineGap;
        }
      }

      // 6. Proses logo (dengan menjaga rasio aspek)
      if (hasLogo) {
        final logo = img.decodeImage(req.logoBytes!);
        if (logo != null) {
          // Hitung ukuran baru dengan rasio aspek tetap
          int newWidth, newHeight;
          if (logo.width > logo.height) {
            newWidth = _logoMaxSize;
            newHeight = (logo.height * _logoMaxSize / logo.width).round();
          } else {
            newHeight = _logoMaxSize;
            newWidth = (logo.width * _logoMaxSize / logo.height).round();
          }
          // Pastikan minimal 1px
          newWidth = newWidth.clamp(1, _logoMaxSize);
          newHeight = newHeight.clamp(1, _logoMaxSize);

          final resizedLogo = img.copyResize(logo, width: newWidth, height: newHeight);

          final dstX = image.width - newWidth - _logoPadding;
          final dstY = image.height - newHeight - _logoPadding;

          img.compositeImage(
            image,
            resizedLogo,
            dstX: dstX.clamp(0, image.width),
            dstY: dstY.clamp(0, image.height),
          );
        } else {
          debugPrint('Peringatan: Gagal mendecode logo bytes.');
        }
      }

      // 7. Encode & simpan
      final destLower = req.destPath.toLowerCase();
      final outBytes = destLower.endsWith('.png')
          ? img.encodePng(image)
          : img.encodeJpg(image, quality: _jpegQuality);

      File(req.destPath).writeAsBytesSync(outBytes);
    } catch (e, stack) {
      // Tangkap error agar ada jejak yang jelas, lalu rethrow supaya
      // pemanggil (compute() future) benar-benar tahu proses gagal —
      // caller di UI (photo_scan_screen) menampilkan ini sebagai snackbar,
      // bukan gagal diam-diam.
      debugPrint('Error di WatermarkService isolate: $e');
      debugPrint('$stack');
      rethrow;
    }
  }
}
