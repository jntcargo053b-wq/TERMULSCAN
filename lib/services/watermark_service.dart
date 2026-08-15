import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Payload yang dikirim ke isolate background lewat compute(). Semua field
/// harus berupa data biasa (String/List/Uint8List) — tidak boleh menyimpan
/// referensi BuildContext, widget, atau singleton, karena isolate baru
/// tidak berbagi memory dengan isolate utama.
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

/// Membakar (compositing permanen, bukan overlay UI) teks watermark +
/// logo ke atas file foto. Dijalankan di isolate terpisah lewat compute()
/// supaya decode/encode gambar resolusi besar tidak nge-freeze UI thread
/// saat proses simpan foto.
class WatermarkService {
  /// [sourcePath] = foto asal (belum ada watermark).
  /// [destPath] = tujuan penulisan hasil (boleh sama dengan sourcePath
  /// untuk overwrite in-place, atau path lain).
  /// [lines] = baris-baris teks watermark, urut dari atas ke bawah.
  /// [logoBytes] = isi file logo perusahaan (opsional).
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

  /// Top-level-able static function — wajib supaya bisa dikirim ke isolate
  /// lain lewat compute().
  static void _burnIsolate(WatermarkBurnRequest req) {
    final bytes = File(req.sourcePath).readAsBytesSync();
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw Exception('Gagal decode gambar untuk watermark: ${req.sourcePath}');
    }

    if (req.lines.isNotEmpty) {
      final font = img.arial24;
      const padding = 16;
      const lineGap = 8;
      // Tinggi baris tetap (bukan baca dari font.lineHeight) supaya tidak
      // bergantung pada detail internal BitmapFont yang bisa berubah antar
      // versi package — arial24 kira-kira 24-26px tinggi karakternya.
      const lineHeight = 30;
      final barHeight = padding * 2 + req.lines.length * lineHeight;
      final barY = (image.height - barHeight).clamp(0, image.height);

      // Bar gradasi hitam semi-transparan di bawah foto supaya teks putih
      // tetap terbaca di atas foto apa pun warna/kontrasnya.
      img.fillRect(
        image,
        x1: 0,
        y1: barY,
        x2: image.width,
        y2: image.height,
        color: img.ColorRgba8(0, 0, 0, 150),
      );

      var textY = barY + padding;
      for (final line in req.lines) {
        img.drawString(
          image,
          line,
          font: font,
          x: padding,
          y: textY,
          color: img.ColorRgb8(255, 255, 255),
        );
        textY += lineHeight;
      }
    }

    // Logo perusahaan di pojok kanan bawah, kalau operator sudah pasang.
    if (req.logoBytes != null) {
      final logo = img.decodeImage(req.logoBytes!);
      if (logo != null) {
        const logoSize = 64;
        const logoPadding = 16;
        final resizedLogo =
            img.copyResize(logo, width: logoSize, height: logoSize);
        img.compositeImage(
          image,
          resizedLogo,
          dstX: image.width - logoSize - logoPadding,
          dstY: image.height - logoSize - logoPadding,
        );
      }
    }

    final destLower = req.destPath.toLowerCase();
    final outBytes = destLower.endsWith('.png')
        ? img.encodePng(image)
        : img.encodeJpg(image, quality: 88);
    File(req.destPath).writeAsBytesSync(outBytes);
  }
}
