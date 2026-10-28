import 'dart:io';
import 'dart:typed_data';
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

    test('classic layout keeps a safe margin at the right photo edge', () async {
      final source = File('${tempDir.path}/classic-edge-source.png');
      final destination = '${tempDir.path}/classic-edge-watermarked.png';
      final original = img.Image(width: 320, height: 240);
      img.fill(original, color: img.ColorRgb8(180, 180, 180));
      await source.writeAsBytes(img.encodePng(original));

      final logo = img.Image(width: 40, height: 20);
      img.fill(logo, color: img.ColorRgba8(20, 120, 220, 255));
      await WatermarkService.burn(
        sourcePath: source.path,
        destPath: destination,
        lines: const [
          '28/10/2026 08:30:00',
          'Alamat: Jalan pengiriman dengan keterangan yang cukup panjang',
          'GPS: -7.123456, 112.123456',
          'AWB: EDGE-REGRESSION-TEST',
        ],
        logoBytes: Uint8List.fromList(img.encodePng(logo)),
      );

      final output = img.decodeImage(await File(destination).readAsBytes());
      expect(output, isNotNull);
      expect(output!.width, 320);
      expect(output.height, 240);
      // PNG bersifat lossless: tepi paling kanan harus tetap berupa foto asli,
      // bukan panel/logo yang meluber sampai keluar batas layout.
      for (var y = 0; y < output.height; y++) {
        final pixel = output.getPixel(output.width - 1, y);
        expect(pixel.r, 180, reason: 'right edge red channel at y=$y');
        expect(pixel.g, 180, reason: 'right edge green channel at y=$y');
        expect(pixel.b, 180, reason: 'right edge blue channel at y=$y');
      }
    });


    test('classic layout keeps long GPS and AWB values inside a narrow photo', () async {
      final source = File('${tempDir.path}/classic-long-source.png');
      final destination = '${tempDir.path}/classic-long-watermarked.png';
      final original = img.Image(width: 320, height: 320);
      img.fill(original, color: img.ColorRgb8(180, 180, 180));
      await source.writeAsBytes(img.encodePng(original));

      final logo = img.Image(width: 80, height: 28);
      img.fill(logo, color: img.ColorRgba8(20, 120, 220, 255));
      await WatermarkService.burn(
        sourcePath: source.path,
        destPath: destination,
        lines: [
          '28/10/2026 08:30:00',
          'Alamat: Jalan tanpa batas dengan detail pengiriman yang panjang sekali',
          'GPS: -7.123456789, 112.123456789, akurasi 3 meter',
          'AWB: ${'LONG-CODE-1234567890-' * 5}',
        ],
        logoBytes: Uint8List.fromList(img.encodePng(logo)),
      );

      final output = img.decodeImage(await File(destination).readAsBytes());
      expect(output, isNotNull);
      expect(output!.width, 320);
      expect(output.height, 320);
      for (var y = 0; y < output.height; y++) {
        final pixel = output.getPixel(output.width - 1, y);
        expect(pixel.r, 180, reason: 'right edge red channel at y=$y');
        expect(pixel.g, 180, reason: 'right edge green channel at y=$y');
        expect(pixel.b, 180, reason: 'right edge blue channel at y=$y');
      }
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

    test('preserves dimensions of a high-resolution POD photo', () async {
      final source = File('${tempDir.path}/high-resolution.jpg');
      final destination = '${tempDir.path}/high-resolution-watermarked.jpg';
      final original = img.Image(width: 2560, height: 1440);
      img.fill(original, color: img.ColorRgb8(175, 185, 195));
      await source.writeAsBytes(img.encodeJpg(original, quality: 92));

      await WatermarkService.burn(
        sourcePath: source.path,
        destPath: destination,
        lines: const [
          'Tanggal: 27/10/2026 08:30:00',
          'AWB: 12345678901234567890',
          'Lokasi: Gudang pengiriman',
        ],
        style: 'modern',
      );

      final outputFile = File(destination);
      expect(await outputFile.exists(), isTrue);
      final output = img.decodeImage(await outputFile.readAsBytes());
      expect(output, isNotNull);
      expect(output!.width, 2560);
      expect(output.height, 1440);
    });

    test('replaces an existing output safely when burning a new watermark', () async {
      final source = File('${tempDir.path}/replacement-source.jpg');
      final destination = File('${tempDir.path}/existing-output.jpg');
      final original = img.Image(width: 640, height: 480);
      img.fill(original, color: img.ColorRgb8(170, 180, 190));
      await source.writeAsBytes(img.encodeJpg(original, quality: 95));

      // Simulasikan file hasil lama yang sudah ada di lokasi tujuan.
      await destination.writeAsBytes(
        img.encodeJpg(img.Image(width: 64, height: 64), quality: 90),
      );

      await WatermarkService.burn(
        sourcePath: source.path,
        destPath: destination.path,
        lines: const ['AWB: REPLACEMENT-TEST', 'Status: Terkirim'],
        style: 'compact',
      );

      final outputBytes = await destination.readAsBytes();
      expect(outputBytes, isNotEmpty);
      final output = img.decodeImage(outputBytes);
      expect(output, isNotNull);
      expect(output!.width, 640);
      expect(output.height, 480);

      final leftovers = tempDir
          .listSync()
          .where((entity) => entity.path.contains('.wm_tmp_') ||
              entity.path.contains('.wm_backup_'));
      expect(leftovers, isEmpty);
    });

    test('all six watermark styles render without changing dimensions', () async {
      final source = File('${tempDir.path}/all-styles-source.jpg');
      final original = img.Image(width: 1280, height: 720);
      img.fill(original, color: img.ColorRgb8(160, 175, 185));
      await source.writeAsBytes(img.encodeJpg(original, quality: 92));

      const styles = [
        'classic',
        'compact',
        'top',
        'modern',
        'minimal',
        'badge',
      ];

      // Selain memastikan file valid, setiap gaya harus benar-benar
      // menghasilkan tampilan berbeda, bukan hanya menyimpan nama gaya.
      final renderedSignatures = <String>{};
      for (final style in styles) {
        final destination = '${tempDir.path}/style-$style.jpg';
        await WatermarkService.burn(
          sourcePath: source.path,
          destPath: destination,
          lines: const [
            'Tanggal: 27/10/2026 08:30:00',
            'AWB: TEST-123456789',
            'Lokasi: Gudang pengiriman',
          ],
          style: style,
        );

        final file = File(destination);
        expect(await file.exists(), isTrue, reason: 'style=$style');
        final outputBytes = await file.readAsBytes();
        final output = img.decodeImage(outputBytes);
        expect(output, isNotNull, reason: 'style=$style');
        expect(output!.width, 1280, reason: 'style=$style');
        expect(output.height, 720, reason: 'style=$style');
        expect(
          renderedSignatures.add(outputBytes.join(',')),
          isTrue,
          reason: 'Gaya $style harus berbeda secara visual dari gaya lain',
        );
      }
    });

    test('does not silently truncate metadata that cannot fit the photo', () async {
      final source = File('${tempDir.path}/oversized-metadata-source.jpg');
      final destination = File('${tempDir.path}/existing-safe-output.jpg');
      final original = img.Image(width: 160, height: 120);
      img.fill(original, color: img.ColorRgb8(180, 180, 180));
      await source.writeAsBytes(img.encodeJpg(original, quality: 95));

      // Existing output must remain intact if the metadata cannot fit.
      final previousOutput = img.Image(width: 32, height: 32);
      img.fill(previousOutput, color: img.ColorRgb8(30, 90, 150));
      await destination.writeAsBytes(img.encodeJpg(previousOutput, quality: 95));

      final tooManyLines = List<String>.generate(
        30,
        (index) => 'Metadata baris $index: informasi pengiriman',
      );

      await expectLater(
        WatermarkService.burn(
          sourcePath: source.path,
          destPath: destination.path,
          lines: tooManyLines,
          style: 'classic',
        ),
        throwsA(isA<StateError>()),
      );

      final preserved = img.decodeImage(await destination.readAsBytes());
      expect(preserved, isNotNull);
      expect(preserved!.width, 32);
      expect(preserved.height, 32);
      expect(
        tempDir.listSync().where((entity) =>
            entity.path.contains('.wm_tmp_') ||
            entity.path.contains('.wm_backup_')),
        isEmpty,
      );
    });
  });
}
