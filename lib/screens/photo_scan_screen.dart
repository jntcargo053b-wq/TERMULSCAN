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
import '../models/scan_entry.dart';
import '../services/location_service.dart';
import '../services/storage_service.dart';
import '../services/watermark_service.dart';
import '../theme/app_theme.dart';
import 'watermark_settings.dart';

class PhotoScanScreen extends StatefulWidget {
  const PhotoScanScreen({super.key});

  @override
  State<PhotoScanScreen> createState() => _PhotoScanScreenState();
}

class _PhotoScanScreenState extends State<PhotoScanScreen> with WidgetsBindingObserver {
  final _picker = ImagePicker();
  final _storage = StorageService();
  final _loc = LocationService();
  final _wmSettings = WatermarkSettings();

  bool _isSaving = false;
  int _photoCount = 0;
  bool _locationGranted = false;

  // Antrian burn watermark — dirantai lewat Future, BUKAN single Completer.
  // Pola single-Completer sebelumnya cuma aman untuk 2 pemanggil bersamaan:
  // kalau ada pemanggil ke-3 datang sebelum pemanggil ke-2 sempat memasang
  // lock barunya, pemanggil ke-3 akan menimpa lock pemanggil ke-2 tanpa
  // pernah menunggunya — akibatnya keduanya jalan bersamaan, persis yang
  // mau dicegah. Pola chained-future ini menjamin urutan FIFO untuk berapa
  // pun banyaknya pemanggil, dan sudah dipakai & terbukti benar di
  // LocationService._geocodeChain untuk kasus yang sama persis.
  Future<void> _burnQueue = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLocationPermission();
    _wmSettings.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Setelah kembali dari pengaturan, periksa ulang izin galeri
    if (state == AppLifecycleState.resumed) {
      _checkLocationPermission();
    }
  }

  Future<void> _checkLocationPermission() async {
    final status = await Permission.location.status;
    if (!status.isGranted) {
      final result = await Permission.location.request();
      if (mounted) setState(() => _locationGranted = result.isGranted);
    } else {
      if (mounted) setState(() => _locationGranted = true);
    }
  }

  Future<void> _takePhoto() async {
    if (!_locationGranted) {
      await _checkLocationPermission();
      if (!_locationGranted) {
        _showError('Izin lokasi diperlukan untuk menandai foto');
        return;
      }
    }

    try {
      final xfile = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        imageQuality: 65,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (xfile == null) return;

      HapticFeedback.mediumImpact();

      final confirmed = await _showPreviewAndConfirm(xfile.path);
      if (!mounted) return;
      if (!confirmed) {
        _deleteTempFile(xfile.path);
        await _takePhoto();
        return;
      }

      setState(() => _isSaving = true);

      final savedPath = await _storage.savePhoto(xfile.path);
      final capturedAt = DateTime.now();
      await _storage.savePhotoRawCopy(xfile.path, savedPath);

      // Burn awal dengan placeholder lokasi
      await _burnWatermark(
        sourcePath: savedPath,
        destPath: savedPath,
        timestamp: capturedAt,
        locationText: 'Mencari lokasi...',
      );

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: savedPath,
        timestamp: capturedAt,
        latitude: null,
        longitude: null,
        locationName: null,
      );
      await _storage.add(entry);

      setState(() {
        _photoCount++;
        _isSaving = false;
      });

      if (mounted) _showSuccess(entry);

      // Proses lokasi di background
      unawaited(_resolveLocationInBackground(entry.id));
    } catch (e) {
      setState(() => _isSaving = false);
      _showError('Gagal ambil foto: $e');
    }
  }

  Future<void> _resolveLocationInBackground(String entryId) async {
    // 1. Ambil koordinat
    final coords = await _loc.getCoordinatesOnly();
    if (coords.lat == null || coords.lng == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ GPS tidak tersedia, foto tetap tersimpan tanpa lokasi'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // Update entry dengan koordinat (tanpa re-burn dulu)
    final saved = await _storage.getEntry(entryId);
    if (saved == null) return;
    final updatedWithCoords = saved.copyWith(
      latitude: coords.lat,
      longitude: coords.lng,
    );
    await _storage.update(updatedWithCoords);

    // 2. Coba reverse geocoding dengan timeout (10 detik)
    String finalLocationText;
    try {
      final address = await _loc.reverseGeocode(coords.lat!, coords.lng!).timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
      if (address != null && address.isNotEmpty) {
        finalLocationText = address;
        // Update entry dengan nama lokasi
        final current = await _storage.getEntry(entryId);
        if (current != null) {
          final updatedWithAddress = current.copyWith(locationName: address);
          await _storage.update(updatedWithAddress);
        }
        // Tampilkan snackbar sukses
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('📍 Lokasi terdeteksi: $address'),
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.green.shade700,
            ),
          );
        }
      } else {
        // Gagal reverse geocode, gunakan koordinat mentah
        finalLocationText = updatedWithCoords.coordinatesString;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Gagal mengambil alamat, gunakan koordinat'),
              duration: Duration(seconds: 2),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      // Error reverse geocode, gunakan koordinat
      finalLocationText = updatedWithCoords.coordinatesString;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ Gagal mengambil alamat: $e'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }

    // 3. Re-burn watermark dengan lokasi final (hanya sekali)
    final currentEntry = await _storage.getEntry(entryId);
    if (currentEntry == null) return;
    try {
      await _burnWatermark(
        sourcePath: _storage.rawPathFor(currentEntry.value),
        destPath: currentEntry.value,
        timestamp: currentEntry.timestamp,
        locationText: finalLocationText,
      );
      // Hapus cache gambar agar tampilan terbaru
      await FileImage(File(currentEntry.value)).evict();
    } catch (_) {
      // Sudah ditangani (snackbar) di dalam _burnWatermark — foto tetap
      // ada dengan watermark placeholder, tidak perlu ditangani ulang di sini.
    }
  }

  Future<void> _pickFromGallery() async {
    if (!_locationGranted) {
      await _checkLocationPermission();
      if (!_locationGranted) {
        _showError('Izin lokasi diperlukan untuk menandai foto');
        return;
      }
    }

    try {
      final xfile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        imageQuality: 65,
      );
      if (xfile == null) return;

      final confirmed = await _showPreviewAndConfirm(xfile.path);
      if (!mounted) return;
      if (!confirmed) {
        await _pickFromGallery();
        return;
      }

      setState(() => _isSaving = true);

      final savedPath = await _storage.savePhoto(xfile.path);
      final capturedAt = DateTime.now();
      await _storage.savePhotoRawCopy(xfile.path, savedPath);

      await _burnWatermark(
        sourcePath: savedPath,
        destPath: savedPath,
        timestamp: capturedAt,
        locationText: 'Mencari lokasi...',
      );

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: savedPath,
        timestamp: capturedAt,
        latitude: null,
        longitude: null,
        locationName: null,
      );
      await _storage.add(entry);

      setState(() {
        _photoCount++;
        _isSaving = false;
      });

      if (mounted) _showSuccess(entry);
      unawaited(_resolveLocationInBackground(entry.id));
    } catch (e) {
      setState(() => _isSaving = false);
      _showError('Gagal memilih foto: $e');
    }
  }

  /// Membakar watermark, diserialisasi lewat [_burnQueue] supaya burn untuk
  /// beberapa foto tidak menembak banyak isolate compute() bersamaan.
  /// Setiap panggilan menunggu giliran lewat rantai Future FIFO, lalu
  /// mengembalikan Future terpisah yang resolve/error sesuai hasil burn
  /// PANGGILAN INI SAJA — kegagalan satu burn tidak menghentikan antrian
  /// burn lain yang menunggu di belakangnya (persis pola _geocodeChain di
  /// LocationService).
  Future<void> _burnWatermark({
    required String sourcePath,
    required String destPath,
    required DateTime timestamp,
    required String locationText,
  }) {
    final completer = Completer<void>();
    _burnQueue = _burnQueue.then((_) async {
      try {
        // Cek apakah source tersedia.
        if (!File(sourcePath).existsSync()) {
          // JANGAN fallback ke file publik yang sudah ber-watermark —
          // membakar watermark baru di atas watermark lama akan
          // menumpuk bar/teks (persis masalah yang raw-copy dibuat untuk
          // dihindari, lihat StorageService.rawPathFor). Lebih aman gagal
          // jelas di sini; foto tetap ada dengan watermark placeholder.
          throw Exception(
              'File sumber watermark tidak ditemukan: $sourcePath (raw copy hilang)');
        }

        Uint8List? logoBytes;
        if (_wmSettings.hasLogo) {
          final logoFile = File(_wmSettings.logoPath!);
          if (await logoFile.exists()) {
            logoBytes = await logoFile.readAsBytes();
          }
        }
        await WatermarkService.burn(
          sourcePath: sourcePath,
          destPath: destPath,
          lines: [
            DateFormat('dd/MM/yyyy HH:mm:ss').format(timestamp),
            locationText,
            if (_wmSettings.operatorName.isNotEmpty)
              'Operator: ${_wmSettings.operatorName}',
          ],
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
      // Selalu resolve normal di sini (error sudah disalurkan lewat
      // `completer` di atas) supaya antrian tetap lanjut memproses burn
      // berikutnya walau burn ini gagal.
    });
    return completer.future;
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

  Future<bool> _ensureGalleryPermission() async {
    var status = await Permission.photos.status;
    if (status.isGranted || status.isLimited) return true;

    status = await Permission.photos.request();
    if (status.isGranted || status.isLimited) return true;

    if (status.isPermanentlyDenied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Izin galeri ditolak permanen — aktifkan manual di Pengaturan'),
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

  Future<bool> _showPreviewAndConfirm(String path) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PhotoPreviewScreen(imagePath: path),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('Ambil Foto'),
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
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: AppTheme.accentOrange.withOpacity(0.1),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppTheme.accentOrange.withOpacity(0.4),
                    width: 2,
                  ),
                ),
                child: const Icon(Icons.camera_alt, size: 52, color: AppTheme.accentOrange),
              ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),
              const Gap(24),
              Text(
                _photoCount == 0 ? 'Siap Ambil Foto' : '$_photoCount foto tersimpan',
                style: Theme.of(context).textTheme.titleLarge,
              ).animate().fadeIn(delay: 100.ms),
              const Gap(8),
              Text(
                'Foto otomatis disertai timestamp & GPS',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ).animate().fadeIn(delay: 200.ms),
              const Gap(48),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isSaving ? null : _takePhoto,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2))
                      : const Icon(Icons.camera_alt, size: 22),
                  label: Text(_isSaving ? 'Menyimpan...' : 'Ambil Foto Kamera'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentOrange,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
              ).animate().fadeIn(delay: 250.ms),
              const Gap(14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _isSaving ? null : _pickFromGallery,
                  icon: const Icon(Icons.photo_library_outlined, size: 20),
                  label: const Text('Pilih dari Galeri'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.accentOrange,
                    side: BorderSide(color: AppTheme.accentOrange.withOpacity(0.6)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ).animate().fadeIn(delay: 300.ms),
              const Gap(32),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: AppTheme.accentBlue),
                    Gap(10),
                    Expanded(
                      child: Text(
                        'Setiap foto otomatis dicatat: waktu, koordinat GPS, & nama lokasi',
                        style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn(delay: 350.ms),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoPreviewScreen extends StatelessWidget {
  final String imagePath;

  const _PhotoPreviewScreen({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Image.file(File(imagePath), fit: BoxFit.contain),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.replay, color: Colors.white),
                      label: const Text('Ambil Ulang', style: TextStyle(color: Colors.white)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white54),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                  const Gap(12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.of(context).pop(true),
                      icon: const Icon(Icons.check, color: Colors.black),
                      label: const Text('Gunakan Foto'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentOrange,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: const TextStyle(fontWeight: FontWeight.w700),
                      ),
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
