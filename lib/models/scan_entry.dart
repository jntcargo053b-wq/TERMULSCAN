import 'dart:convert';
import 'package:intl/intl.dart';

enum ScanType { barcode, photo }

class ScanEntry {
  final String id;
  final ScanType type;

  /// Nilai utama entry: isi barcode untuk [ScanType.barcode],
  /// path file foto untuk [ScanType.photo].
  final String value;

  /// Format/tipe barcode (mis. "qrCode", "ean13"). Null untuk foto.
  final String? barcodeFormat;

  final DateTime timestamp;
  final double? latitude;
  final double? longitude;

  /// Nama lokasi hasil reverse-geocoding (alamat).
  final String? locationName;

  /// Foto konteks opsional yang menyertai sebuah scan barcode.
  final String? imagePath;

  /// Hasil scan barcode/QR yang menyertai sebuah foto (kebalikan dari
  /// [imagePath] — dipakai saat type == ScanType.photo tapi foto tersebut
  /// terkait dengan sebuah barcode, misal dari alur "Foto dengan Scan").
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

  // ── Alias getters untuk kompatibilitas API lama ──────────────────────────
  bool get isBarcode => type == ScanType.barcode;
  bool get isPhoto => type == ScanType.photo;

  String get barcodeValue => value;
  String get barcodeType => barcodeFormat ?? '';
  String? get address => locationName;

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
    return ScanEntry(
      id: map['id'] ?? '',
      type: ScanType.values.firstWhere(
        (t) => t.name == map['type'],
        orElse: () => ScanType.barcode,
      ),
      value: map['value'] ?? '',
      barcodeFormat: map['barcodeFormat'],
      timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      locationName: map['locationName'],
      imagePath: map['imagePath'],
      scanResult: map['scanResult'],
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
