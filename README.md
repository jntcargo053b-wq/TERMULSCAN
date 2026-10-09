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

## List Search Share
Setiap item pada hasil pencarian/riwayat memiliki tombol Share langsung. Tombol Share memakai resolver storage yang sama dengan preview sehingga path foto lama tetap dapat dipulihkan.

## CI dan Production CI/CD

Repository ini menjalankan `flutter pub get`, `flutter analyze`, dan `flutter test` pada push ke `main` dan pull request. Workflow CI tidak membuat atau mengunggah APK testing.

TERMULSCAN-BUILD memeriksa commit `main` terbaru setiap 15 menit dan hanya membangun APK production bila commit itu memiliki workflow CI `push` yang berhasil. Jadi tidak dibutuhkan `TERMULSCAN_BUILD_TOKEN` atau pemindahan APK secara manual.

Keystore production disimpan hanya sebagai GitHub Secrets di TERMULSCAN-BUILD. APK final diunggah sebagai Actions artifact dan GitHub Release.
