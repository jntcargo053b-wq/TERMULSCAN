import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:intl/intl.dart';
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
  final _locationService = LocationService();

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

    try {
      // 1. Get Location First
      ({double? lat, double? lng, String? address})? location;
      try {
        location = await _locationService.getLocation();
      } catch (e) {
        // Continue with null location if failed
        debugPrint("Location error: $e");
      }

      // 2. Create Entry
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

      // 3. Capture Image
      File? imageFile;
      try {
        imageFile = await _captureImage();
        
        // Update entry with image path if capture success
        if (imageFile != null) {
          // TODO: Integrasikan watermark processing di sini jika diperlukan
          // Untuk sekarang simpan gambar asli dulu agar save tidak gagal
          final entryWithImage = entry.copyWith(imagePath: imageFile.path);
          
          // 4. SAVE TO STORAGE IMMEDIATELY
          await _storage.addEntry(entryWithImage);
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Scan saved successfully!'), backgroundColor: Colors.green),
            );
            Navigator.pop(context, entryWithImage);
            return;
          }
        } else {
          // Jika gagal ambil gambar, tetap simpan data scan tanpa gambar
           await _storage.addEntry(entry);
           if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Scan saved (no image)'), backgroundColor: Colors.orange),
            );
            Navigator.pop(context, entry);
            return;
          }
        }
      } catch (e) {
        // Fallback: Simpan data meski gambar gagal
        await _storage.addEntry(entry);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved without image: $e'), backgroundColor: Colors.orange),
          );
          Navigator.pop(context, entry);
        }
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
        setState(() => _isProcessing = false);
      }
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
      
      File imageFile = File(filePath);
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
          IconButton(
            icon: const Icon(Icons.camera_alt),
            onPressed: () {
               // Manual capture trigger if needed
            },
          )
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
