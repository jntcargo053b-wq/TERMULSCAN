import 'dart:io';

/// Memulihkan file sementara watermark setelah proses aplikasi terhenti.
///
/// Dipanggil saat startup saja, sebelum pipeline foto menerima pekerjaan baru.
class PhotoFileRecovery {
  PhotoFileRecovery._();

  static const _temporaryMarker = '.wm_tmp_';
  static const _backupMarker = '.wm_backup_';

  static Future<void> recoverWatermarkArtifacts(Directory directory) async {
    if (!await directory.exists()) return;

    final files = await directory
        .list(followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();

    final backups = <({File file, DateTime modified})>[];
    for (final file in files) {
      final name = _fileName(file);
      if (!name.contains(_backupMarker)) continue;
      try {
        backups.add((file: file, modified: await file.lastModified()));
      } catch (_) {
        // File yang tidak dapat diperiksa dibiarkan untuk pemeriksaan berikutnya.
      }
    }

    // Jika ada beberapa backup, periksa yang terbaru lebih dahulu.
    backups.sort((a, b) => b.modified.compareTo(a.modified));
    for (final item in backups) {
      final backup = item.file;
      final name = _fileName(backup);
      final marker = name.lastIndexOf(_backupMarker);
      if (marker <= 0) continue;

      final original = File(
        '${directory.path}/${name.substring(0, marker)}',
      );
      try {
        if (await original.exists()) {
          // Output baru sudah berhasil dipasang; backup lama tidak diperlukan.
          await backup.delete();
        } else {
          // Output baru belum terpasang. Pulihkan foto lama agar riwayat tidak
          // menunjuk ke file yang hilang.
          await backup.rename(original.path);
        }
      } catch (_) {
        // Jangan menghapus backup bila pemulihan gagal.
      }
    }

    // Temp output tidak pernah menjadi sumber riwayat. Aman dibersihkan
    // setelah proses startup memastikan tidak ada burn aktif.
    for (final file in files) {
      if (!_fileName(file).contains(_temporaryMarker)) continue;
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  static String _fileName(File file) =>
      file.uri.pathSegments.isEmpty ? '' : file.uri.pathSegments.last;
}
