import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termulscan/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
  });

  group('StorageService photo recovery metadata', () {
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

      final prefs = await SharedPreferences.getInstance();
      final persisted = (json.decode(
        prefs.getString('pending_photo_tasks_v1')!,
      ) as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final savedTask = persisted.singleWhere(
        (item) => item['entryId'] == entryId,
      );
      expect(savedTask['latitude'], -7.98);
      expect(savedTask['longitude'], 112.63);
      expect(savedTask['attempts'], 0);
      expect(savedTask['addressAttempts'], 0);
    });

    test('watermark retry count and timestamp are persisted together', () async {
      const entryId = 'storage-test-watermark-retry';
      await storage.enqueuePhotoTask(entryId);

      await storage.markPhotoTaskAttempt(entryId);

      final task = storage.getPhotoTask(entryId)!;
      expect(task['attempts'], 1);
      expect(DateTime.tryParse(task['lastAttemptAt'] as String?), isNotNull);

      final prefs = await SharedPreferences.getInstance();
      final persisted = (json.decode(
        prefs.getString('pending_photo_tasks_v1')!,
      ) as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final savedTask = persisted.singleWhere(
        (item) => item['entryId'] == entryId,
      );
      expect(savedTask['attempts'], 1);
      expect(
        DateTime.tryParse(savedTask['lastAttemptAt'] as String?),
        isNotNull,
      );
    });

    test('address retry metadata is separate from watermark retries', () async {
      const entryId = 'storage-test-address-retry';
      await storage.enqueuePhotoTask(entryId);

      await storage.markPhotoTaskAttempt(entryId);
      await storage.markPhotoTaskAddressAttempt(entryId);

      final task = storage.getPhotoTask(entryId)!;
      expect(task['attempts'], 1);
      expect(task['addressAttempts'], 1);
      expect(DateTime.tryParse(task['lastAttemptAt'] as String?), isNotNull);
      expect(
        DateTime.tryParse(task['lastAddressAttemptAt'] as String?),
        isNotNull,
      );

      final prefs = await SharedPreferences.getInstance();
      final persisted = (json.decode(
        prefs.getString('pending_photo_tasks_v1')!,
      ) as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final savedTask = persisted.singleWhere(
        (item) => item['entryId'] == entryId,
      );
      expect(savedTask['attempts'], 1);
      expect(savedTask['addressAttempts'], 1);
      expect(DateTime.tryParse(savedTask['lastAttemptAt'] as String?), isNotNull);
      expect(
        DateTime.tryParse(savedTask['lastAddressAttemptAt'] as String?),
        isNotNull,
      );
    });
  });
}
