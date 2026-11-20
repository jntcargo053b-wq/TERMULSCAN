import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:termulscan/services/photo_file_recovery.dart';

Uint8List _validJpeg() {
  final image = img.Image(width: 4, height: 4);
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  group('PhotoFileRecovery', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('termulscan-recovery-');
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('restores previous photo if watermark replacement was interrupted',
        () async {
      final backup = File(
        '${directory.path}/photo_100_1.jpg.wm_backup_200',
      );
      final originalPhoto = _validJpeg();
      await backup.writeAsBytes(originalPhoto);

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      final restored = File('${directory.path}/photo_100_1.jpg');
      expect(await restored.exists(), isTrue);
      final restoredBytes = await restored.readAsBytes();
      expect(restoredBytes, originalPhoto);
      expect(img.decodeImage(restoredBytes), isNotNull);
      expect(await backup.exists(), isFalse);
    });

    test('restores backup when destination exists but is empty', () async {
      final destination = File('${directory.path}/photo_empty.jpg');
      final backup = File(
        '${directory.path}/photo_empty.jpg.wm_backup_300',
      );
      await destination.writeAsBytes([]);
      final originalPhoto = _validJpeg();
      await backup.writeAsBytes(originalPhoto);

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      final restoredBytes = await destination.readAsBytes();
      expect(restoredBytes, originalPhoto);
      expect(img.decodeImage(restoredBytes), isNotNull);
      expect(await backup.exists(), isFalse);
    });

    test('restores backup when destination is non-empty but corrupt', () async {
      final destination = File('${directory.path}/photo_corrupt.jpg');
      final backup = File(
        '${directory.path}/photo_corrupt.jpg.wm_backup_400',
      );
      await destination.writeAsBytes([0xFF, 0xD8, 0x00, 0x01]);
      final originalPhoto = _validJpeg();
      await backup.writeAsBytes(originalPhoto);

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      final restoredBytes = await destination.readAsBytes();
      expect(restoredBytes, originalPhoto);
      expect(img.decodeImage(restoredBytes), isNotNull);
      expect(await backup.exists(), isFalse);
    });

    test('deletes backup when the new destination is a valid image', () async {
      final destination = File('${directory.path}/photo_100_1.jpg');
      final backup = File(
        '${directory.path}/photo_100_1.jpg.wm_backup_200',
      );
      final validOutput = _validJpeg();
      await destination.writeAsBytes(validOutput);
      await backup.writeAsBytes([1, 2, 3]);

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      expect(await destination.readAsBytes(), validOutput);
      expect(await backup.exists(), isFalse);
    });

    test('preserves corrupt destination and invalid backup for later recovery',
        () async {
      final destination = File('${directory.path}/photo_both_corrupt.jpg');
      final backup = File(
        '${directory.path}/photo_both_corrupt.jpg.wm_backup_500',
      );
      final destinationBytes = Uint8List.fromList([0xFF, 0xD8, 0x00]);
      final backupBytes = Uint8List.fromList([0x00, 0x01, 0x02]);
      await destination.writeAsBytes(destinationBytes);
      await backup.writeAsBytes(backupBytes);

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      expect(await destination.exists(), isTrue);
      expect(await destination.readAsBytes(), destinationBytes);
      expect(await backup.exists(), isTrue);
      expect(await backup.readAsBytes(), backupBytes);
    });

    test('does not restore an invalid backup when destination is missing',
        () async {
      final backup = File(
        '${directory.path}/photo_missing.jpg.wm_backup_600',
      );
      final backupBytes = Uint8List.fromList([0x01, 0x02, 0x03]);
      await backup.writeAsBytes(backupBytes);

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      expect(await File('${directory.path}/photo_missing.jpg').exists(), isFalse);
      expect(await backup.exists(), isTrue);
      expect(await backup.readAsBytes(), backupBytes);
    });

    test('removes abandoned temporary output but leaves unrelated files',
        () async {
      final temporary = File(
        '${directory.path}/photo_100_1.jpg.wm_tmp_200',
      );
      final unrelated = File('${directory.path}/notes.txt');
      await temporary.writeAsBytes([1]);
      await unrelated.writeAsString('keep');

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      expect(await temporary.exists(), isFalse);
      expect(await unrelated.readAsString(), 'keep');
    });
  });
}
