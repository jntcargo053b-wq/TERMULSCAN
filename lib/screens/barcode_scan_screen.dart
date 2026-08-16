import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/location_service.dart';
import 'photo_scan_screen.dart';

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({Key? key}) : super(key: key);

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> with WidgetsBindingObserver {
  MobileScannerController? _controller;
  final _storage = StorageService();
  final _locationService = LocationService();

  /// Barcode yang barusan terdeteksi, menunggu keputusan user (Ambil Foto /
  /// Simpan Tanpa Foto / Scan Ulang). Selama ini tidak null, kamera
  /// di-pause dan onDetect diabaikan — tidak lagi auto-capture & auto-save
  /// begitu barcode kelihatan.
  Barcode? _detectedBarcode;

  /// Indikator loading khusus untuk aksi "Simpan Tanpa Foto" (fetch lokasi
  /// + simpan). Terpisah dari _detectedBarcode supaya tombol bisa nonaktif
  /// sementara tanpa menghilangkan panel konfirmasi.
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  void _initCamera() {
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      // Tidak perlu lagi returnImage: true — foto sekarang diambil lewat
      // kamera penuh di PhotoScanScreen (tombol "Ambil Foto"), bukan dari
      // frame scanner otomatis seperti alur sebelumnya.
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        if (_detectedBarcode == null) _controller?.start();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
        _controller?.stop();
        break;
      default:
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  void _handleScan(BarcodeCapture capture) {
    // Diam-diam abaikan deteksi baru selama panel konfirmasi masih
    // terbuka — mencegah barcode lain "menimpa" pilihan user di tengah
    // jalan.
    if (_detectedBarcode != null || capture.barcodes.isEmpty) return;
    final barcode = capture.barcodes.first;
    if (barcode.rawValue == null || barcode.rawValue!.isEmpty) return;

    _controller?.stop();
    setState(() => _detectedBarcode = barcode);
  }

  void _rescan() {
    setState(() => _detectedBarcode = null);
    _controller?.start();
  }

  /// User pilih "Ambil Foto" — pindah ke PhotoScanScreen yang otomatis
  /// membuka kamera dan membakar nomor barcode ini ke watermark foto.
  /// PhotoScanScreen sendiri yang menyimpan entry (dengan scanResult diisi
  /// barcode ini) begitu foto dikonfirmasi, jadi di sini kita tidak perlu
  /// menyimpan apa pun lagi — cukup teruskan hasilnya ke pemanggil layar
  /// scan ini lalu tutup layar scan.
  Future<void> _goTakePhoto() async {
    final barcode = _detectedBarcode;
    if (barcode == null) return;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoScanScreen(initialBarcode: barcode.rawValue),
      ),
    );
    if (!mounted) return;
    Navigator.pop(context, result);
  }

  /// User pilih "Simpan Tanpa Foto" — simpan entry barcode polos (tanpa
  /// gambar), sama seperti alur lama sebelum ada fitur foto opsional ini.
  Future<void> _saveWithoutPhoto() async {
    final barcode = _detectedBarcode;
    if (barcode == null) return;

    setState(() => _isSaving = true);
    try {
      ({double? lat, double? lng, String? address})? location;
      try {
        location = await _locationService.getLocation();
      } catch (e) {
        debugPrint('Location error: $e');
      }

      final entry = ScanEntry(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        barcodeValue: barcode.rawValue!,
        barcodeType: barcode.type.name,
        timestamp: DateTime.now(),
        latitude: location?.lat,
        longitude: location?.lng,
        address: location?.address ?? '',
        imagePath: null,
      );
      await _storage.addEntry(entry);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Scan tersimpan'), backgroundColor: Colors.green),
        );
        Navigator.pop(context, entry);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final barcode = _detectedBarcode;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Barcode'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(_controller?.torchState.value == TorchState.on ? Icons.flash_on : Icons.flash_off),
            onPressed: () {
              _controller?.toggleTorch();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _handleScan,
          ),
          if (barcode != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                decoration: const BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.qr_code, color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            barcode.rawValue ?? '',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isSaving ? null : _goTakePhoto,
                            icon: const Icon(Icons.camera_alt),
                            label: const Text('Ambil Foto'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isSaving ? null : _saveWithoutPhoto,
                            icon: _isSaving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.check, color: Colors.white),
                            label: Text(
                              _isSaving ? 'Menyimpan...' : 'Tanpa Foto',
                              style: const TextStyle(color: Colors.white),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.white54),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: TextButton(
                        onPressed: _isSaving ? null : _rescan,
                        child: const Text('Scan Ulang', style: TextStyle(color: Colors.white70)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

