import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:intl/intl.dart';

import '../models/scan_entry.dart';
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

  Future<void> recoverPending() async {
    if (_runningRecovery) return;
    _runningRecovery = true;
    try {
      await _settings.load();
      for (final entryId in List<String>.from(_storage.pendingPhotoTaskIds)) {
        try {
          await processEntry(entryId, allowFreshLocation: false);
        } catch (e, st) {
          debugPrint('Pending photo recovery $entryId gagal: $e\n$st');
          // Continue with the next task so one broken photo cannot block the queue.
        }
      }
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

  static const int _maxRecoveryAttempts = 3;

  Future<void> _processOne(
    String entryId, {
    required bool allowFreshLocation,
  }) async {
    final entry = await _storage.getEntry(entryId);
    if (entry == null || !entry.isPhoto) {
      await _storage.markPhotoTaskCompleted(entryId);
      return;
    }

    final publicPath = entry.displayImagePath;
    if (publicPath == null || publicPath.isEmpty) {
      await _storage.markPhotoTaskCompleted(entryId);
      return;
    }

    final rawPath = _storage.rawPathFor(publicPath);
    if (!await File(rawPath).exists() || !await File(publicPath).exists()) {
      // Nothing recoverable remains; prevent an endless pending task loop.
      await _storage.markPhotoTaskCompleted(entryId);
      return;
    }

    final task = _storage.getPhotoTask(entryId);
    final watermarkCompleted = task?['watermarkCompleted'] == true;
    final attempts = (task?['attempts'] as int?) ?? 0;

    // The three-attempt limit applies only to actually burning the image.
    // Address enrichment is a separate state and may retry later when the
    // network becomes available.
    if (!watermarkCompleted && attempts >= _maxRecoveryAttempts) {
      debugPrint('Photo task $entryId reached watermark retry limit; stopping recovery.');
      await _storage.markPhotoTaskCompleted(entryId);
      return;
    }
    final taskLat = task?['latitude'];
    final taskLng = task?['longitude'];
    double? lat = taskLat is num ? taskLat.toDouble() : entry.latitude;
    double? lng = taskLng is num ? taskLng.toDouble() : entry.longitude;

    // Hanya task yang masih hidup pada proses capture boleh meminta lokasi
    // baru. Recovery setelah process death tidak boleh menggeser lokasi foto.
    if (allowFreshLocation && (lat == null || lng == null)) {
      final coords = await _location.getCoordinatesOnly();
      lat = coords.lat;
      lng = coords.lng;
      if (lat != null && lng != null) {
        await _storage.enqueuePhotoTask(entryId, latitude: lat, longitude: lng);
      }
    }

    if (lat == null || lng == null) return;

    if (!watermarkCompleted) {
      await _storage.markPhotoTaskAttempt(entryId);
    }

    var current = entry.copyWith(latitude: lat, longitude: lng);
    await _storage.update(current);

    final taskState = _storage.getPhotoTask(entryId);
    final addressResolvedState = taskState?['addressResolved'] == true;

    String locationText = current.coordinatesString;
    String? resolvedAddress;
    try {
      final cached = _storage.getCachedLocation(lat, lng);
      resolvedAddress = cached ??
          await _location.reverseGeocode(lat, lng).timeout(
            const Duration(seconds: 10),
            onTimeout: () => null,
          );

      if (resolvedAddress != null && resolvedAddress!.isNotEmpty) {
        locationText = resolvedAddress!;
        _storage.updateGeoCache(lat, lng, resolvedAddress!);
        current = current.copyWith(locationName: resolvedAddress);
        await _storage.update(current);
        await _storage.markPhotoAddressAttempt(entryId);
      } else {
        await _storage.markPhotoAddressAttempt(entryId);
      }
    } catch (e) {
      debugPrint('Reverse geocode $entryId gagal: $e');
      try {
        await _storage.markPhotoAddressAttempt(entryId);
      } catch (_) {}
    }

    final hasAddress = resolvedAddress != null && resolvedAddress!.isNotEmpty;

    // If the image was already burned with coordinates, do not burn it again
    // merely because reverse-geocoding is temporarily unavailable.
    if (!watermarkCompleted) {
      final logoBytes = await _loadCompactLogo();
      final lines = <String>[
        if (current.scanResult?.isNotEmpty == true) 'AWB: ${current.scanResult}',
        DateFormat('dd/MM/yyyy HH:mm:ss').format(current.timestamp),
        locationText,
        if (_settings.operatorName.isNotEmpty)
          'Operator: ${_settings.operatorName}',
      ];

      await WatermarkService.burn(
        sourcePath: rawPath,
        destPath: publicPath,
        lines: lines,
        logoBytes: logoBytes,
      );

      await FileImage(File(publicPath)).evict();

      await _storage.markPhotoWatermarkCompleted(
        entryId,
        addressResolved: hasAddress,
      );
      return;
    }

    // Watermark already exists. Only an address enrichment is needed now.
    if (hasAddress && !addressResolvedState) {
      final logoBytes = await _loadCompactLogo();
      final lines = <String>[
        if (current.scanResult?.isNotEmpty == true) 'AWB: ${current.scanResult}',
        DateFormat('dd/MM/yyyy HH:mm:ss').format(current.timestamp),
        resolvedAddress!,
        if (_settings.operatorName.isNotEmpty)
          'Operator: ${_settings.operatorName}',
      ];

      await WatermarkService.burn(
        sourcePath: rawPath,
        destPath: publicPath,
        lines: lines,
        logoBytes: logoBytes,
      );

      await FileImage(File(publicPath)).evict();

      await _storage.markPhotoAddressResolved(entryId);
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
