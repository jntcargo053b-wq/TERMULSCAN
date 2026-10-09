# WH Scanner — Scanner Gudang & Ekspedisi

Aplikasi Flutter untuk scan barcode/QR, dokumentasi foto POD, timestamp, GPS, watermark, history, search, dan share.

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
- `LocationManager` native Android + `http`/Nominatim — GPS & nama lokasi
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

## List Search Share
- Setiap item pada hasil pencarian/riwayat memiliki tombol Share langsung.
- Tombol Share memakai resolver storage yang sama dengan preview sehingga path foto lama tetap dapat dipulihkan.

## Catatan CI

GitHub Actions membangun project Android yang sudah ada di repository secara langsung. Workflow tidak menjalankan `flutter create`, tidak melakukan `git pull/push`, dan tidak memodifikasi source repository saat build.

Workflow CI menjalankan `flutter pub get`, `flutter analyze`, dan `flutter test`. APK production dibuat di repository TERMULSCAN-BUILD.

## Production CI/CD

Pada setiap push ke `main`, setelah analyze dan test sukses, TERMULSCAN meminta TERMULSCAN-BUILD menjalankan workflow production dengan SHA commit sumber yang tepat.

Secret `TERMULSCAN_BUILD_TOKEN` di TERMULSCAN harus menggunakan token yang:
- Dibuat oleh akun yang memiliki akses ke `jntcargo053b-wq/TERMULSCAN-BUILD`.
- Memiliki akses repository ke `TERMULSCAN-BUILD`.
- Memiliki permission **Actions: Read and write** (untuk endpoint workflow dispatch).

TERMULSCAN-BUILD menyimpan keystore production hanya di GitHub Secrets dan mempublikasikan APK production sebagai artifact dan GitHub Release.
