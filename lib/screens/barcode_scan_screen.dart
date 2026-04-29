import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:TERMULScan/models/scan_entry.dart';
import 'package:TERMULScan/services/storage_service.dart';
import 'package:TERMULScan/services/location_service.dart';
import 'watermark_settings.dart';
import 'watermark_settings_sheet.dart';

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
    _wmSettings.load(); // muat pengaturan watermark tersimpan
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.location,
      Permission.camera,
      Permission.photos,
      Permission.storage,
    ].request();
  }

  // ── PENGATURAN WATERMARK ─────────────────────────────────────────────────
  void _openWatermarkSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const WatermarkSettingsSheet(),
    ).then((_) => setState(() {})); // refresh UI setelah tutup
  }

  // ── AUTO SCAN dari kamera ────────────────────────────────────────────────
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
      final loc = await _loc.getLocation();

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.barcode,
        value: code,
        barcodeFormat: format,
        timestamp: DateTime.now(),
        latitude: loc.lat,
        longitude: loc.lng,
        locationName: loc.address,
      );

      await _storage.add(entry);
      setState(() => _scanCount++);

      if (mounted) await _takePhotoAndShow(entry);
    } catch (e) {
      debugPrint("Error _onDetect: $e");
      if (mounted) setState(() { _scanning = true; _lastCode = null; });
    } finally {
      if (mounted) setState(() => _isSaving = false);
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
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
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
      final loc = await _loc.getLocation();

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.barcode,
        value: code,
        barcodeFormat: 'MANUAL',
        timestamp: DateTime.now(),
        latitude: loc.lat,
        longitude: loc.lng,
        locationName: loc.address,
      );

      await _storage.add(entry);
      setState(() => _scanCount++);

      if (mounted) await _takePhotoAndShow(entry);
    } catch (e) {
      debugPrint("Error _processManualCode: $e");
      if (mounted) setState(() { _scanning = true; _lastCode = null; });
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── FOTO & WATERMARK ─────────────────────────────────────────────────────
  Future<void> _takePhotoAndShow(ScanEntry entry) async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
    );

    if (file == null) {
      if (mounted) setState(() { _scanning = true; _lastCode = null; });
      return;
    }

    try {
      final wmPath = await _addWatermark(file.path, entry);
      final saved = await _storage.savePhoto(wmPath, name: entry.value);
      try { await File(wmPath).delete(); } catch (_) {}

      final photoEntry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: saved,
        timestamp: DateTime.now(),
        latitude: entry.latitude,
        longitude: entry.longitude,
        locationName: entry.locationName,
      );
      await _storage.add(photoEntry);

      if (mounted) _showResult(entry, photoPath: saved);
    } catch (e) {
      debugPrint("Error _takePhotoAndShow: $e");
      if (mounted) setState(() { _scanning = true; _lastCode = null; });
    }
  }

  Future<bool> _saveToGallery(String filePath, ScanEntry entry) async {
    try {
      PermissionStatus status = await Permission.photos.request();
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      if (!status.isGranted) return false;

      final bytes = await File(filePath).readAsBytes();
      final dir = Directory('/storage/emulated/0/Pictures/TERMULScan');
      await dir.create(recursive: true);
      final cleanValue = entry.value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final fileName = '${cleanValue}_${DateTime.now().millisecondsSinceEpoch}.png';
      await File('${dir.path}/$fileName').writeAsBytes(bytes);
      return true;
    } catch (e) {
      debugPrint("Error _saveToGallery: $e");
      return false;
    }
  }

  Future<ui.Image> _resizeImage(ui.Image src, {int maxSize = 1280}) async {
    final w = src.width;
    final h = src.height;
    if (w <= maxSize && h <= maxSize) return src;

    final scale = maxSize / (w > h ? w : h);
    final newW = (w * scale).toInt();
    final newH = (h * scale).toInt();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()),
    );
    canvas.drawImageRect(
      src,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()),
      Paint(),
    );
    final pic = recorder.endRecording();
    return pic.toImage(newW, newH);
  }

  /// Load logo dari file dan decode ke ui.Image
  Future<ui.Image?> _loadLogoImage() async {
    try {
      if (!_wmSettings.hasLogo) return null;
      final bytes = await File(_wmSettings.logoPath!).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 160);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      debugPrint("Error load logo: $e");
      return null;
    }
  }

  Future<String> _addWatermark(String imagePath, ScanEntry entry) async {
    // Load foto
    final imageBytes = await File(imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final srcImage = frame.image;

    final resized = await _resizeImage(srcImage);
    if (srcImage != resized) srcImage.dispose();

    final width = resized.width.toDouble();
    final height = resized.height.toDouble();

    // Load logo (jika ada)
    final logoImage = await _loadLogoImage();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
    canvas.drawImage(resized, Offset.zero, Paint());

    // ── Teks watermark ──────────────────────────────────────────────────
    final dateStr = DateFormat('dd/MM/yyyy HH:mm:ss').format(entry.timestamp);
    final gpsStr = entry.locationName ??
        (entry.latitude != null
            ? '${entry.latitude!.toStringAsFixed(5)}, ${entry.longitude!.toStringAsFixed(5)}'
            : 'GPS tidak tersedia');
    final isManual = entry.barcodeFormat == 'MANUAL';

    final lines = <Map<String, dynamic>>[
      if (_wmSettings.operatorName.isNotEmpty)
        {'text': _wmSettings.operatorName, 'color': const Color(0xFFFFD700)}, // emas
      if (isManual)
        {'text': '[INPUT MANUAL]', 'color': const Color(0xFFFFAA00)},
      {'text': entry.value, 'color': Colors.white},
      {'text': dateStr, 'color': const Color(0xFFCCCCCC)},
      {'text': gpsStr, 'color': const Color(0xFFCCCCCC)},
    ];

    final fontSize = width * 0.03;
    final padding = width * 0.04;
    final rowHeight = fontSize * 1.65;

    // Hitung tinggi logo
    final logoSize = width * 0.1;
    final bgHeight = (lines.length * rowHeight) + (padding * 2);
    final finalBgHeight = logoImage != null
        ? (bgHeight > logoSize + padding * 2 ? bgHeight : logoSize + padding * 2)
        : bgHeight;

    // Background strip hitam transparan
    canvas.drawRect(
      Rect.fromLTWH(0, height - finalBgHeight, width, finalBgHeight),
      Paint()..color = const Color(0xCC000000),
    );

    // Gambar logo di KANAN BAWAH
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

    // Gambar teks baris per baris
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

    // Finalize
    final picture = recorder.endRecording();
    final img = await picture.toImage(width.toInt(), height.toInt());
    resized.dispose();

    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();

    final pngBytes = byteData!.buffer.asUint8List();
    final newPath =
        '${File(imagePath).parent.path}/wm_${DateTime.now().millisecondsSinceEpoch}.png';
    await File(newPath).writeAsBytes(pngBytes);
    return newPath;
  }

  void _showResult(ScanEntry entry, {String? photoPath}) {
    showModalBottomSheet(
      context: context,
      isDismissible: true,
      isScrollControlled: true,
      builder: (_) => _ResultSheet(
        entry: entry,
        photoPath: photoPath,
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
  }

  // ── BUILD ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Scanner ($_scanCount)"),
        actions: [
          // Tombol pengaturan watermark
          IconButton(
            onPressed: _openWatermarkSettings,
            icon: Stack(
              children: [
                const Icon(Icons.tune, color: Colors.white),
                // Indikator hijau jika operator sudah diisi
                if (_wmSettings.operatorName.isNotEmpty || _wmSettings.hasLogo)
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
          // Kamera scanner
          MobileScanner(onDetect: _onDetect),

          // Info watermark aktif (nama operator)
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

          // Tombol Input Manual
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

          // Loading overlay
          if (_isSaving)
            const ColoredBox(
              color: Color(0x88000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    Gap(12),
                    Text("Memproses...",
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

// ── Result Sheet ──────────────────────────────────────────────────────────
class _ResultSheet extends StatefulWidget {
  final ScanEntry entry;
  final String? photoPath;
  final StorageService storage;
  final Future<bool> Function(String, ScanEntry) onSaveToGallery;

  const _ResultSheet({
    required this.entry,
    required this.photoPath,
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

  bool get _isManual => widget.entry.barcodeFormat == 'MANUAL';

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20, 16, 20,
        MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Badge MANUAL
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

          // Preview foto
          if (widget.photoPath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(widget.photoPath!),
                height: 200,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          const Gap(12),

          // Nilai barcode
          Text(
            widget.entry.value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const Gap(4),
          Text(
            DateFormat('dd/MM/yyyy HH:mm:ss').format(widget.entry.timestamp),
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const Gap(4),
          Text(
            widget.entry.coordinatesString,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const Gap(12),

          // Tambah catatan
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
                            final updated = widget.entry.copyWith(note: note);
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

          // Tombol Simpan & Scan Lagi
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (_isSaved || _isSaving || widget.photoPath == null)
                      ? null
                      : () async {
                          setState(() => _isSaving = true);
                          final success = await widget.onSaveToGallery(
                              widget.photoPath!, widget.entry);
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
                      ? "Menyimpan..."
                      : _isSaved ? "Tersimpan" : "Simpan"),
                ),
              ),
              const Gap(10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text("Scan Lagi"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
