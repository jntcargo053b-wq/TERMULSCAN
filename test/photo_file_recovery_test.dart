import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:termulscan/services/photo_file_recovery.dart';

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

    test('deletes backup when the new destination already exists', () async {
      final destination = File('${directory.path}/photo_100_1.jpg');
      final backup = File(
        '${directory.path}/photo_100_1.jpg.wm_backup_200',
      );
      await destination.writeAsBytes([4, 5, 6]);
      await backup.writeAsBytes([1, 2, 3]);

      await PhotoFileRecovery.recoverWatermarkArtifacts(directory);

      expect(await destination.readAsBytes(), [4, 5, 6]);
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
