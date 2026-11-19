import 'package:flutter_test/flutter_test.dart';
import 'package:termulscan/models/scan_entry.dart';

void main() {
  group('ScanEntry', () {
    test('barcode entry round-trips through persisted map', () {
      final timestamp = DateTime(2026, 10, 9, 14, 30, 45);
      final original = ScanEntry(
        id: 'scan-1',
        type: ScanType.barcode,
        value: 'AWB-12345',
        barcodeFormat: 'code128',
        timestamp: timestamp,
        latitude: -7.98,
        longitude: 112.63,
        locationName: 'Gudang Utama',
      );

      final restored = ScanEntry.fromMap(original.toMap());

      expect(restored.id, original.id);
      expect(restored.isBarcode, isTrue);
      expect(restored.barcodeValue, 'AWB-12345');
      expect(restored.barcodeType, 'code128');
      expect(restored.timestamp, timestamp);
      expect(restored.latitude, -7.98);
      expect(restored.longitude, 112.63);
      expect(restored.address, 'Gudang Utama');
    });

    test('photo entry displays barcode as title when available', () {
      final entry = ScanEntry(
        id: 'photo-1',
        type: ScanType.photo,
        value: '/app/photos/photo_123_1.jpg',
        imagePath: '/app/photos/photo_123_1.jpg',
        scanResult: 'AWB-9988',
        timestamp: DateTime(2026, 10, 9),
      );

      expect(entry.isPhoto, isTrue);
      expect(entry.displayImagePath, '/app/photos/photo_123_1.jpg');
      expect(entry.displayTitle, 'AWB-9988');
    });

    test('legacy photo map without type keeps its image path', () {
      final entry = ScanEntry.fromMap({
        'id': 'legacy-photo',
        'value': '/app/photos/photo_456_1.jpg',
        'timestamp': '2026-10-09T12:00:00.000',
      });

      expect(entry.isPhoto, isTrue);
      expect(entry.displayImagePath, '/app/photos/photo_456_1.jpg');
    });

    test('photo GPS quality metadata round-trips through persisted map', () {
      final original = ScanEntry(
        id: 'photo-gps-1',
        type: ScanType.photo,
        value: '/app/photos/gps.jpg',
        imagePath: '/app/photos/gps.jpg',
        timestamp: DateTime(2026, 11, 19, 10),
        latitude: -7.98,
        longitude: 112.63,
        locationAccuracyMeters: 7.5,
        locationAgeMillis: 420,
        locationProvider: 'gps',
        locationIsFallback: false,
      );

      final restored = ScanEntry.fromMap(original.toMap());

      expect(restored.locationAccuracyMeters, 7.5);
      expect(restored.locationAgeMillis, 420);
      expect(restored.locationProvider, 'gps');
      expect(restored.locationIsFallback, isFalse);
    });

    test('legacy history defaults GPS quality metadata safely', () {
      final restored = ScanEntry.fromMap({
        'id': 'old-photo',
        'type': 'photo',
        'value': '/app/photos/old.jpg',
        'timestamp': '2026-10-09T12:00:00.000',
        'latitude': -7.98,
        'longitude': 112.63,
      });

      expect(restored.locationAccuracyMeters, isNull);
      expect(restored.locationAgeMillis, isNull);
      expect(restored.locationProvider, isNull);
      expect(restored.locationIsFallback, isFalse);
    });

    test('barcode without scan result uses barcode value as title', () {
      final entry = ScanEntry(
        id: 'scan-2',
        type: ScanType.barcode,
        value: '123456789',
        timestamp: DateTime(2026, 10, 9),
      );

      expect(entry.displayTitle, '123456789');
    });
  });
}
