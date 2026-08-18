# TERMULSCAN update tanpa install ulang

Gunakan `versionCode` yang selalu naik dan **signing JKS yang sama** dengan APK yang sudah terpasang.

- Saat ini: `1.0.1+2`
- Jangan mengubah `applicationId` (`com.termulscan.app`).
- Jangan uninstall aplikasi lama.
- Untuk CI, simpan JKS sebagai Base64 di `ANDROID_KEYSTORE_BASE64` dan password/alias di secrets terkait.

Jika APK lama ditandatangani dengan debug keystore berbeda, APK release production pertama mungkin tidak dapat dipasang sebagai update. Setelah migrasi ke JKS production yang tetap, semua versi berikutnya dapat di-update tanpa menghapus data aplikasi.
