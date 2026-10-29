import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:termulscan/services/watermark_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Watermark visual regression', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('termulscan-style-visual-');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('each selectable style produces a distinct visual render', () async {
      const styles = ['classic', 'timemark', 'compact', 'top', 'modern', 'minimal', 'badge'];
      final source = File('${tempDir.path}/source.png');
      final original = img.Image(width: 480, height: 640);
      img.fill(original, color: img.ColorRgb8(174, 192, 176));
      img.fillRect(original, x1: 0, y1: 0, x2: 479, y2: 270,
          color: img.ColorRgb8(166, 195, 211));
      img.fillRect(original, x1: 55, y1: 190, x2: 390, y2: 455,
          color: img.ColorRgb8(130, 137, 127));
      img.fillRect(original, x1: 0, y1: 480, x2: 479, y2: 639,
          color: img.ColorRgb8(91, 116, 84));
      await source.writeAsBytes(img.encodePng(original));

      final signatures = <String>{};
      for (final style in styles) {
        final destination = File('${tempDir.path}/watermark-$style.png');
        await WatermarkService.burn(
          sourcePath: source.path,
          destPath: destination.path,
          style: style,
          position: 'bottomRight',
          lines: const [
            'WAKTU: 2026-10-28 08:30:00',
            'ALAMAT: Gudang pengiriman, Malang',
            'GPS: -7.966620, 112.632630',
            'AWB: TERMULSCAN-123456789',
          ],
        );
        final bytes = await destination.readAsBytes();
        final output = img.decodeImage(bytes);
        expect(output, isNotNull, reason: 'Style $style harus dapat dirender');
        expect(output!.width, original.width, reason: 'Lebar foto berubah pada $style');
        expect(output.height, original.height, reason: 'Tinggi foto berubah pada $style');

        final signature = StringBuffer();
        for (var y = 0; y < output.height; y += 4) {
          for (var x = 0; x < output.width; x += 4) {
            final pixel = output.getPixel(x, y);
            signature
              ..write(pixel.r.toInt())
              ..write(',')
              ..write(pixel.g.toInt())
              ..write(',')
              ..write(pixel.b.toInt())
              ..write(';');
          }
        }
        signatures.add(signature.toString());
      }

      expect(signatures.length, styles.length,
          reason: 'Setiap gaya harus memiliki hasil visual berbeda, bukan sekadar nama pilihan berbeda.');
    });
  });
}
