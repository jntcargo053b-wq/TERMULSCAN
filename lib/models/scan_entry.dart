import 'dart:convert';

enum ScanType { barcode, photo }

class ScanEntry {
  final String id;
  final ScanType type;
  final String value; // isi barcode, atau path file foto
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String? barcodeFormat; // hanya untuk type == barcode
  final String? imagePath; // foto yang menyertai scan barcode (opsional)

  ScanEntry({
    required this.id,
    required this.type,
    required this.value,
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.locationName,
    this.barcodeFormat,
    this.imagePath,
  });

  bool get isBarcode => type == ScanType.barcode;
  bool get isPhoto => type == ScanType.photo;

  String get coordinatesString {
    if (latitude == null || longitude == null) return 'Lokasi tidak tersedia';
    return '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}';
  }

  String get timestampShort {
    final d = timestamp.day.toString().padLeft(2, '0');
    final mo = timestamp.month.toString().padLeft(2, '0');
    final h = timestamp.hour.toString().padLeft(2, '0');
    final mi = timestamp.minute.toString().padLeft(2, '0');
    return '$d/$mo $h:$mi';
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type.name,
      'value': value,
      'timestamp': timestamp.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'locationName': locationName,
      'barcodeFormat': barcodeFormat,
      'imagePath': imagePath,
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
      timestamp: DateTime.parse(map['timestamp']),
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      locationName: map['locationName'],
      barcodeFormat: map['barcodeFormat'],
      imagePath: map['imagePath'],
    );
  }

  String toJson() => json.encode(toMap());

  factory ScanEntry.fromJson(String source) => ScanEntry.fromMap(json.decode(source));

  ScanEntry copyWith({
    String? id,
    ScanType? type,
    String? value,
    DateTime? timestamp,
    double? latitude,
    double? longitude,
    String? locationName,
    String? barcodeFormat,
    String? imagePath,
  }) {
    return ScanEntry(
      id: id ?? this.id,
      type: type ?? this.type,
      value: value ?? this.value,
      timestamp: timestamp ?? this.timestamp,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationName: locationName ?? this.locationName,
      barcodeFormat: barcodeFormat ?? this.barcodeFormat,
      imagePath: imagePath ?? this.imagePath,
    );
  }
}
