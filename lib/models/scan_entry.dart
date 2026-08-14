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
  final String? note;
  // ID entri pasangan (barcode <-> foto) dari satu aksi scan yang sama.
  // Dipakai untuk cascade delete & agar 2 entri yang muncul di log bisa
  // ditelusuri sebagai satu kesatuan, bukan dua baris lepas tak terkait.
  final String? linkedId;

  ScanEntry({
    required this.id,
    required this.type,
    required this.value,
    this.barcodeFormat,
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.locationName,
    this.note,
    this.linkedId,
  });

  String get timestampFormatted =>
      DateFormat('dd-MM-yyyy HH:mm:ss').format(timestamp);

  String get timestampShort =>
      DateFormat('dd/MM HH:mm').format(timestamp);

  String get coordinatesString {
    if (latitude == null || longitude == null) return 'GPS tidak tersedia';
    return '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}';
  }

  bool get isBarcode => type == ScanType.barcode;
  bool get isPhoto => type == ScanType.photo;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'value': value,
    'barcodeFormat': barcodeFormat,
    'timestamp': timestamp.toIso8601String(),
    'latitude': latitude,
    'longitude': longitude,
    'locationName': locationName,
    'note': note,
    'linkedId': linkedId,
  };

  factory ScanEntry.fromJson(Map<String, dynamic> j) => ScanEntry(
    id: j['id'],
    type: ScanType.values.firstWhere((e) => e.name == j['type']),
    value: j['value'],
    barcodeFormat: j['barcodeFormat'],
    timestamp: DateTime.parse(j['timestamp']),
    latitude: (j['latitude'] as num?)?.toDouble(),
    longitude: (j['longitude'] as num?)?.toDouble(),
    locationName: j['locationName'],
    note: j['note'],
    // Entri lama (sebelum field ini ada) tidak punya key 'linkedId' —
    // aman jadi null lewat operator akses map bertanda tanya.
    linkedId: j['linkedId'],
  );

  ScanEntry copyWith({
    String? value,
    double? latitude,
    double? longitude,
    String? locationName,
    String? note,
    String? linkedId,
  }) => ScanEntry(
    id: id, type: type, value: value ?? this.value, barcodeFormat: barcodeFormat,
    timestamp: timestamp,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    locationName: locationName ?? this.locationName,
    note: note ?? this.note,
    linkedId: linkedId ?? this.linkedId,
  );
}
