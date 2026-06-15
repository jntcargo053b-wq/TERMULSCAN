import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:termulscan/models/scan_entry.dart';
import 'package:termulscan/services/storage_service.dart';
import 'package:termulscan/services/location_service.dart';
import 'watermark_settings.dart';
import 'watermark_settings_sheet.dart';

// ── Isolate payload untuk watermark ──────────────────────────────────────
class _WatermarkTask {
  final String imagePath;
  final String outputPath;
  final String barcodeValue;
  final String? barcodeFormat;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String operatorName;
  final String? logoPath;
  final SendPort replyTo;

  const _WatermarkTask({
    required this.imagePath,
    required this.outputPath,
    required this.barcodeValue,
    required this.barcodeFormat,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.locationName,
    required this.operatorName,
    required this.logoPath,
    required this.replyTo,
  });
}

/// Entry-point isolate — harus top-level function.
void _watermarkIsolate(_WatermarkTask task) async {
  try {
    final result = await _renderWatermark(task);
    task.replyTo.send(result);
  } catch (e) {
    task.replyTo.send(null);
  }
}

/// Fungsi render watermark (berjalan di isolate terpisah).
Future<String?> _renderWatermark(_WatermarkTask task) async {
  final imageBytes = await File(task.imagePath).readAsBytes();
  final codec = await ui.instantiateImageCodec(imageBytes);
  final frame = await codec.getNextFrame();
  final srcImage = frame.image;

  final width = srcImage.width.toDouble();
  final height = srcImage.height.toDouble();

  // Load logo jika ada
  ui.Image? logoImage;
  if (task.logoPath != null) {
    try {
      final logoBytes = await File(task.logoPath!).readAsBytes();
      final logoCodec = await ui.instantiateImageCodec(logoBytes, targetWidth: 160);
      final logoFrame = await logoCodec.getNextFrame();
      logoImage = logoFrame.image;
    } catch (_) {}
  }

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
  canvas.drawImage(srcImage, Offset.zero, Paint());

  // Teks watermark
  final dateStr = DateFormat('dd/MM/yyyy HH:mm:ss').format(task.timestamp);
  final gpsStr = task.locationName ??
      (task.latitude != null
          ? '${task.latitude!.toStringAsFixed(5)}, ${task.longitude!.toStringAsFixed(5)}'
          : 'GPS tidak tersedia');
  final isManual = task.barcodeFormat == 'MANUAL';

  final lines = <Map<String, dynamic>>[
    if (task.operatorName.isNotEmpty)
      {'text': task.operatorName, 'color': const Color(0xFFFFD700)},
    if (isManual)
      {'text': '[INPUT MANUAL]', 'color': const Color(0xFFFFAA00)},
    {'text': task.barcodeValue, 'color': Colors.white},
    {'text': dateStr, 'color': const Color(0xFFCCCCCC)},
    {'text': gpsStr, 'color': const Color(0xFFCCCCCC)},
  ];

  final fontSize = width * 0.03;
  final padding = width * 0.04;
  final rowHeight = fontSize * 1.65;
  final logoSize = width * 0.1;
  final bgHeight = (lines.length * rowHeight) + (padding * 2);
  final finalBgHeight = logoImage != null
      ? (bgHeight > logoSize + padding * 2 ? bgHeight : logoSize + padding * 2)
      : bgHeight;

  // Background strip
  canvas.drawRect(
    Rect.fromLTWH(0, height - finalBgHeight, width, finalBgHeight),
    Paint()..color = const Color(0xCC000000),
  );

  // Logo kanan bawah
  if (logoImage != null) {
    final logoW = logoImage.width.toDouble();
    final logoH = logoImage.height.toDouble();
    final scale = logoSize / (logoW > logoH ? logoW : logoH);
    final drawW = logoW * scale;
    final drawH = logoH * scale;
    final logoLeft = width - padding - drawW;
    final logoTop = height - finalBgHeight + (finalBgHeight - drawH) / 2;

    canvas.drawImageRect(
      logoImage,
      Rect.fromLTWH(0, 0, logoW, logoH),
      Rect.fromLTWH(logoLeft, logoTop, drawW, drawH),
      Paint()..filterQuality = FilterQuality.high,
    );
    logoImage.dispose();
  }

  // Teks baris per baris
  final textMaxWidth = logoImage != null
      ? width - (padding * 2) - (logoSize + padding)
      : width - (padding * 2);

  for (int i = 0; i < lines.length; i++) {
    final tp = TextPainter(
      text: TextSpan(
        text: lines[i]['text'] as String,
        style: TextStyle(
          color: lines[i]['color'] as Color,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          shadows: const [Shadow(blurRadius: 2, color: Colors.black)],
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: textMaxWidth);

    tp.paint(
      canvas,
      Offset(
        padding,
        (height - finalBgHeight + padding) + (i * rowHeight),
      ),
    );
  }

  final picture = recorder.endRecording();
  final img = await picture.toImage(width.toInt(), height.toInt());
  srcImage.dispose();

  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();

  final pngBytes = byteData!.buffer.asUint8List();
  await File(task.outputPath).writeAsBytes(pngBytes);
  return task.outputPath;
}

// ═════════════════════════════════════════════════════════════════════════
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  bool _scanning = true;
  bool _isSaving = false;
  String? _lastCode;
  int _scanCount = 0;

  final StorageService _storage = StorageService();
  final LocationService _loc = LocationService();
  final ImagePicker _picker = ImagePicker();
  final WatermarkSettings _wmSettings = WatermarkSettings();

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _wmSettings.load();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.location,
      Permission.camera,
      Permission.photos,
      Permission.storage,
    ].request();
  }

  void _openWatermarkSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const WatermarkSettingsSheet(),
    ).then((_) => setState(() {}));
  }

  // ── AUTO SCAN ────────────────────────────────────────────────────────────
  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!_scanning || _isSaving) return;

    final barcode = capture.barcodes.isNotEmpty ? capture.barcodes.first : null;
    if (barcode == null || barcode.rawValue == null) return;

    final code = barcode.rawValue!;
    final format = barcode.format.name;
    if (code == _lastCode) return;

    setState(() {
      _scanning = false;
      _lastCode = code;
      _isSaving = true;
    });

    try {
      HapticFeedback.mediumImpact();

      // Simpan barcode DULU tanpa GPS (akan diupdate nanti)
      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.barcode,
        value: code,
        barcodeFormat: format,
        timestamp: DateTime.now(),
        latitude: null,
        longitude: null,
        locationName: null,
      );
      await _storage.add(entry);
      setState(() => _scanCount++);

      if (mounted) {
        _takePhotoAndShow(entry).catchError((e) {
          debugPrint('Error _takePhotoAndShow: $e');
          if (mounted) setState(() {
            _isSaving = false;
            _scanning = true;
            _lastCode = null;
          });
        });
      }
    } catch (e) {
      debugPrint('Error _onDetect: $e');
      if (mounted) setState(() {
        _isSaving = false;
        _scanning = true;
        _lastCode = null;
      });
    }
  }

  // ── INPUT MANUAL ─────────────────────────────────────────────────────────
  void _showManualInput() {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Gap(16),
            const Row(
              children: [
                Icon(Icons.keyboard, color: Colors.amber, size: 20),
                Gap(8),
                Text('Input Manual',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    )),
              ],
            ),
            const Gap(4),
            const Text(
              'Ketik atau paste barcode jika kamera gagal membaca',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const Gap(16),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Contoh: 8991234567890',
                hintStyle: const TextStyle(color: Colors.grey),
                filled: true,
                fillColor: const Color(0xFF2A2A2A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Colors.amber, width: 1.5),
                ),
                prefixIcon: const Icon(Icons.qr_code, color: Colors.grey),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear, color: Colors.grey, size: 18),
                  onPressed: () => controller.clear(),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14,
                ),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (val) {
                if (val.trim().isNotEmpty) {
                  Navigator.pop(ctx);
                  _processManualCode(val.trim());
                }
              },
            ),
            const Gap(16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  final val = controller.text.trim();
                  if (val.isNotEmpty) {
                    Navigator.pop(ctx);
                    _processManualCode(val);
                  }
                },
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Konfirmasi',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _processManualCode(String code) async {
    if (_isSaving) return;

    setState(() {
      _scanning = false;
      _lastCode = code;
      _isSaving = true;
    });

    try {
      HapticFeedback.mediumImpact();

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.barcode,
        value: code,
        barcodeFormat: 'MANUAL',
        timestamp: DateTime.now(),
        latitude: null,
        longitude: null,
        locationName: null,
      );
      await _storage.add(entry);
      setState(() => _scanCount++);

      if (mounted) {
        _takePhotoAndShow(entry).catchError((e) {
          debugPrint('Error _takePhotoAndShow: $e');
          if (mounted) setState(() {
            _isSaving = false;
            _scanning = true;
            _lastCode = null;
          });
        });
      }
    } catch (e) {
      debugPrint('Error _processManualCode: $e');
      if (mounted) setState(() {
        _isSaving = false;
        _scanning = true;
        _lastCode = null;
      });
    }
  }

  // ── FOTO & WATERMARK ─────────────────────────────────────────────────────
  Future<void> _takePhotoAndShow(ScanEntry entry) async {
    // Ambil foto dari kamera (sudah dikompres)
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1024,
      imageQuality: 65,
    );

    if (file == null) {
      if (mounted) setState(() {
        _isSaving = false;
        _scanning = true;
        _lastCode = null;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _isSaving = false);

    // 1. Dapatkan koordinat CEPAT (tanpa reverse geocoding)
    final coords = await _loc.getCoordinatesOnly();

    // 2. Update entry dengan koordinat (address masih null)
    ScanEntry updatedEntry = entry.copyWith(
      latitude: coords.lat,
      longitude: coords.lng,
      locationName: null,
    );
    await _storage.update(updatedEntry);

    // 3. Tampilkan result sheet dengan status "memproses"
    final stateNotifier = ValueNotifier<_ResultState>(
      _ResultState(entry: updatedEntry, photoPath: null, processing: true),
    );

    showModalBottomSheet(
      context: context,
      isDismissible: true,
      isScrollControlled: true,
      builder: (_) => _ResultSheet(
        notifier: stateNotifier,
        storage: _storage,
        onSaveToGallery: _saveToGallery,
      ),
    ).then((_) {
      if (mounted) {
        setState(() {
          _scanning = true;
          _lastCode = null;
        });
      }
    });

    // 4. Jalankan reverse geocoding di BACKGROUND (tanpa await)
    if (coords.lat != null && coords.lng != null) {
      // ignore: unawaited_futures
      _loc.updateAddressForEntry(
        entryId: updatedEntry.id,
        lat: coords.lat!,
        lng: coords.lng!,
        onAddressReceived: (id, address) async {
          final currentEntry = await _storage.getEntry(id);
          if (currentEntry != null) {
            final withAddress = currentEntry.copyWith(locationName: address);
            await _storage.update(withAddress);
            if (mounted) {
              stateNotifier.value = _ResultState(
                entry: withAddress,
                photoPath: stateNotifier.value.photoPath,
                processing: stateNotifier.value.processing,
                error: stateNotifier.value.error,
              );
            }
          }
        },
      );
    }

    // 5. Proses watermark dan simpan foto (tidak menunggu address)
    try {
      final wmPath = await _addWatermarkInIsolate(
        file.path,
        updatedEntry,
      );
      final savedPhotoPath = await _storage.savePhoto(wmPath, name: entry.value);

      // Buat entri foto
      final photoEntry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: savedPhotoPath,
        timestamp: DateTime.now(),
        latitude: coords.lat,
        longitude: coords.lng,
        locationName: null,
      );
      await _storage.add(photoEntry);

      // Update sheet dengan hasil foto
      stateNotifier.value = _ResultState(
        entry: updatedEntry,
        photoPath: savedPhotoPath,
        processing: false,
      );
    } catch (e) {
      debugPrint('Error watermark/save: $e');
      stateNotifier.value = _ResultState(
        entry: updatedEntry,
        photoPath: null,
        processing: false,
        error: true,
      );
    }
  }

  /// Jalankan watermark di Isolate agar UI tidak freeze
  Future<String> _addWatermarkInIsolate(String imagePath, ScanEntry entry) async {
    final receivePort = ReceivePort();
    final outputPath =
        '${File(imagePath).parent.path}/wm_${DateTime.now().millisecondsSinceEpoch}.png';

    final task = _WatermarkTask(
      imagePath: imagePath,
      outputPath: outputPath,
      barcodeValue: entry.value,
      barcodeFormat: entry.barcodeFormat,
      timestamp: entry.timestamp,
      latitude: entry.latitude,
      longitude: entry.longitude,
      locationName: entry.locationName,
      operatorName: _wmSettings.operatorName,
      logoPath: _wmSettings.hasLogo ? _wmSettings.logoPath : null,
      replyTo: receivePort.sendPort,
    );

    await Isolate.spawn(_watermarkIsolate, task);
    final result = await receivePort.first as String?;
    receivePort.close();

    if (result == null) throw Exception('Watermark isolate gagal');
    return result;
  }

  /// ✅ FUNGSI SAVE TO GALLERY - menggunakan image_gallery_saver
  Future<bool> _saveToGallery(String filePath, ScanEntry entry) async {
    try {
      final result = await ImageGallerySaver.saveFile(filePath);
      
      if (result != null && result['isSuccess'] == true) {
        debugPrint('✅ Berhasil menyimpan ke galeri: $filePath');
        return true;
      } else {
        debugPrint('⚠️ Gagal menyimpan ke galeri: $filePath');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error _saveToGallery: $e');
      return false;
    }
  }

  // ── BUILD ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Scanner ($_scanCount)'),
        actions: [
          IconButton(
            onPressed: _openWatermarkSettings,
            icon: Stack(
              children: [
                const Icon(Icons.tune, color: Colors.white),
                if (_wmSettings.operatorName.isNotEmpty ||
                    _wmSettings.hasLogo)
                  Positioned(
                    right: 0, top: 0,
                    child: Container(
                      width: 8, height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.amber,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            tooltip: 'Pengaturan Watermark',
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),

          if (_wmSettings.operatorName.isNotEmpty && !_isSaving)
            Positioned(
              top: 12,
              left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xAA000000),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.amber.withOpacity(0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person, color: Colors.amber, size: 12),
                      const Gap(5),
                      Text(
                        _wmSettings.operatorName,
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_wmSettings.hasLogo) ...[
                        const Gap(8),
                        const Icon(Icons.business, color: Colors.white54, size: 12),
                      ],
                    ],
                  ),
                ),
              ),
            ),

          if (!_isSaving)
            Positioned(
              bottom: 40,
              left: 0, right: 0,
              child: Center(
                child: TextButton.icon(
                  onPressed: _showManualInput,
                  icon: const Icon(Icons.keyboard, color: Colors.white70, size: 18),
                  label: const Text(
                    'Input Manual',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0x88000000),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: const BorderSide(color: Colors.white24),
                    ),
                  ),
                ),
              ),
            ),

          if (_isSaving)
            const ColoredBox(
              color: Color(0x88000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    Gap(12),
                    Text('Memproses...',
                        style: TextStyle(color: Colors.white, fontSize: 16)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Result State (untuk live-update sheet) ──────────────────────────────
class _ResultState {
  final ScanEntry entry;
  final String? photoPath;
  final bool processing;
  final bool error;

  const _ResultState({
    required this.entry,
    required this.photoPath,
    required this.processing,
    this.error = false,
  });
}

// ── Result Sheet ──────────────────────────────────────────────────────────
class _ResultSheet extends StatefulWidget {
  final ValueNotifier<_ResultState> notifier;
  final StorageService storage;
  final Future<bool> Function(String, ScanEntry) onSaveToGallery;

  const _ResultSheet({
    required this.notifier,
    required this.storage,
    required this.onSaveToGallery,
  });

  @override
  State<_ResultSheet> createState() => _ResultSheetState();
}

class _ResultSheetState extends State<_ResultSheet> {
  final TextEditingController _noteController = TextEditingController();
  bool _isSaved = false;
  bool _isSaving = false;
  bool _isEditingNote = false;
  bool _noteSaved = false;

  bool get _isManual => widget.notifier.value.entry.barcodeFormat == 'MANUAL';

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_ResultState>(
      valueListenable: widget.notifier,
      builder: (context, state, _) {
        final entry = state.entry;
        final photoPath = state.photoPath;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20, 16, 20,
            MediaQuery.of(context).viewInsets.bottom + 32,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              if (_isManual)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.amber.withOpacity(0.4)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.keyboard, color: Colors.amber, size: 13),
                      Gap(5),
                      Text('Input Manual',
                          style: TextStyle(
                            color: Colors.amber,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          )),
                    ],
                  ),
                ),

              if (photoPath != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(photoPath),
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                )
              else if (state.processing)
                Container(
                  height: 200,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 24, height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        Gap(8),
                        Text('Memproses foto & GPS...',
                            style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                )
              else if (state.error)
                Container(
                  height: 80,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(
                    child: Text('Gagal memproses foto',
                        style: TextStyle(color: Colors.red, fontSize: 12)),
                  ),
                ),
              const Gap(12),

              Text(
                entry.value,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const Gap(4),
              Text(
                DateFormat('dd/MM/yyyy HH:mm:ss').format(entry.timestamp),
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const Gap(4),
              Text(
                entry.coordinatesString,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const Gap(12),

              if (!_isEditingNote && !_noteSaved)
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _isEditingNote = true),
                    icon: const Icon(Icons.note_add_outlined, size: 18),
                    label: const Text('Tambah Catatan'),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: Colors.grey,
                    ),
                  ),
                ),

              if (_isEditingNote)
                Column(
                  children: [
                    TextField(
                      controller: _noteController,
                      autofocus: true,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: 'Tulis catatan...',
                        isDense: true,
                        contentPadding: const EdgeInsets.all(10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const Gap(8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => setState(() {
                              _isEditingNote = false;
                              _noteController.clear();
                            }),
                            child: const Text('Batal'),
                          ),
                        ),
                        const Gap(8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final note = _noteController.text.trim();
                              if (note.isNotEmpty) {
                                final updated = entry.copyWith(note: note);
                                await widget.storage.update(updated);
                              }
                              setState(() {
                                _isEditingNote = false;
                                _noteSaved = note.isNotEmpty;
                              });
                            },
                            child: const Text('Simpan Catatan'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

              if (_noteSaved)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green, size: 16),
                      const Gap(8),
                      Expanded(
                        child: Text(
                          _noteController.text,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() {
                          _noteSaved = false;
                          _isEditingNote = true;
                        }),
                        child: const Icon(Icons.edit, size: 16, color: Colors.grey),
                      ),
                    ],
                  ),
                ),

              const Gap(12),

              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: (_isSaved || _isSaving || photoPath == null)
                          ? null
                          : () async {
                              setState(() => _isSaving = true);
                              final success = await widget.onSaveToGallery(photoPath!, entry);
                              setState(() {
                                _isSaving = false;
                                _isSaved = success;
                              });
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(success
                                        ? '✓ Foto tersimpan ke galeri'
                                        : 'Gagal menyimpan — cek permission'),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              }
                            },
                      icon: _isSaving
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(_isSaved ? Icons.check : Icons.save_alt),
                      label: Text(_isSaving
                          ? 'Menyimpan...'
                          : _isSaved ? 'Tersimpan' : 'Simpan'),
                    ),
                  ),
                  const Gap(10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan Lagi'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
