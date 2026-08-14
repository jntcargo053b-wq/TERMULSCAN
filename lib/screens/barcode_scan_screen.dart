import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/location_service.dart';
import '../widgets/watermark_overlay.dart'; // Pastikan widget ini ada

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
      Position? position;
      try {
        position = await _locationService.getCurrentLocation();
      } catch (e) {
        // Fallback handled in service, continue with null or last known
      }

      // 2. Create Entry
      final entry = ScanEntry(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        barcodeValue: barcode.rawValue!,
        barcodeType: barcode.type.name,
        timestamp: DateTime.now(),
        latitude: position?.latitude,
        longitude: position?.longitude,
        address: '', // Will be filled by geocoding later or in detail view
      );

      // 3. Capture Image & Watermark (Simplified for brevity)
      // Dalam implementasi nyata, panggil fungsi watermark isolate di sini
      final imageFile = await _captureAndWatermark(position);

      // Update entry with image path
      final finalEntry = entry.copyWith(imagePath: imageFile?.path);

      // 4. SAVE TO STORAGE IMMEDIATELY (Critical Fix)
      await _storage.addEntry(finalEntry);

      // 5. Show Success & Navigate Back
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Scan saved successfully!'), backgroundColor: Colors.green),
        );
        Navigator.pop(context, finalEntry);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<File?> _captureAndWatermark(Position? position) async {
    if (_controller == null) return null;
    try {
      final capture = await _controller!.takePhoto();
      if (capture == null) return null;

      final dir = await getApplicationDocumentsDirectory();
      final fileName = 'scan_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final filePath = '${dir.path}/$fileName';
      
      File imageFile = File(filePath);
      // Simpan foto mentah dulu
      await imageFile.writeAsBytes(capture.bytes);

      // TODO: Panggil fungsi watermark isolate di sini jika diperlukan sebelum return
      // final watermarkedFile = await processWatermark(imageFile, position);
      
      return imageFile;
    } catch (e) {
      print("Capture error: $e");
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Barcode')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _handleScan,
          ),
          if (_isProcessing)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }
}
