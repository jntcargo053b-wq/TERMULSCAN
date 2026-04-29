# WH Scanner — Scanner Gudang & Ekspedisi

Aplikasi Flutter profesional untuk kebutuhan gudang dan ekspedisi.

## Fitur
- **Scan Barcode / QR Code** — realtime, support QR, EAN-13, Code-128, dll
- **Ambil Foto** — kamera langsung atau dari galeri
- **Timestamp Otomatis** — setiap scan dicatat waktu lengkap (dd-MM-yyyy HH:mm:ss)
- **GPS Otomatis** — koordinat + nama lokasi (reverse geocoding)
- **Log Scan** — riwayat semua scan, bisa cari & filter
- **Export TXT** — laporan teks profesional siap dibagikan

## Cara Build

```bash
flutter pub get
flutter build apk --release
# APK: build/app/outputs/flutter-apk/app-release.apk
```

## Dependencies
- `mobile_scanner` — kamera barcode/QR
- `image_picker` — ambil foto
- `geolocator` + `geocoding` — GPS & nama lokasi
- `path_provider` + `share_plus` — simpan & bagikan file
- `permission_handler` — manajemen izin

## Struktur
```
lib/
  main.dart
  models/scan_entry.dart
  screens/
    home_screen.dart
    barcode_scan_screen.dart
    photo_scan_screen.dart
    log_screen.dart
  services/
    location_service.dart
    storage_service.dart
  theme/app_theme.dart
```
