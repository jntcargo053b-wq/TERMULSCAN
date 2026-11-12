# TERMULSCAN — Scanner Gudang & Dokumentasi POD

TERMULSCAN adalah aplikasi Android berbasis Flutter untuk alur kerja gudang dan ekspedisi: membaca barcode/QR, mengambil bukti foto, mencatat waktu dan lokasi, membakar watermark ke foto, serta menyimpan riwayat scan secara lokal.

## Fitur utama

- **Scan barcode dan QR secara realtime** menggunakan kamera belakang.
- **Konfirmasi hasil scan** sebelum melanjutkan: ambil foto POD, simpan tanpa foto, atau scan ulang.
- **Input AWB manual** bila barcode tidak dapat dibaca.
- **Foto POD dari kamera atau galeri**, dengan opsi mendeteksi barcode dari gambar galeri.
- **Metadata waktu dan lokasi**: timestamp, koordinat GPS, dan reverse-geocoded address bila jaringan tersedia.
- **Watermark foto** dengan pilihan gaya (Timemark, Classic, Compact, Top, Modern, Minimal, Badge), posisi, nama operator, teks tambahan, dan logo.
- **Pemrosesan foto berurutan dan pemulihan task**: pekerjaan foto yang terputus dapat dicoba kembali setelah aplikasi dibuka/resume.
- **Riwayat lokal** untuk scan barcode dan foto, pencarian berdasarkan AWB/hasil scan/lokasi/nama file/tanggal, pratinjau foto, dan share.
- **Perlindungan file** melalui penyimpanan bertahap, pemulihan referensi foto lama, dan pembersihan file foto yatim yang tidak lagi direferensikan.

## Catatan penggunaan

- GPS dan alamat membutuhkan izin lokasi. Reverse geocoding membutuhkan koneksi internet; koordinat dapat tetap dicatat ketika alamat tidak tersedia.
- Barcode dari gambar galeri bergantung pada kualitas, orientasi, dan keterbacaan barcode.
- Riwayat disimpan pada penyimpanan privat aplikasi. Jangan menghapus data aplikasi atau uninstall jika ingin mempertahankan riwayat lokal.
- Foto yang disimpan/di-share merupakan bukti kerja; pastikan hasil watermark dan AWB benar sebelum digunakan sebagai POD.

## Build lokal

Memerlukan Flutter SDK dan Android SDK yang kompatibel dengan konfigurasi proyek.

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

APK lokal: `build/app/outputs/flutter-apk/app-release.apk`.

## CI dan distribusi

Workflow pada repository menjalankan `flutter pub get`, `flutter analyze`, dan `flutter test`. Untuk event push/manual (bukan pull request), workflow juga membangun APK dan menerbitkan aset pada GitHub Release.

Konfigurasi signing produksi dikelola terpisah oleh repository **TERMULSCAN-BUILD**. Build dari repository ini menggunakan signing pengujian bila tidak diberi konfigurasi keystore produksi. Jangan menganggap APK hasil build pengujian dapat dipasang sebagai pembaruan atas APK produksi; Android mensyaratkan applicationId dan sertifikat signing yang cocok.

## Identitas aplikasi dan data

- Android applicationId: `com.termulscan.app`
- Namespace: `com.termulscan.app`
- Penyimpanan riwayat: SharedPreferences dengan key kompatibilitas yang sudah ada.
- Task recovery: `pending_photo_tasks_v1`.

Perubahan fitur harus mempertahankan applicationId, skema/key penyimpanan, dan identitas signing produksi. Jangan menghapus atau mengganti keystore produksi tanpa instruksi eksplisit.
