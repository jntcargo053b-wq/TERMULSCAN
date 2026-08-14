import 'dart:convert';

class ScanEntry {
  final String id;
  final String barcodeValue;
  final String barcodeType;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final String? address;
  final String? imagePath;

  ScanEntry({
    required this.id,
    required this.barcodeValue,
    required this.barcodeType,
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.address,
    this.imagePath,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'barcodeValue': barcodeValue,
      'barcodeType': barcodeType,
      'timestamp': timestamp.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'address': address,
      'imagePath': imagePath,
    };
  }

  factory ScanEntry.fromMap(Map<String, dynamic> map) {
    return ScanEntry(
      id: map['id'] ?? '',
      barcodeValue: map['barcodeValue'] ?? '',
      barcodeType: map['barcodeType'] ?? '',
      timestamp: DateTime.parse(map['timestamp']),
      latitude: map['latitude']?.toDouble(),
      longitude: map['longitude']?.toDouble(),
      address: map['address'],
      imagePath: map['imagePath'],
    );
  }

  String toJson() => json.encode(toMap());

  factory ScanEntry.fromJson(String source) => ScanEntry.fromMap(json.decode(source));

  ScanEntry copyWith({
    String? id,
    String? barcodeValue,
    String? barcodeType,
    DateTime? timestamp,
    double? latitude,
    double? longitude,
    String? address,
    String? imagePath,
  }) {
    return ScanEntry(
      id: id ?? this.id,
      barcodeValue: barcodeValue ?? this.barcodeValue,
      barcodeType: barcodeType ?? this.barcodeType,
      timestamp: timestamp ?? this.timestamp,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      address: address ?? this.address,
      imagePath: imagePath ?? this.imagePath,
    );
  }
}
