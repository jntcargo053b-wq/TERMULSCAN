import 'dart:io';

import 'package:image/image.dart' as img;

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
        if (await original.exists() && await _isDecodableImage(original)) {
          // A valid destination is already the committed output. Its backup
          // is obsolete, even if the backup itself is damaged.
          await backup.delete();
          continue;
        }

        // A backup is a recovery source only if it is a decodable image.
        // Never replace a destination with an empty/truncated backup.
        if (!await _isDecodableImage(backup)) {
          continue;
        }

        if (await original.exists()) {
          // Destination is empty/corrupt: restore the valid previous photo.
          await original.delete();
        }
        // Output is missing or corrupt. Restore the valid backup so history
        // does not point at a missing/invalid image.
        await backup.rename(original.path);
      } catch (_) {
        // Jangan menghapus backup bila pemeriksaan/pemulihan gagal.
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

  static Future<bool> _isDecodableImage(File file) async {
    try {
      if (await file.length() == 0) return false;
      return img.decodeImage(await file.readAsBytes()) != null;
    } catch (_) {
      return false;
    }
  }

  static String _fileName(File file) =>
      file.uri.pathSegments.isEmpty ? '' : file.uri.pathSegments.last;
}
