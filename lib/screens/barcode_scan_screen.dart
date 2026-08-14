import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/location_service.dart';

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({Key? key}) : super(key: key);

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> with WidgetsBindingObserver {
  MobileScannerController? _controller;
  bool _isProcessing = false;
  final _storage = StorageService();
  final _loc = LocationService();

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
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _controller?.start();
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

  Future<void> _handleScan(BarcodeCapture capture) async {
    if (_isProcessing || capture.barcodes.isEmpty) return;

    final barcode = capture.barcodes.first;
    if (barcode.rawValue == null) return;

    setState(() => _isProcessing = true);

    // Ambil koordinat cepat (best-effort, tanpa menunggu reverse-geocode)
    // dan foto capture SEKALIGUS — dua-duanya independen (beda channel/
    // plugin). Sebelumnya di-await berurutan sehingga latensi tiap scan =
    // jumlah keduanya. Start dua-duanya dulu baru await, supaya jalan
    // paralel dan latensinya cuma sebesar operasi yang paling lama.
    final coordsFuture = _loc.getCoordinatesOnly();
    final imageFuture = _captureImage();
    final coords = await coordsFuture;
    final imageFile = await imageFuture;

    final entry = ScanEntry(
      id: _storage.generateId(),
      type: ScanType.barcode,
      value: barcode.rawValue!,
      barcodeFormat: barcode.type.name,
      timestamp: DateTime.now(),
      latitude: coords.lat,
      longitude: coords.lng,
      imagePath: imageFile?.path,
    );

    await _storage.add(entry);

    // Susulkan alamat di background kalau koordinat awal berhasil didapat.
    // Sengaja tidak di-await dan dipicu SEBELUM pop, supaya tetap jalan
    // walau layar ini sudah ditutup (mirip pola di PhotoScanScreen).
    if (coords.lat != null && coords.lng != null) {
      // ignore: unawaited_futures
      _loc.updateAddressForEntry(
        entryId: entry.id,
        lat: coords.lat!,
        lng: coords.lng!,
        accuracy: coords.accuracy,
        onAddressReceived: (id, address) async {
          final current = await _storage.getEntry(id);
          if (current != null) {
            await _storage.update(current.copyWith(locationName: address));
          }
        },
      );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(imageFile != null
              ? 'Scan tersimpan'
              : 'Scan tersimpan (tanpa gambar)'),
          backgroundColor: imageFile != null ? Colors.green : Colors.orange,
        ),
      );
      Navigator.pop(context, entry);
    }
  }

  Future<File?> _captureImage() async {
    if (_controller == null) return null;
    try {
      final capture = await _controller!.takePhoto();
      if (capture == null) return null;

      final dir = await getApplicationDocumentsDirectory();
      final fileName = 'scan_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final filePath = '${dir.path}/$fileName';

      final imageFile = File(filePath);
      await imageFile.writeAsBytes(capture.bytes);

      return imageFile;
    } catch (e) {
      debugPrint("Capture error: $e");
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
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
          if (_isProcessing)
            const Container(
              color: Colors.black54,
              child: Center(child: CircularProgressIndicator(color: Colors.white)),
            ),
        ],
      ),
    );
  }
}
