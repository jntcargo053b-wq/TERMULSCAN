import 'dart:io';
import 'package:intl/intl.dart';

import '../models/scan_entry.dart';
import '../screens/watermark_settings.dart';
import 'location_service.dart';
import 'storage_service.dart';
import 'watermark_service.dart';

/// Memulihkan pipeline foto yang tertinggal ketika Android membunuh proses.
/// Task hanya dihapus setelah koordinat/alamat dan watermark final berhasil.
class PhotoTaskRecoveryService {
  PhotoTaskRecoveryService._();
  static final instance = PhotoTaskRecoveryService._();

  final _storage = StorageService();
  final _location = LocationService();
  final _settings = WatermarkSettings();
  bool _running = false;

  Future<void> recoverPending() async {
    if (_running) return;
    _running = true;
    try {
      await _settings.load();
      for (final entryId in List<String>.from(_storage.pendingPhotoTaskIds)) {
        await _recoverOne(entryId);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _recoverOne(String entryId) async {
    final entry = await _storage.getEntry(entryId);
    if (entry == null || !entry.isPhoto) {
      await _storage.markPhotoTaskCompleted(entryId);
      return;
    }

    final publicPath = entry.displayImagePath;
    if (publicPath == null || publicPath.isEmpty) {
      await _storage.markPhotoTaskAttempt(entryId);
      return;
    }

    final rawPath = _storage.rawPathFor(publicPath);
    if (!await File(rawPath).exists()) {
      await _storage.markPhotoTaskAttempt(entryId);
      return;
    }

    await _storage.markPhotoTaskAttempt(entryId);

    // Recovery harus memakai koordinat yang disimpan saat capture. Jangan
    // mengambil GPS baru di sini: saat app dibuka kembali, perangkat bisa
    // sudah berpindah jauh dari lokasi foto. Jika koordinat capture tidak
    // tersedia, biarkan task tetap pending daripada menulis watermark palsu.
    final task = _storage.getPhotoTask(entryId);
    final taskLat = task?['latitude'];
    final taskLng = task?['longitude'];
    final lat = taskLat is num ? taskLat.toDouble() : entry.latitude;
    final lng = taskLng is num ? taskLng.toDouble() : entry.longitude;
    if (lat == null || lng == null) return;

    var current = entry.copyWith(
      latitude: lat,
      longitude: lng,
    );
    await _storage.update(current);

    String locationText = current.coordinatesString;
    try {
      final address = await _location
          .reverseGeocode(lat, lng)
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (address != null && address.isNotEmpty) {
        locationText = address;
        current = current.copyWith(locationName: address);
        await _storage.update(current);
      }
    } catch (_) {
      // Koordinat tetap valid; alamat dapat dicoba lagi pada recovery berikutnya.
    }

    final logoBytes = _settings.hasLogo
        ? await File(_settings.logoPath!).readAsBytes()
        : null;
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

    await _storage.markPhotoTaskCompleted(entryId);
  }
}
