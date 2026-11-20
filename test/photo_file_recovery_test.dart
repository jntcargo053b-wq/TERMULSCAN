import 'dart:io';

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
      await backup.writeAsBytes([1, 2, 3]);

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      final restored = File('${directory.path}/photo_100_1.jpg');
      expect(await restored.exists(), isTrue);
      expect(await restored.readAsBytes(), [1, 2, 3]);
      expect(await backup.exists(), isFalse);
    });

    test('restores backup when destination exists but is empty', () async {
      final destination = File('${directory.path}/photo_empty.jpg');
      final backup = File(
        '${directory.path}/photo_empty.jpg.wm_backup_300',
      );
      await destination.writeAsBytes([]);
      await backup.writeAsBytes([7, 8, 9]);

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      expect(await destination.readAsBytes(), [7, 8, 9]);
      expect(await backup.exists(), isFalse);
    });

    test('restores backup when destination is non-empty but corrupt', () async {
      final destination = File('${directory.path}/photo_corrupt.jpg');
      final backup = File(
        '${directory.path}/photo_corrupt.jpg.wm_backup_400',
      );
      await destination.writeAsBytes([0xFF, 0xD8, 0x00, 0x01]);
      await backup.writeAsBytes([1, 2, 3]);

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      expect(await destination.readAsBytes(), [1, 2, 3]);
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
