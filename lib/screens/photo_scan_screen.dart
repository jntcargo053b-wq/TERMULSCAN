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

class _PhotoScanScreenState extends State<PhotoScanScreen> {
  final _picker = ImagePicker();
  final _storage = StorageService();
  final _loc = LocationService();
  final _wmSettings = WatermarkSettings();

  bool _isSaving = false;
  int _photoCount = 0;
  bool _locationGranted = false;

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
    // Idempotent — aman dipanggil lagi walau sudah di-load dari HomeScreen.
    _wmSettings.load();
  }

  Future<void> _checkLocationPermission() async {
    final status = await Permission.location.status;
    if (!status.isGranted) {
      final result = await Permission.location.request();
      setState(() => _locationGranted = result.isGranted);
    } else {
      setState(() => _locationGranted = true);
    }
  }

  Future<void> _takePhoto() async {
    // Pastikan izin lokasi sudah diberikan
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

      // Tampilkan preview hasil jepretan dulu — user bisa 'Ambil Ulang'
      // sebelum foto benar-benar disimpan ke storage.
      final confirmed = await _showPreviewAndConfirm(xfile.path);
      if (!mounted) return;
      if (!confirmed) {
        // Ambil ulang: hapus file sementara hasil jepretan yang dibatalkan,
        // lalu buka kamera lagi.
        _deleteTempFile(xfile.path);
        await _takePhoto();
        return;
      }

      setState(() => _isSaving = true);

      // Simpan foto ke penyimpanan permanen — hanya rename file, tidak menunggu GPS
      final savedPath = await _storage.savePhoto(xfile.path);
      final capturedAt = DateTime.now();

      // Simpan salinan mentah dulu sebelum watermark dibakar — dipakai
      // untuk render ulang watermark begitu lokasi resolve di background,
      // tanpa menumpuk watermark lama+baru.
      await _storage.savePhotoRawCopy(xfile.path, savedPath);

      // Bakar watermark tahap pertama: waktu, operator, logo. Lokasi belum
      // tersedia (masih dicari di background) — ditandai placeholder dulu,
      // nanti di-render ulang begitu koordinat/alamat ketemu.
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

      // GPS & reverse geocoding sepenuhnya di background — tidak menghalangi capture berikutnya
      // ignore: unawaited_futures
      _resolveLocationInBackground(entry.id);
    } catch (e) {
      setState(() => _isSaving = false);
      _showError('Gagal ambil foto: $e');
    }
  }

  /// Ambil koordinat & alamat setelah entry sudah tersimpan, lalu update entry.
  /// Dijalankan tanpa di-await dari alur capture supaya UI tidak menunggu GPS.
  Future<void> _resolveLocationInBackground(String entryId) async {
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

    final saved = await _storage.getEntry(entryId);
    if (saved != null) {
      final updated = saved.copyWith(latitude: coords.lat, longitude: coords.lng);
      await _storage.update(updated);
      // Render ulang watermark dari salinan mentah dengan koordinat yang
      // baru ketemu (alamat menyusul di bawah kalau reverse-geocode sukses).
      await _burnWatermark(
        sourcePath: _storage.rawPathFor(updated.value),
        destPath: updated.value,
        timestamp: updated.timestamp,
        locationText: updated.coordinatesString,
      );
      await FileImage(File(updated.value)).evict();
    }

    await _loc.updateAddressForEntry(
      entryId: entryId,
      lat: coords.lat!,
      lng: coords.lng!,
      accuracy: coords.accuracy,
      onAddressReceived: (id, address) async {
        final currentEntry = await _storage.getEntry(id);
        if (currentEntry != null) {
          final updated = currentEntry.copyWith(locationName: address);
          await _storage.update(updated);
          // Render ulang lagi begitu alamat human-readable ketemu, supaya
          // watermark tampil alamat, bukan cuma koordinat mentah.
          await _burnWatermark(
            sourcePath: _storage.rawPathFor(updated.value),
            destPath: updated.value,
            timestamp: updated.timestamp,
            locationText: address,
          );
          await FileImage(File(updated.value)).evict();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('📍 Lokasi terdeteksi: $address'),
                duration: const Duration(seconds: 2),
                backgroundColor: Colors.green.shade700,
              ),
            );
          }
        }
      },
    );
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
        // Pilih ulang: buka galeri lagi, file asal di galeri tidak disentuh.
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

      // GPS & reverse geocoding di background — tidak menghalangi UI
      // ignore: unawaited_futures
      _resolveLocationInBackground(entry.id);
    } catch (e) {
      setState(() => _isSaving = false);
      _showError('Gagal memilih foto: $e');
    }
  }

  /// Susun baris teks watermark dari data yang tersedia lalu bakar ke foto.
  /// Dipakai dua kali per foto: sekali langsung setelah capture (tanpa
  /// lokasi), sekali lagi begitu GPS/alamat resolve di background.
  Future<void> _burnWatermark({
    required String sourcePath,
    required String destPath,
    required DateTime timestamp,
    required String locationText,
  }) async {
    try {
      Uint8List? logoBytes;
      if (_wmSettings.hasLogo) {
        logoBytes = await File(_wmSettings.logoPath!).readAsBytes();
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
    } catch (e) {
      // Watermark gagal bukan alasan untuk gagalkan penyimpanan foto —
      // foto tanpa watermark tetap lebih baik daripada foto hilang.
      debugPrint('Watermark error: $e');
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

  /// Ekspor foto yang sudah tersimpan (internal) ke galeri publik perangkat.
  /// Sebelumnya layar ini tidak pernah meminta Permission.photos sama
  /// sekali (cuma Permission.location) — saveFile() ke galeri jadi gagal
  /// diam-diam di banyak device karena izinnya memang belum pernah diminta.
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

  /// Pastikan izin galeri granted sebelum menulis; kalau permanently
  /// denied, arahkan ke App Settings lewat snackbar dengan aksi langsung.
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

  /// Tampilkan foto hasil jepretan/pilihan full-screen dan minta konfirmasi
  /// user sebelum benar-benar disimpan ke storage & entry list.
  /// Return true kalau user pilih 'Gunakan Foto', false kalau 'Ambil Ulang'.
  Future<bool> _showPreviewAndConfirm(String path) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PhotoPreviewScreen(imagePath: path),
      ),
    );
    return result ?? false;
  }

  /// Bersihkan file sementara di cache picker saat user memilih ambil ulang,
  /// supaya tidak menumpuk sampah di cache directory.
  void _deleteTempFile(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Abaikan — bukan fatal, cache OS akan dibersihkan sendiri nanti.
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(backgroundColor: AppTheme.error, content: Text(msg)),
    );
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
                child: const Icon(Icons.camera_alt,
                    size: 52, color: AppTheme.accentOrange),
              ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),
              const Gap(24),
              Text(
                _photoCount == 0
                    ? 'Siap Ambil Foto'
                    : '$_photoCount foto tersimpan',
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
                    textStyle: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
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
                    side: BorderSide(
                        color: AppTheme.accentOrange.withOpacity(0.6)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ).animate().fadeIn(delay: 300.ms),
              const Gap(32),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: AppTheme.accentBlue),
                    Gap(10),
                    Expanded(
                      child: Text(
                        'Setiap foto otomatis dicatat: waktu, koordinat GPS, & nama lokasi',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 12),
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

/// Layar preview full-screen sebelum foto di-commit ke storage.
/// Muncul setelah shutter native camera / pemilihan galeri, supaya user
/// bisa cek hasilnya dulu dan pilih 'Ambil Ulang' kalau kurang pas.
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
                      label: const Text('Ambil Ulang',
                          style: TextStyle(color: Colors.white)),
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
