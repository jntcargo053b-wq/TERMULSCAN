import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/scan_entry.dart';

class StorageService {
  static final _i = StorageService._();
  factory StorageService() => _i;
  StorageService._();

  static const _fileName = 'scan_log.json';

  // ── In-memory cache ──────────────────────────────────────────────────────
  List<ScanEntry>? _cache;

  Future<Directory> get _dir async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/WHScanner');
    await d.create(recursive: true);
    return d;
  }

  Future<File> get _jsonFile async {
    final d = await _dir;
    return File('${d.path}/$_fileName');
  }

  Future<List<ScanEntry>> loadAll() async {
    if (_cache != null) return List.unmodifiable(_cache!);
    try {
      final f = await _jsonFile;
      if (!await f.exists()) {
        _cache = [];
        return [];
      }
      final raw = await f.readAsString();
      final list = json.decode(raw) as List;
      _cache = list.map((e) => ScanEntry.fromJson(e)).toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return List.unmodifiable(_cache!);
    } catch (_) {
      _cache = [];
      return [];
    }
  }

  Future<void> _persist() async {
    final f = await _jsonFile;
    await f.writeAsString(
      json.encode((_cache ?? []).map((e) => e.toJson()).toList()),
    );
  }

  /// Append entry ke cache + disk tanpa baca ulang file.
  Future<void> add(ScanEntry entry) async {
    // Pastikan cache sudah di-load sekali
    if (_cache == null) await loadAll();
    _cache!.insert(0, entry);
    await _persist();
  }

  Future<void> update(ScanEntry entry) async {
    if (_cache == null) await loadAll();
    final idx = _cache!.indexWhere((e) => e.id == entry.id);
    if (idx >= 0) _cache![idx] = entry;
    await _persist();
  }

  Future<void> delete(String id) async {
    if (_cache == null) await loadAll();
    final entry = _cache!.firstWhere((e) => e.id == id);
    if (entry.isPhoto) {
      try {
        final f = File(entry.value);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _cache!.removeWhere((e) => e.id == id);
    await _persist();
  }

  Future<void> deleteAll() async {
    if (_cache == null) await loadAll();
    for (final e in _cache!) {
      if (e.isPhoto) {
        try {
          final f = File(e.value);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    _cache = [];
    final f = await _jsonFile;
    if (await f.exists()) await f.delete();
  }

  /// Invalidasi cache (misal setelah proses luar mengubah file)
  void invalidateCache() => _cache = null;

  Future<String> exportTxt(List<ScanEntry> entries) async {
    final d = await _dir;
    final now = DateTime.now();
    final fname =
        'laporan_${now.day.toString().padLeft(2, '0')}-${now.month.toString().padLeft(2, '0')}-${now.year}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.txt';
    final f = File('${d.path}/$fname');

    final buf = StringBuffer();
    final sep = '=' * 60;
    final thin = '-' * 60;

    buf.writeln(sep);
    buf.writeln('  WH SCANNER — LAPORAN LOG SCAN');
    buf.writeln('  Dicetak: ${_fmt(now)}');
    buf.writeln(sep);
    buf.writeln();
    buf.writeln('Total scan  : ${entries.length} entri');
    buf.writeln('Barcode     : ${entries.where((e) => e.isBarcode).length}');
    buf.writeln('Foto        : ${entries.where((e) => e.isPhoto).length}');
    buf.writeln();

    for (int i = 0; i < entries.length; i++) {
      final e = entries[i];
      buf.writeln('[${(i + 1).toString().padLeft(3, '0')}] ${e.isBarcode ? "BARCODE" : "FOTO"}');
      buf.writeln('    Waktu    : ${e.timestampFormatted}');
      if (e.isBarcode) {
        buf.writeln('    Format   : ${e.barcodeFormat ?? "-"}');
        buf.writeln('    Nilai    : ${e.value}');
      } else {
        buf.writeln('    File     : ${e.value.split('/').last}');
      }
      buf.writeln('    GPS      : ${e.coordinatesString}');
      if (e.locationName != null) buf.writeln('    Lokasi   : ${e.locationName}');
      if (e.note != null && e.note!.isNotEmpty) buf.writeln('    Catatan  : ${e.note}');
      buf.writeln(thin);
    }

    buf.writeln();
    buf.writeln(sep);
    buf.writeln('  WH Scanner Pro  |  ${_fmt(now)}');
    buf.writeln(sep);

    await f.writeAsString(buf.toString(), flush: true);
    return f.path;
  }

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';

  Future<void> shareTxt(String path) async {
    await Share.shareXFiles([XFile(path)], subject: 'Log Scan WH Scanner');
  }

  /// Simpan foto ke folder permanen app.
  /// Mengembalikan path final — TIDAK melakukan copy ganda.
  Future<String> savePhoto(String tempPath, {String? name}) async {
    final d = await _dir;
    final photoDir = Directory('${d.path}/photos');
    await photoDir.create(recursive: true);
    final id = DateTime.now().millisecondsSinceEpoch;
    final cleanName = name != null
        ? name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        : 'photo';
    final dest = '${photoDir.path}/${cleanName}_$id.jpg';
    await File(tempPath).rename(dest).catchError((_) async {
      // rename lintas partisi tidak bisa → fallback copy+delete
      await File(tempPath).copy(dest);
      try {
        await File(tempPath).delete();
      } catch (_) {}
      return File(dest);
    });
    return dest;
  }

  String generateId() => 'sc_${DateTime.now().millisecondsSinceEpoch}';

  // ── Method getEntry untuk mengambil satu entri berdasarkan ID ─────────────
  Future<ScanEntry?> getEntry(String id) async {
    if (_cache == null) await loadAll();
    try {
      return _cache!.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }
}
