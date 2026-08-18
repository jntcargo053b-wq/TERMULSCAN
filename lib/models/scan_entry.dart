import 'dart:convert';
import 'package:intl/intl.dart';

enum ScanType { barcode, photo }

class ScanEntry {
  final String id;
  final ScanType type;
  final String value;
  final String? barcodeFormat;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String? imagePath;
  final String? scanResult;

  ScanEntry({
    required this.id,
    ScanType? type,
    String? value,
    String? barcodeValue,
    String? barcodeFormat,
    String? barcodeType,
    required this.timestamp,
    this.latitude,
    this.longitude,
    String? locationName,
    String? address,
    this.imagePath,
    this.scanResult,
  })  : type = type ?? (barcodeValue != null ? ScanType.barcode : ScanType.photo),
        value = value ?? barcodeValue ?? '',
        barcodeFormat = barcodeFormat ?? barcodeType,
        locationName = locationName ?? address;

  bool get isBarcode => type == ScanType.barcode;
  bool get isPhoto => type == ScanType.photo;

  String get barcodeValue => value;
  String get barcodeType => barcodeFormat ?? '';
  String? get address => locationName;

  /// Untuk foto, imagePath adalah field kanonis. `value` tetap menjadi
  /// fallback agar data lama tetap dapat ditampilkan.
  String? get displayImagePath {
    if (isPhoto) {
      if (imagePath != null && imagePath!.trim().isNotEmpty) return imagePath;
      if (value.trim().isNotEmpty) return value;
      return null;
    }
    return imagePath?.trim().isNotEmpty == true ? imagePath : null;
  }

  String get displayTitle {
    if (isPhoto) {
      if (scanResult != null && scanResult!.trim().isNotEmpty) return scanResult!;
      return 'Foto tanpa barcode';
    }
    return barcodeValue;
  }

  /// Nama file saja, aman dipakai untuk search tanpa membocorkan path storage.
  String get imageFileName {
    final path = displayImagePath;
    if (path == null || path.isEmpty) return '';
    return path.split(RegExp(r'[/\\]')).last;
  }

  String get coordinatesString {
    if (latitude == null || longitude == null) return 'Lokasi tidak tersedia';
    return '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}';
  }

  String get timestampShort => DateFormat('dd/MM HH:mm').format(timestamp);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type.name,
      'value': value,
      'barcodeFormat': barcodeFormat,
      'timestamp': timestamp.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'locationName': locationName,
      'imagePath': imagePath,
      'scanResult': scanResult,
    };
  }

  factory ScanEntry.fromMap(Map<String, dynamic> map) {
    final typeName = map['type']?.toString();
    final type = ScanType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => (map['imagePath'] != null ||
              (map['value']?.toString().contains('/') ?? false) ||
              (map['value']?.toString().contains('\\') ?? false))
          ? ScanType.photo
          : ScanType.barcode,
    );

    return ScanEntry(
      id: map['id']?.toString() ?? '',
      type: type,
      value: map['value']?.toString() ?? '',
      barcodeFormat: map['barcodeFormat']?.toString(),
      timestamp: DateTime.tryParse(map['timestamp']?.toString() ?? '') ?? DateTime.now(),
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      locationName: map['locationName']?.toString(),
      imagePath: map['imagePath']?.toString(),
      scanResult: map['scanResult']?.toString(),
    );
  }

  String toJson() => json.encode(toMap());

  factory ScanEntry.fromJson(String source) => ScanEntry.fromMap(json.decode(source));

  ScanEntry copyWith({
    String? id,
    ScanType? type,
    String? value,
    String? barcodeFormat,
    DateTime? timestamp,
    double? latitude,
    double? longitude,
    String? locationName,
    String? imagePath,
    String? scanResult,
  }) {
    return ScanEntry(
      id: id ?? this.id,
      type: type ?? this.type,
      value: value ?? this.value,
      barcodeFormat: barcodeFormat ?? this.barcodeFormat,
      timestamp: timestamp ?? this.timestamp,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationName: locationName ?? this.locationName,
      imagePath: imagePath ?? this.imagePath,
      scanResult: scanResult ?? this.scanResult,
    );
  }
}
