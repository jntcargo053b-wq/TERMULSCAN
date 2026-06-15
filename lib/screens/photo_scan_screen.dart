import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/scan_entry.dart';
import '../services/location_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

class PhotoScanScreen extends StatefulWidget {
  const PhotoScanScreen({super.key});

  @override
  State<PhotoScanScreen> createState() => _PhotoScanScreenState();
}

class _PhotoScanScreenState extends State<PhotoScanScreen> {
  final _picker = ImagePicker();
  final _storage = StorageService();
  final _loc = LocationService();

  bool _isSaving = false;
  int _photoCount = 0;
  bool _locationGranted = false;

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
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

      setState(() => _isSaving = true);
      HapticFeedback.mediumImpact();

      // Jalankan paralel: ambil koordinat dan simpan foto sementara
      final coordsFuture = _loc.getCoordinatesOnly();
      final savedPathFuture = _storage.savePhoto(xfile.path);

      final savedPath = await savedPathFuture;
      final coords = await coordsFuture;

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: savedPath,
        timestamp: DateTime.now(),
        latitude: coords.lat,
        longitude: coords.lng,
        locationName: null,
      );
      await _storage.add(entry);

      setState(() {
        _photoCount++;
        _isSaving = false;
      });

      // Reverse geocoding asinkron (tidak menghalangi UI)
      if (coords.lat != null && coords.lng != null) {
        // ignore: unawaited_futures
        _loc.updateAddressForEntry(
          entryId: entry.id,
          lat: coords.lat!,
          lng: coords.lng!,
          onAddressReceived: (id, address) async {
            final currentEntry = await _storage.getEntry(id);
            if (currentEntry != null) {
              final updated = currentEntry.copyWith(locationName: address);
              await _storage.update(updated);
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
      } else {
        // Tampilkan peringatan jika GPS tidak tersedia
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ GPS tidak tersedia, foto tetap tersimpan tanpa lokasi'),
              duration: Duration(seconds: 2),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }

      if (mounted) _showSuccess(entry);
    } catch (e) {
      setState(() => _isSaving = false);
      _showError('Gagal ambil foto: $e');
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

      setState(() => _isSaving = true);

      final coordsFuture = _loc.getCoordinatesOnly();
      final savedPathFuture = _storage.savePhoto(xfile.path);

      final savedPath = await savedPathFuture;
      final coords = await coordsFuture;

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: savedPath,
        timestamp: DateTime.now(),
        latitude: coords.lat,
        longitude: coords.lng,
        locationName: null,
      );
      await _storage.add(entry);

      setState(() {
        _photoCount++;
        _isSaving = false;
      });

      if (coords.lat != null && coords.lng != null) {
        // ignore: unawaited_futures
        _loc.updateAddressForEntry(
          entryId: entry.id,
          lat: coords.lat!,
          lng: coords.lng!,
          onAddressReceived: (id, address) async {
            final currentEntry = await _storage.getEntry(id);
            if (currentEntry != null) {
              await _storage.update(currentEntry.copyWith(locationName: address));
            }
          },
        );
      }

      if (mounted) _showSuccess(entry);
    } catch (e) {
      setState(() => _isSaving = false);
      _showError('Gagal memilih foto: $e');
    }
  }

  void _showSuccess(ScanEntry entry) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 2),
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
      ),
    );
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
