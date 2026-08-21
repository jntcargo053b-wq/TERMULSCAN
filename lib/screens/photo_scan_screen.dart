import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/scan_entry.dart';
import '../services/location_service.dart';
import '../services/photo_task_recovery_service.dart';
import '../services/storage_service.dart';
import '../services/watermark_service.dart';
import '../theme/app_theme.dart';
import 'watermark_settings.dart';
import 'watermark_settings_sheet.dart';

class PhotoScanScreen extends StatefulWidget {

  // Lightweight POD GPS policy: 20m is the quality target; 30m is the maximum accepted capture accuracy.
  static const double _gpsQualityTargetMeters = 20.0;
  static const double _gpsMaxAcceptedMeters = 30.0;

  /// Hasil barcode/QR yang didapat dari layar scan sebelumnya (opsional).
  /// Jika diset, kamera akan langsung terbuka tanpa menampilkan tombol.
  final String? initialBarcode;

  const PhotoScanScreen({super.key, this.initialBarcode});

  @override
  State<PhotoScanScreen> createState() => _PhotoScanScreenState();
}

class _PhotoScanScreenState extends State<PhotoScanScreen>
    with WidgetsBindingObserver {
  final _picker = ImagePicker();
  final _storage = StorageService();
  final _loc = LocationService();
  final _wmSettings = WatermarkSettings();

  bool _isSaving = false;
  int _photoCount = 0;
  bool _locationGranted = false;

  /// Barcode yang akan dicantumkan di watermark.
  /// Diisi dari widget.initialBarcode (bisa null).
  String? _barcode;

  /// Antrian burn watermark — FIFO chained Future. Lihat penjelasan di
  /// _burnWatermark kenapa pola ini dipakai (bukan single Completer lock).
  Future<void> _burnQueue = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _barcode = widget.initialBarcode;
    _checkLocationPermission();
    _wmSettings.load();

    // Jika ada barcode, langsung buka kamera setelah layout selesai.
    if (_barcode != null && _barcode!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _takePhoto();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkLocationPermission();
    }
  }

  // ============================================================================
  // Izin
  // ============================================================================

  Future<void> _checkLocationPermission() async {
    final status = await Permission.location.status;
    if (!status.isGranted) {
      final result = await Permission.location.request();
      if (mounted) setState(() => _locationGranted = result.isGranted);
    } else {
      if (mounted) setState(() => _locationGranted = true);
    }
  }

  Future<bool> _ensureGalleryPermission() async {
    var status = await Permission.photos.status;
    if (status.isGranted || status.isLimited) return true;
    status = await Permission.photos.request();
    if (status.isGranted || status.isLimited) return true;
    if (status.isPermanentlyDenied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
              'Izin galeri ditolak permanen — aktifkan manual di Pengaturan'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: 'BUKA SETTING',
            onPressed: openAppSettings,
          ),
        ),
      );
    }
    return false;
  }

  // ============================================================================
  // Pemindaian barcode dari gambar galeri
  // ============================================================================

  /// Scan barcode/QR dari file gambar (dipakai untuk foto yang dipilih dari
  /// galeri, di mana barcode tidak diketahui lebih dulu seperti dari layar
  /// scan kamera langsung).
  ///
  /// Pakai `mobile_scanner` yang SUDAH jadi dependency app ini
  /// (`controller.analyzeImage()`). Versi mobile_scanner 3.x: analyzeImage()
  /// mengembalikan bool dan hasil barcode dikirim lewat stream `barcodes`.
  Future<String?> _scanBarcodeFromImage(String imagePath) async {
    final controller = MobileScannerController();
    StreamSubscription<BarcodeCapture>? sub;
    try {
      final completer = Completer<String?>();
      sub = controller.barcodes.listen((capture) {
        for (final barcode in capture.barcodes) {
          if (barcode.rawValue != null && barcode.rawValue!.isNotEmpty) {
            if (!completer.isCompleted) completer.complete(barcode.rawValue);
            return;
          }
        }
      });

      final found = await controller
          .analyzeImage(imagePath)
          .timeout(const Duration(seconds: 5));
      if (!found) return null;

      return await completer.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
    } catch (e) {
      debugPrint('Gagal scan barcode dari gambar: $e');
      return null;
    } finally {
      await sub?.cancel();
      controller.dispose();
    }
  }

  // ============================================================================
  // Metode utama: ambil foto dari kamera
  // ============================================================================

  Future<void> _takePhoto() async {
    if (!_locationGranted) {
      await _checkLocationPermission();
      if (!_locationGranted) {
        _showError('Izin lokasi diperlukan untuk menandai foto');
        return;
      }
    }

    String? previewPath;
    String? sourcePath;
    String? savedPath;
    String? entryId;
    bool taskCreated = false;
    try {
      // ImagePicker controls the native camera UI, so the earliest reliable
      // capture timestamp we can obtain is immediately after it returns the
      // captured file. GPS acquisition also starts only after capture, keeping
      // the coordinate close to the actual photo rather than stale from the
      // moment the camera UI opened.
      final xfile = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        imageQuality: 65,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (xfile == null) return;

      sourcePath = xfile.path;
      final capturedAt = DateTime.now();
      HapticFeedback.mediumImpact();

      // One lightweight native GPS request. No multi-sample lock/Kalman.
      final captureCoords = await _loc.getCoordinatesOnly();
      final gpsAccuracy = captureCoords.accuracy;
      final gpsValid = captureCoords.lat != null &&
          captureCoords.lng != null &&
          gpsAccuracy != null &&
          gpsAccuracy <= _gpsMaxAcceptedMeters;
      if (!gpsValid) {
        throw Exception(
          'GPS belum cukup akurat (maksimal 30 m, target 20 m). '
          'Tunggu beberapa detik di area terbuka lalu ambil foto lagi.'
          '${gpsAccuracy != null ? ' Akurasi saat ini: ${gpsAccuracy.toStringAsFixed(1)} m.' : ''}',
        );
      }

      // Resolve the address in parallel with the temporary preview burn. The
      // preview must be watermarked before confirmation, but it should not
      // block capture on reverse geocoding/network latency.
      final addressFuture = _loc
          .reverseGeocode(captureCoords.lat!, captureCoords.lng!, accuracy: gpsAccuracy)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);

      previewPath = await _createPreviewWatermark(
        sourcePath: sourcePath!,
        timestamp: capturedAt,
        latitude: captureCoords.lat!,
        longitude: captureCoords.lng!,
        barcode: _barcode,
      );

      final confirmed = await _showPreviewAndConfirm(previewPath);
      if (!mounted) return;
      if (!confirmed) return;

      setState(() => _isSaving = true);

      final address = await addressFuture;
      final locationText = (address != null && address.isNotEmpty)
          ? address
          : '${captureCoords.lat!.toStringAsFixed(5)}, ${captureCoords.lng!.toStringAsFixed(5)}';

      // Persist the raw/source photo first; the pending task is created before
      // the final burn so a process death during burn can be recovered later.
      savedPath = await _storage.savePhoto(sourcePath!);
      await _storage.savePhotoRawCopy(sourcePath!, savedPath!);

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: savedPath,
        imagePath: savedPath,
        timestamp: capturedAt,
        latitude: captureCoords.lat,
        longitude: captureCoords.lng,
        locationName: address,
        scanResult: _barcode,
      );
      entryId = entry.id;
      await _storage.add(entry);
      await _storage.enqueuePhotoTask(
        entry.id,
        latitude: captureCoords.lat,
        longitude: captureCoords.lng,
      );
      taskCreated = true;

      try {
        await _burnWatermark(
          sourcePath: savedPath,
          destPath: savedPath,
          timestamp: capturedAt,
          locationText: locationText,
          barcode: _barcode,
        );
        await _storage.markPhotoWatermarkCompleted(
          entry.id,
          addressResolved: address != null && address.isNotEmpty,
        );
      } catch (_) {
        // Keep the task pending so startup recovery can retry the final burn.
        rethrow;
      }

      if (!mounted) return;
      setState(() {
        _photoCount++;
        _isSaving = false;
      });

      _showSuccess(entry);
    } catch (e) {
      if (!taskCreated && entryId != null) {
        try { await _storage.deleteEntry(entryId!); } catch (_) {}
      }
      if (!taskCreated && savedPath != null) {
        try { await File(savedPath!).delete(); } catch (_) {}
        try { await File(_storage.rawPathFor(savedPath!)).delete(); } catch (_) {}
      }
      if (mounted) setState(() => _isSaving = false);
      if (taskCreated) {
        _showError('Foto tersimpan. Watermark belum selesai dan akan diproses ulang otomatis.');
      } else {
        _showError('Gagal ambil foto: $e');
      }
    } finally {
      if (previewPath != null) _deleteTempFile(previewPath);
      if (sourcePath != null) _deleteTempFile(sourcePath);
    }
  }

  // ============================================================================
  // Ambil dari galeri (dengan scan barcode otomatis dari gambar)
  // ============================================================================

  Future<void> _pickFromGallery() async {
    if (!_locationGranted) {
      await _checkLocationPermission();
      if (!_locationGranted) {
        _showError('Izin lokasi diperlukan untuk menandai foto');
        return;
      }
    }

    String? previewPath;
    String? sourcePath;
    String? savedPath;
    String? entryId;
    bool taskCreated = false;
    try {
      final xfile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        imageQuality: 65,
      );
      if (xfile == null) return;

      sourcePath = xfile.path;
      final capturedAt = DateTime.now();

      // Start the one-shot GPS request immediately after the user selects the
      // image, while barcode scanning runs. No persisted file is created until
      // GPS has passed the 30m acceptance threshold.
      final captureCoordsFuture = _loc.getCoordinatesOnly();

      String? scannedBarcode;
      try {
        scannedBarcode = await _scanBarcodeFromImage(xfile.path);
        if (scannedBarcode != null && scannedBarcode.isNotEmpty && mounted) {
          setState(() => _barcode = scannedBarcode);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✓ Barcode terdeteksi: $scannedBarcode'),
                duration: const Duration(seconds: 2),
                backgroundColor: Colors.green.shade700,
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('⚠️ Gagal memindai gambar: $e'),
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }

      final captureCoords = await captureCoordsFuture;
      final gpsAccuracy = captureCoords.accuracy;
      final gpsValid = captureCoords.lat != null &&
          captureCoords.lng != null &&
          gpsAccuracy != null &&
          gpsAccuracy <= _gpsMaxAcceptedMeters;
      if (!gpsValid) {
        throw Exception(
          'GPS belum cukup akurat (maksimal 30 m, target 20 m). '
          'Tunggu beberapa detik di area terbuka lalu pilih foto lagi.'
          '${gpsAccuracy != null ? ' Akurasi saat ini: ${gpsAccuracy.toStringAsFixed(1)} m.' : ''}',
        );
      }

      final addressFuture = _loc
          .reverseGeocode(captureCoords.lat!, captureCoords.lng!, accuracy: gpsAccuracy)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);

      previewPath = await _createPreviewWatermark(
        sourcePath: sourcePath!,
        timestamp: capturedAt,
        latitude: captureCoords.lat!,
        longitude: captureCoords.lng!,
        barcode: _barcode,
      );

      final confirmed = await _showPreviewAndConfirm(previewPath);
      if (!mounted) return;
      if (!confirmed) return;

      setState(() => _isSaving = true);

      final address = await addressFuture;
      final locationText = (address != null && address.isNotEmpty)
          ? address
          : '${captureCoords.lat!.toStringAsFixed(5)}, ${captureCoords.lng!.toStringAsFixed(5)}';

      savedPath = await _storage.savePhoto(sourcePath!);
      await _storage.savePhotoRawCopy(sourcePath!, savedPath!);

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: savedPath,
        imagePath: savedPath,
        timestamp: capturedAt,
        latitude: captureCoords.lat,
        longitude: captureCoords.lng,
        locationName: address,
        scanResult: _barcode,
      );
      entryId = entry.id;
      await _storage.add(entry);
      await _storage.enqueuePhotoTask(
        entry.id,
        latitude: captureCoords.lat,
        longitude: captureCoords.lng,
      );
      taskCreated = true;

      try {
        await _burnWatermark(
          sourcePath: savedPath,
          destPath: savedPath,
          timestamp: capturedAt,
          locationText: locationText,
          barcode: _barcode,
        );
        await _storage.markPhotoWatermarkCompleted(
          entry.id,
          addressResolved: address != null && address.isNotEmpty,
        );
      } catch (_) {
        rethrow;
      }

      if (!mounted) return;
      setState(() {
        _photoCount++;
        _isSaving = false;
      });
      _showSuccess(entry);
    } catch (e) {
      if (!taskCreated && entryId != null) {
        try { await _storage.deleteEntry(entryId!); } catch (_) {}
      }
      if (!taskCreated && savedPath != null) {
        try { await File(savedPath!).delete(); } catch (_) {}
        try { await File(_storage.rawPathFor(savedPath!)).delete(); } catch (_) {}
      }
      if (mounted) setState(() => _isSaving = false);
      if (taskCreated) {
        _showError('Foto tersimpan. Watermark belum selesai dan akan diproses ulang otomatis.');
      } else {
        _showError('Gagal memilih foto: $e');
      }
    } finally {
      if (previewPath != null) _deleteTempFile(previewPath);
      if (sourcePath != null) _deleteTempFile(sourcePath);
    }
  }

  // ============================================================================
  // Watermark dengan antrian FIFO
  // ============================================================================

  /// Membakar watermark, diserialisasi lewat [_burnQueue] via chained Future
  /// (bukan single Completer lock — pola itu bocor kalau ada 3+ pemanggil
  /// bersamaan). Setiap panggilan mengembalikan Future terpisah yang
  /// resolve/error sesuai hasil burn PANGGILAN INI SAJA; kegagalan satu burn
  /// tidak menghentikan antrian burn lain di belakangnya.
  Future<String> _createPreviewWatermark({
    required String sourcePath,
    required DateTime timestamp,
    required double latitude,
    required double longitude,
    String? barcode,
  }) async {
    final destPath = '${Directory.systemTemp.path}/termulscan_preview_${DateTime.now().microsecondsSinceEpoch}.jpg';
    await _burnWatermark(
      sourcePath: sourcePath,
      destPath: destPath,
      timestamp: timestamp,
      locationText: '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}',
      barcode: barcode,
    );
    return destPath;
  }

  Future<void> _burnWatermark({
    required String sourcePath,
    required String destPath,
    required DateTime timestamp,
    required String locationText,
    String? barcode,
  }) {
    final completer = Completer<void>();
    _burnQueue = _burnQueue.then((_) async {
      try {
        if (!File(sourcePath).existsSync()) {
          // JANGAN fallback ke file publik yang sudah ber-watermark — akan
          // menumpuk watermark baru di atas watermark lama.
          throw Exception(
              'File sumber watermark tidak ditemukan: $sourcePath (raw copy hilang)');
        }

        Uint8List? logoBytes;
        if (_wmSettings.hasLogo) {
          final logoFile = File(_wmSettings.logoPath!);
          if (await logoFile.exists()) {
            final length = await logoFile.length();
            // Hindari menahan asset logo multi-MB di setiap item queue.
            if (length <= 512 * 1024) {
              logoBytes = await logoFile.readAsBytes();
            }
          }
        }

        final lines = <String>[];
        if (barcode != null && barcode.isNotEmpty) {
          lines.add('AWB: $barcode');
        }
        lines.add(DateFormat('dd/MM/yyyy HH:mm:ss').format(timestamp));
        lines.add(locationText);
        if (_wmSettings.operatorName.isNotEmpty) {
          lines.add('Operator: ${_wmSettings.operatorName}');
        }

        await WatermarkService.burn(
          sourcePath: sourcePath,
          destPath: destPath,
          lines: lines,
          logoBytes: logoBytes,
        );

        if (!completer.isCompleted) completer.complete();
      } catch (e, st) {
        debugPrint('Watermark error: $e\n$st');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: AppTheme.error,
              duration: const Duration(seconds: 3),
              content: Text('⚠️ Gagal menandai watermark: $e'),
            ),
          );
        }
        if (!completer.isCompleted) completer.completeError(e, st);
      }
      // Selalu resolve normal di sini supaya antrian tetap lanjut memproses
      // burn berikutnya walau burn ini gagal (error sudah disalurkan lewat
      // `completer` di atas, terpisah dari resolusi _burnQueue).
    });
    return completer.future;
  }

  // ============================================================================
  // UI Helpers
  // ============================================================================

  Future<bool> _showPreviewAndConfirm(String path) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PhotoPreviewScreen(
          imagePath: path,
          barcode: _barcode,
        ),
      ),
    );
    return result ?? false;
  }

  void _deleteTempFile(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Abaikan
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: AppTheme.error, content: Text(msg)),
      );
    }
  }

  void _showSuccess(ScanEntry entry) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 4),
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 18),
            const Gap(8),
            Expanded(
              child: Text(
                'Foto tersimpan  •  ${entry.locationName ?? entry.coordinatesString}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'KE GALERI',
          textColor: Colors.white,
          onPressed: () => _saveToGallery(entry.value),
        ),
      ),
    );
  }

  Future<void> _saveToGallery(String filePath) async {
    final granted = await _ensureGalleryPermission();
    if (!granted) return;
    try {
      await Gal.putImage(filePath, album: 'TermulScan');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
          content: const Text('✓ Foto tersimpan ke galeri'),
        ),
      );
    } on GalException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.error,
          content: Text('Gagal menyimpan ke galeri: ${e.type.message}'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.error,
          content: Text('Gagal menyimpan ke galeri: $e'),
        ),
      );
    }
  }

  // ============================================================================
  // Build
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    final hasBarcode = _barcode != null && _barcode!.isNotEmpty;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(hasBarcode ? 'Foto dengan Scan' : 'Ambil Foto'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context, _photoCount),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.add_a_photo_outlined,
                size: 72,
                color: AppTheme.accent,
              ),
              const Gap(20),
              Text(
                hasBarcode ? 'Ambil foto untuk AWB' : 'Dokumentasi Foto',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displayMedium,
              ),
              const Gap(10),
              Text(
                hasBarcode
                    ? 'Barcode akan dicantumkan pada watermark foto.'
                    : 'Foto akan diberi watermark waktu dan lokasi secara otomatis.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (hasBarcode) ...[
                const Gap(16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.qr_code_2, color: AppTheme.accent),
                      const Gap(10),
                      Expanded(
                        child: Text(
                          _barcode!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_photoCount > 0) ...[
                const Gap(16),
                Text(
                  'Foto tersimpan sesi ini: $_photoCount',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              const Gap(28),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _isSaving ? null : _takePhoto,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('AMBIL FOTO'),
                ),
              ),
              const Gap(12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: _isSaving ? null : _pickFromGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('PILIH DARI GALERI'),
                ),
              ),
              const Gap(12),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const WatermarkSettingsSheet(),
                  ),
                ),
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Pengaturan watermark'),
              ),
              if (_isSaving) ...[
                const Gap(18),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoPreviewScreen extends StatelessWidget {
  final String imagePath;
  final String? barcode;

  const _PhotoPreviewScreen({
    required this.imagePath,
    this.barcode,
  });

  @override
  Widget build(BuildContext context) {
    final hasBarcode = barcode != null && barcode!.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Pratinjau Foto'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4,
                child: Center(
                  child: Image.file(
                    File(imagePath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      size: 64,
                      color: Colors.white54,
                    ),
                  ),
                ),
              ),
            ),
            if (hasBarcode)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Barcode: $barcode',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context, false),
                      icon: const Icon(Icons.refresh),
                      label: const Text('ULANGI'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                    ),
                  ),
                  const Gap(12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(context, true),
                      icon: const Icon(Icons.check),
                      label: const Text('GUNAKAN'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
