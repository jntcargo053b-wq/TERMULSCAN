import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:termulscan/services/watermark_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WatermarkService', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('termulscan-watermark-');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('burns long text and logo without changing photo dimensions', () async {
      final source = File('${tempDir.path}/source.jpg');
      final destination = '${tempDir.path}/watermarked.jpg';
      final original = img.Image(width: 480, height: 640);
      img.fill(original, color: img.ColorRgb8(180, 180, 180));
      await source.writeAsBytes(img.encodeJpg(original, quality: 95));

      final logo = img.Image(width: 80, height: 40);
      img.fill(logo, color: img.ColorRgba8(20, 120, 220, 255));
      final logoBytes = Uint8List.fromList(img.encodePng(logo));

      await WatermarkService.burn(
        sourcePath: source.path,
        destPath: destination,
        lines: [
          '28/10/2026 08:30:00',
          'Alamat gudang dan jalan utama yang cukup panjang untuk dibungkus',
          'AWB: ${'1234567890' * 8}',
          'Operator: TermulScan',
        ],
        logoBytes: logoBytes,
      );

      final outputFile = File(destination);
      expect(await outputFile.exists(), isTrue);
      expect(await outputFile.length(), greaterThan(0));

      final output = img.decodeImage(await outputFile.readAsBytes());
      expect(output, isNotNull);
      expect(output!.width, 480);
      expect(output.height, 640);
    });

    test('supports logo-only watermark on a small image', () async {
      final source = File('${tempDir.path}/small.png');
      final destination = '${tempDir.path}/small-watermarked.png';
      final original = img.Image(width: 160, height: 120);
      img.fill(original, color: img.ColorRgb8(220, 220, 220));
      await source.writeAsBytes(img.encodePng(original));

      final logo = img.Image(width: 24, height: 16);
      img.fill(logo, color: img.ColorRgba8(220, 40, 40, 255));

      await WatermarkService.burn(
        sourcePath: source.path,
        destPath: destination,
        lines: const [],
        logoBytes: Uint8List.fromList(img.encodePng(logo)),
      );

      final output = img.decodeImage(await File(destination).readAsBytes());
      expect(output, isNotNull);
      expect(output!.width, 160);
      expect(output.height, 120);
    });
  });
}
