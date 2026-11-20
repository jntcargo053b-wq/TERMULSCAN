import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termulscan/models/scan_entry.dart';
import 'package:termulscan/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
  });

  group('StorageService photo recovery metadata', () {
    test('corrupt metadata is preserved and skips destructive startup cleanup', () async {
      const corruptHistory = '{broken-history';
      const corruptTasks = '{broken-photo-tasks';
      SharedPreferences.setMockInitialValues({
        'scan_entries': corruptHistory,
        'pending_photo_tasks_v1': corruptTasks,
      });

      await storage.init();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('scan_entries'), corruptHistory);
      expect(prefs.getString('pending_photo_tasks_v1'), corruptTasks);
      expect(storage.entries, isEmpty);
      expect(storage.pendingPhotoTaskIds, isEmpty);

      // A later normal write must first preserve the exact damaged source.
      await storage.enqueuePhotoTask('new-photo-after-corruption');
      expect(
        prefs.getString('scan_entries_corrupt_backup_v1'),
        corruptHistory,
      );
      expect(
        prefs.getString('pending_photo_tasks_corrupt_backup_v1'),
        corruptTasks,
      );
      expect(
        () => json.decode(prefs.getString('pending_photo_tasks_v1')!),
        returnsNormally,
      );

      // The first recovery snapshot is immutable across subsequent writes.
      await storage.enqueuePhotoTask('another-new-photo');
      expect(
        prefs.getString('scan_entries_corrupt_backup_v1'),
        corruptHistory,
      );
      expect(
        prefs.getString('pending_photo_tasks_corrupt_backup_v1'),
        corruptTasks,
      );
    });

    test('rawPathFor inserts suffix before the extension', () {
      expect(
        storage.rawPathFor('/app/photos/photo_123_1.jpg'),
        '/app/photos/photo_123_1_raw.jpg',
      );
      expect(
        storage.rawPathFor('/app/photos/photo_without_extension'),
        '/app/photos/photo_without_extension_raw',
      );
    });

    test('photo entry and recovery task are committed in one snapshot', () async {
      const entryId = 'storage-test-atomic-photo';
      final entry = ScanEntry(
        id: entryId,
        type: ScanType.photo,
        value: '/photos/photo_123_1.jpg',
        imagePath: '/photos/photo_123_1.jpg',
        timestamp: DateTime(2026, 11, 21, 10),
        latitude: -7.98,
        longitude: 112.63,
      );

      await storage.addPhotoEntryWithTask(
        entry,
        latitude: -7.98,
        longitude: 112.63,
      );

      expect((await storage.getEntry(entryId))?.displayImagePath,
          '/photos/photo_123_1.jpg');
      expect(storage.getPhotoTask(entryId)?['latitude'], -7.98);

      final prefs = await SharedPreferences.getInstance();
      final savedEntries =
          (json.decode(prefs.getString('scan_entries')!) as List<dynamic>)
              .cast<Map<String, dynamic>>();
      final savedTasks =
          (json.decode(prefs.getString('pending_photo_tasks_v1')!)
                  as List<dynamic>)
              .cast<Map<String, dynamic>>();
      expect(savedEntries.any((item) => item['id'] == entryId), isTrue);
      expect(savedTasks.any((item) => item['entryId'] == entryId), isTrue);
    });

    test('enqueue persists capture coordinates and initial retry metadata', () async {
      const entryId = 'storage-test-enqueue';
      await storage.enqueuePhotoTask(
        entryId,
        latitude: -7.98,
        longitude: 112.63,
      );

      final task = storage.getPhotoTask(entryId)!;
      expect(task['entryId'], entryId);
      expect(task['latitude'], -7.98);
      expect(task['longitude'], 112.63);
      expect(task['attempts'], 0);
      expect(task['addressAttempts'], 0);

      final savedTask = await _readPersistedTask(entryId);
      expect(savedTask['latitude'], -7.98);
      expect(savedTask['longitude'], 112.63);
      expect(savedTask['attempts'], 0);
      expect(savedTask['addressAttempts'], 0);
    });

    test('enqueue without coordinates preserves previously captured coordinates', () async {
      const entryId = 'storage-test-preserve-coordinates';
      await storage.enqueuePhotoTask(
        entryId,
        latitude: -7.98,
        longitude: 112.63,
      );

      await storage.enqueuePhotoTask(entryId);
      final task = storage.getPhotoTask(entryId)!;
      expect(task['latitude'], -7.98);
      expect(task['longitude'], 112.63);

      final savedTask = await _readPersistedTask(entryId);
      expect(savedTask['latitude'], -7.98);
      expect(savedTask['longitude'], 112.63);
    });

    test('watermark retry count and timestamp are persisted together', () async {
      const entryId = 'storage-test-watermark-retry';
      await storage.enqueuePhotoTask(entryId);
      await storage.markPhotoTaskAttempt(entryId);

      final task = storage.getPhotoTask(entryId)!;
      expect(task['attempts'], 1);
      expect(DateTime.tryParse(task['lastAttemptAt'] as String), isNotNull);

      final savedTask = await _readPersistedTask(entryId);
      expect(savedTask['attempts'], 1);
      expect(DateTime.tryParse(savedTask['lastAttemptAt'] as String), isNotNull);
    });

    test('address retry metadata is separate from watermark retries', () async {
      const entryId = 'storage-test-address-retry';
      await storage.enqueuePhotoTask(entryId);
      await storage.markPhotoTaskAttempt(entryId);
      await storage.markPhotoTaskAddressAttempt(entryId);

      final task = storage.getPhotoTask(entryId)!;
      expect(task['attempts'], 1);
      expect(task['addressAttempts'], 1);
      expect(DateTime.tryParse(task['lastAttemptAt'] as String), isNotNull);
      expect(DateTime.tryParse(task['lastAddressAttemptAt'] as String), isNotNull);

      final savedTask = await _readPersistedTask(entryId);
      expect(savedTask['attempts'], 1);
      expect(savedTask['addressAttempts'], 1);
      expect(DateTime.tryParse(savedTask['lastAttemptAt'] as String), isNotNull);
      expect(DateTime.tryParse(savedTask['lastAddressAttemptAt'] as String), isNotNull);
    });

    test('retry exhaustion pauses task without discarding recovery metadata', () async {
      const entryId = 'storage-test-retry-exhausted';
      await storage.enqueuePhotoTask(
        entryId,
        latitude: -7.98,
        longitude: 112.63,
      );

      await storage.markPhotoTaskRetryExhausted(entryId);

      final task = storage.getPhotoTask(entryId)!;
      expect(task['retryExhausted'], isTrue);
      expect(task['latitude'], -7.98);
      expect(task['longitude'], 112.63);
      expect(storage.pendingPhotoTaskIds, contains(entryId));

      final savedTask = await _readPersistedTask(entryId);
      expect(savedTask['retryExhausted'], isTrue);
      expect(savedTask['latitude'], -7.98);
      expect(savedTask['longitude'], 112.63);
    });

    test('watermark and address completion flags are persisted', () async {
      const entryId = 'storage-test-completion-flags';
      await storage.enqueuePhotoTask(entryId);
      await storage.markPhotoTaskWatermarkCompleted(entryId);
      await storage.markPhotoTaskAddressResolved(entryId);

      final task = storage.getPhotoTask(entryId)!;
      expect(task['watermarkCompleted'], isTrue);
      expect(task['addressResolved'], isTrue);

      final savedTask = await _readPersistedTask(entryId);
      expect(savedTask['watermarkCompleted'], isTrue);
      expect(savedTask['addressResolved'], isTrue);
    });
  });
}

Future<Map<String, dynamic>> _readPersistedTask(String entryId) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('pending_photo_tasks_v1');
  expect(raw, isNotNull);
  final persisted = (json.decode(raw!) as List<dynamic>)
      .cast<Map<String, dynamic>>();
  return persisted.singleWhere((item) => item['entryId'] == entryId);
}
