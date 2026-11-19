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

    test('Timemark custom text changes the header while preserving photo size', () async {
      final source = File('${tempDir.path}/timemark-custom-source.png');
      final original = img.Image(width: 480, height: 640);
      img.fill(original, color: img.ColorRgb8(174, 192, 176));
      await source.writeAsBytes(img.encodePng(original));

      final withoutCustom = File('${tempDir.path}/timemark-without-custom.png');
      final withCustom = File('${tempDir.path}/timemark-with-custom.png');
      const lines = [
        'WAKTU: 2026-10-28 08:30:00',
        'ALAMAT: Gudang pengiriman, Malang',
        'GPS: -7.966620, 112.632630',
        'AWB: TERMULSCAN-123456789',
      ];
      await WatermarkService.burn(
        sourcePath: source.path,
        destPath: withoutCustom.path,
        style: 'timemark',
        lines: lines,
      );
      await WatermarkService.burn(
        sourcePath: source.path,
        destPath: withCustom.path,
        style: 'timemark',
        lines: const [...lines, 'CUSTOM_TEXT: PT Contoh Logistik'],
      );

      final imageWithoutCustom = img.decodeImage(await withoutCustom.readAsBytes());
      final imageWithCustom = img.decodeImage(await withCustom.readAsBytes());
      expect(imageWithoutCustom, isNotNull);
      expect(imageWithCustom, isNotNull);
      expect(imageWithCustom!.width, original.width);
      expect(imageWithCustom.height, original.height);
      expect(
        (await withoutCustom.readAsBytes()).join(','),
        isNot((await withCustom.readAsBytes()).join(',')),
      );
    });

    test('each selectable style produces a distinct visual render', () async {
      const styles = ['classic', 'timemark', 'compact', 'top', 'modern', 'minimal', 'badge', 'pod', 'editorial', 'technical', 'geo', 'split', 'ribbon'];
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
    test('new templates preserve portrait, landscape and square photo proportions', () async {
      const styles = ['pod', 'editorial', 'technical', 'geo', 'split', 'ribbon'];
      const dimensions = [
        (720, 1280),   // portrait 9:16
        (1920, 1080),  // landscape 16:9
        (1080, 1080),  // square 1:1
      ];
      final logo = img.Image(width: 96, height: 48);
      img.fill(logo, color: img.ColorRgba8(24, 120, 210, 255));
      final logoBytes = Uint8List.fromList(img.encodePng(logo));

      for (final (width, height) in dimensions) {
        final source = File('${tempDir.path}/aspect-${width}x$height.png');
        final original = img.Image(width: width, height: height);
        img.fill(original, color: img.ColorRgb8(180, 180, 180));
        await source.writeAsBytes(img.encodePng(original));

        for (final style in styles) {
          final destination = File(
            '${tempDir.path}/aspect-${width}x$height-$style.png',
          );
          await WatermarkService.burn(
            sourcePath: source.path,
            destPath: destination.path,
            style: style,
            position: 'bottomRight',
            logoBytes: logoBytes,
            lines: const [
              'WAKTU: 2026-11-19 19:30:00',
              'AWB: TERMULSCAN-12345678901234567890',
              'GPS: -7.966620, 112.632630, akurasi 3 meter',
              'ALAMAT: Jalan utama kawasan gudang, Kecamatan Lowokwaru, Malang',
              'Operator: Kurir Pengiriman',
            ],
          );

          final output = img.decodeImage(await destination.readAsBytes());
          expect(output, isNotNull, reason: '$style pada $width x $height');
          expect(output!.width, width, reason: 'Lebar foto berubah: $style');
          expect(output.height, height, reason: 'Tinggi foto berubah: $style');

          // Panel harus tetap berada di dalam foto; piksel tepi kanan tidak
          // boleh tertimpa meskipun panel ditempatkan di kanan bawah.
          for (var y = 0; y < height; y += 17) {
            final pixel = output.getPixel(width - 1, y);
            expect(pixel.r, 180, reason: '$style right edge x=$width y=$y');
            expect(pixel.g, 180, reason: '$style right edge x=$width y=$y');
            expect(pixel.b, 180, reason: '$style right edge x=$width y=$y');
          }
        }
      }
    });
  });
}
