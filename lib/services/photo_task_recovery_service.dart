import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:intl/intl.dart';

import '../screens/watermark_settings.dart';
import 'location_service.dart';
import 'storage_service.dart';
import 'watermark_service.dart';

/// Memproses pipeline foto di luar Widget State.
///
/// Service ini sengaja tidak menyimpan BuildContext/State/ScaffoldMessenger,
/// sehingga task background tidak menahan PhotoScanScreen setelah dispose().
class PhotoTaskRecoveryService {
  PhotoTaskRecoveryService._();
  static final instance = PhotoTaskRecoveryService._();

  final _storage = StorageService();
  final _location = LocationService();
  final _settings = WatermarkSettings();
  Future<void> _chain = Future.value();
  bool _runningRecovery = false;
  Timer? _monitorTimer;

  void startMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      unawaited(recoverPending());
    });
  }

  void disposeMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
  }

  Future<void> recoverPending() async {
    if (_runningRecovery) return;
    _runningRecovery = true;
    try {
      await _settings.load();
      for (final entryId in List<String>.from(_storage.pendingPhotoTaskIds)) {
        await processEntry(entryId, allowFreshLocation: false);
      }
    } catch (e, st) {
      // Recovery berjalan sebagai background task dan tidak boleh membuat
      // startup/widget test gagal hanya karena plugin storage belum tersedia.
      // Task tetap dipertahankan untuk percobaan berikutnya.
      debugPrint('Photo recovery startup gagal: $e\\n$st');
    } finally {
      _runningRecovery = false;
    }
  }

  /// Jalur aktif setelah capture. Boleh memakai GPS saat ini hanya jika
  /// capture belum mendapatkan koordinat sama sekali.
  Future<void> processEntry(String entryId, {bool allowFreshLocation = true}) {
    final completer = Completer<void>();
    _chain = _chain.then((_) async {
      try {
        await _settings.load();
        await _processOne(entryId, allowFreshLocation: allowFreshLocation);
        if (!completer.isCompleted) completer.complete();
      } catch (e, st) {
        debugPrint('Photo task $entryId gagal: $e\n$st');
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _processOne(
    String entryId, {
    required bool allowFreshLocation,
  }) async {
    final entry = await _storage.getEntry(entryId);
    if (entry == null || !entry.isPhoto) {
      await _storage.markPhotoTaskCompleted(entryId);
      return;
    }

    final task = _storage.getPhotoTask(entryId);
    if (task == null) return;
    if (task['retryExhausted'] == true) return;

    final attempts = (task['attempts'] as int?) ?? 0;
    if (attempts >= 3) {
      await _storage.markPhotoTaskRetryExhausted(entryId);
      return;
    }
    final publicPath = entry.displayImagePath;
    if (publicPath == null || publicPath.isEmpty) {
      await _storage.markPhotoTaskAttempt(entryId);
      if (attempts + 1 >= 3) {
        await _storage.markPhotoTaskRetryExhausted(entryId);
      }
      return;
    }

    final rawPath = _storage.rawPathFor(publicPath);
    if (!await File(rawPath).exists()) {
      // Count missing-source failures; otherwise attempts never advance and
      // this unrecoverable task would be revisited forever.
      await _storage.markPhotoTaskAttempt(entryId);
      if (attempts + 1 >= 3) {
        await _storage.markPhotoTaskRetryExhausted(entryId);
      }
      return;
    }

    final taskLat = task['latitude'];
    final taskLng = task['longitude'];
    double? lat = taskLat is num ? taskLat.toDouble() : entry.latitude;
    double? lng = taskLng is num ? taskLng.toDouble() : entry.longitude;

    if (allowFreshLocation && (lat == null || lng == null)) {
      final coords = await _location.getCoordinatesOnly();
      lat = coords.lat;
      lng = coords.lng;
      if (lat != null && lng != null) {
        await _storage.enqueuePhotoTask(entryId, latitude: lat, longitude: lng);
      }
    }

    var current = entry;
    if (lat != null && lng != null &&
        (current.latitude != lat || current.longitude != lng)) {
      current = current.copyWith(latitude: lat, longitude: lng);
      await _storage.update(current);
    }

    final addressResolved = task['addressResolved'] == true;
    final watermarkCompleted = task['watermarkCompleted'] == true;

    // Jika watermark sudah selesai tetapi alamat belum, jangan membakar ulang
    // kecuali reverse-geocode sekarang berhasil. Sumber tetap RAW sehingga
    // watermark tidak pernah menumpuk.
    if (watermarkCompleted && !addressResolved) {
      // Tanpa koordinat capture, alamat tidak bisa dipulihkan secara aman.
      // Jangan mengganti lokasi foto lama dengan posisi perangkat saat ini.
      if (lat == null || lng == null) {
        await _storage.markPhotoTaskCompleted(entryId);
        return;
      }

      final addressAttempts = (task['addressAttempts'] as int?) ?? 0;
      if (addressAttempts >= 3) {
        await _storage.markPhotoTaskRetryExhausted(entryId);
        return;
      }
      await _storage.markPhotoTaskAddressAttempt(entryId);

      try {
        final address = await _location
            .reverseGeocode(lat, lng, accuracy: null)
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
        if (address == null || address.trim().isEmpty) {
          if (addressAttempts + 1 >= 3) {
            await _storage.markPhotoTaskRetryExhausted(entryId);
          }
          return;
        }

        final resolvedAddress = address.trim();
        current = current.copyWith(locationName: resolvedAddress);
        await _storage.update(current);

        final logoBytes = await _loadCompactLogo();
        final lines = <String>[
          if (current.scanResult?.isNotEmpty == true) 'AWB: ${current.scanResult}',
          DateFormat('dd/MM/yyyy HH:mm:ss').format(current.timestamp),
          resolvedAddress,
          if (_settings.operatorName.isNotEmpty) 'Operator: ${_settings.operatorName}',
        ];
        await WatermarkService.burn(
          sourcePath: rawPath,
          destPath: publicPath,
          lines: lines,
          logoBytes: logoBytes,
        );
        await _evictPublicImage(publicPath);
        await _storage.markPhotoTaskAddressResolved(entryId);
        await _storage.markPhotoTaskCompleted(entryId);
        return;
      } catch (e, st) {
        debugPrint('Address retry $entryId gagal: $e\\n$st');
        if (addressAttempts + 1 >= 3) {
          await _storage.markPhotoTaskRetryExhausted(entryId);
        }
        return;
      }
    }

    if (watermarkCompleted && addressResolved) {
      await _storage.markPhotoTaskCompleted(entryId);
      return;
    }

    // Hanya proses watermark yang mengonsumsi retry counter.
    await _storage.markPhotoTaskAttempt(entryId);

    String locationText = current.coordinatesString;
    var resolvedNow = false;
    if (lat != null && lng != null) {
      try {
        final address = await _location
            .reverseGeocode(lat, lng, accuracy: null)
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
        if (address != null && address.trim().isNotEmpty) {
          locationText = address.trim();
          resolvedNow = true;
          current = current.copyWith(locationName: locationText);
          await _storage.update(current);
        }
      } catch (e) {
        debugPrint('Reverse geocode $entryId gagal: $e');
      }
    }

    final logoBytes = await _loadCompactLogo();
    final lines = <String>[
      if (current.scanResult?.isNotEmpty == true) 'AWB: ${current.scanResult}',
      DateFormat('dd/MM/yyyy HH:mm:ss').format(current.timestamp),
      locationText,
      if (_settings.operatorName.isNotEmpty) 'Operator: ${_settings.operatorName}',
    ];

    await WatermarkService.burn(
      sourcePath: rawPath,
      destPath: publicPath,
      lines: lines,
      logoBytes: logoBytes,
    );
    await _evictPublicImage(publicPath);

    await _storage.markPhotoTaskWatermarkCompleted(entryId);
    if (resolvedNow) {
      await _storage.markPhotoTaskAddressResolved(entryId);
      await _storage.markPhotoTaskCompleted(entryId);
    }
  }

  Future<void> _evictPublicImage(String path) async {
    try {
      await FileImage(File(path)).evict();
    } catch (e) {
      debugPrint('Gagal memperbarui cache foto $path: $e');
    }
  }

  Future<Uint8List?> _loadCompactLogo() async {
    if (!_settings.hasLogo) return null;
    final path = _settings.logoPath;
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    // WatermarkService melakukan decode+resize di isolate. Batasi file logo
    // sebelum dikirim ke isolate agar antrean tidak menahan asset multi-MB.
    final bytes = await file.readAsBytes();
    if (bytes.length <= 512 * 1024) return bytes;
    return null;
  }
}
