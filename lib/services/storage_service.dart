import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/scan_entry.dart';

class LRUCache {
  final int capacity;
  final Map<String, String> _cache = {};
  final List<String> _order = [];

  LRUCache({this.capacity = 50});

  String? get(String key) {
    if (!_cache.containsKey(key)) return null;
    _order.remove(key);
    _order.add(key);
    return _cache[key];
  }

  void put(String key, String value) {
    if (_cache.containsKey(key)) {
      _order.remove(key);
    } else if (_cache.length >= capacity) {
      final oldest = _order.removeAt(0);
      _cache.remove(oldest);
    }
    _cache[key] = value;
    _order.add(key);
  }

  void clear() {
    _cache.clear();
    _order.clear();
  }
}

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  static const _entriesKey = 'scan_entries';

  final List<ScanEntry> _entries = [];
  final LRUCache _geoCache = LRUCache(capacity: 100);

  Timer? _saveDebounceTimer;
  bool _isSaving = false;
  bool _initialized = false;
  int _idCounter = 0;

  List<ScanEntry> get entries => List.unmodifiable(_entries);

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_entriesKey);
    if (data != null && data.isNotEmpty) {
      try {
        final List<dynamic> jsonList = json.decode(data);
        _entries
          ..clear()
          ..addAll(jsonList
              .whereType<Map>()
              .map((e) => ScanEntry.fromMap(Map<String, dynamic>.from(e))));
      } catch (_) {
        // Jangan crash saat startup bila history lama korup.
      }
    }

    // Normalisasi data lama: foto lama hanya menyimpan path di `value`.
    // Simpan ulang dengan imagePath yang eksplisit dan path yang sudah
    // direlokasi bila file masih dapat ditemukan.
    await _repairImageReferences();
    _initialized = true;
  }

  Future<List<ScanEntry>> loadAll() async {
    if (!_initialized) await init();
    return entries;
  }

  Future<void> add(ScanEntry entry) async {
    _entries.insert(0, entry);
    _triggerSave();
  }

  Future<void> addEntry(ScanEntry entry) => add(entry);

  Future<ScanEntry?> getEntry(String id) async {
    try {
      return _entries.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> update(ScanEntry entry) async {
    final index = _entries.indexWhere((e) => e.id == entry.id);
    if (index != -1) {
      _entries[index] = entry;
      _triggerSave();
    }
  }

  Future<void> updateEntry(ScanEntry entry) => update(entry);

  Future<void> deleteEntry(String id) async {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index == -1) return;

    final entry = _entries.removeAt(index);
    await _deleteEntryFiles(entry);
    _triggerSave();
  }

  Future<void> clear() async {
    final oldEntries = List<ScanEntry>.from(_entries);
    _entries.clear();
    _geoCache.clear();
    for (final entry in oldEntries) {
      await _deleteEntryFiles(entry);
    }
    await _persist();
  }

  String generateId() {
    _idCounter = (_idCounter + 1) % 1000000;
    return '${DateTime.now().millisecondsSinceEpoch}_$_idCounter';
  }

  /// Storage foto aplikasi yang stabil. Android tetap memakai external app
  /// storage agar tidak membebani internal storage; fallback ke Documents.
  Future<Directory> _photosBaseDir() async {
    if (Platform.isAndroid) {
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) return extDir;
      } catch (_) {}
    }
    return getApplicationDocumentsDirectory();
  }

  Future<Directory> _photosDir() async {
    final base = await _photosBaseDir();
    final dir = Directory('${base.path}/photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> savePhoto(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('File foto sumber tidak ditemukan', sourcePath);
    }

    final photosDir = await _photosDir();
    final extension = _extensionOf(sourcePath);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final fileName = 'photo_${stamp}_${_idCounter + 1}.$extension';
    final destination = File('${photosDir.path}/$fileName');

    await source.copy(destination.path);
    if (!await destination.exists() || await destination.length() == 0) {
      try {
        await destination.delete();
      } catch (_) {}
      throw FileSystemException('Foto gagal disimpan', destination.path);
    }
    return destination.path;
  }

  String _extensionOf(String path) {
    final clean = path.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || dot == clean.length - 1) return 'jpg';
    final ext = clean.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext) ? ext : 'jpg';
  }

  String rawPathFor(String publicPath) {
    final dotIndex = publicPath.lastIndexOf('.');
    if (dotIndex == -1) return '${publicPath}_raw';
    return '${publicPath.substring(0, dotIndex)}_raw${publicPath.substring(dotIndex)}';
  }

  Future<void> savePhotoRawCopy(String sourcePath, String publicPath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('File sumber raw tidak ditemukan', sourcePath);
    }
    final raw = File(rawPathFor(publicPath));
    await source.copy(raw.path);
    if (!await raw.exists() || await raw.length() == 0) {
      throw FileSystemException('Raw foto gagal disimpan', raw.path);
    }
  }

  /// Resolve path foto yang disimpan di history. Jika absolute path lama
  /// sudah tidak valid, cari filename yang sama di storage app saat ini.
  Future<String?> resolveImagePath(ScanEntry entry) async {
    final candidates = <String>[];
    final primary = entry.displayImagePath;
    if (primary != null && primary.isNotEmpty) candidates.add(primary);

    final fileName = entry.imageFileName;
    if (fileName.isNotEmpty) {
      final dirs = await _candidatePhotoDirs();
      for (final dir in dirs) candidates.add('${dir.path}/$fileName');
    }

    final seen = <String>{};
    for (final path in candidates) {
      if (!seen.add(path)) continue;
      try {
        final file = File(path);
        if (await file.exists() && await file.length() > 0) {
          if (path != primary && entry.isPhoto) {
            await update(entry.copyWith(imagePath: path, value: path));
          }
          return path;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<List<Directory>> _candidatePhotoDirs() async {
    final dirs = <Directory>[];
    final currentBase = await _photosBaseDir();
    dirs.add(Directory('${currentBase.path}/photos'));

    // Lokasi yang dipakai versi sebelumnya: Documents/photos.
    final documents = await getApplicationDocumentsDirectory();
    dirs.add(Directory('${documents.path}/photos'));

    if (Platform.isAndroid) {
      try {
        final external = await getExternalStorageDirectory();
        if (external != null) dirs.add(Directory('${external.path}/photos'));
      } catch (_) {}
    }

    final unique = <String>{};
    return dirs.where((d) => unique.add(d.path)).toList();
  }

  Future<void> _repairImageReferences() async {
    var changed = false;
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (!entry.isPhoto) continue;

      final resolved = await resolveImagePath(entry);
      if (resolved != null &&
          (entry.imagePath != resolved || entry.value != resolved)) {
        _entries[i] = entry.copyWith(value: resolved, imagePath: resolved);
        changed = true;
      } else if (resolved == null && entry.imagePath == null && entry.value.isNotEmpty) {
        // Tetap isi imagePath agar entry baru/hasil migrasi konsisten.
        _entries[i] = entry.copyWith(imagePath: entry.value);
        changed = true;
      }
    }
    if (changed) await _persist();
  }

  Future<void> _deleteEntryFiles(ScanEntry entry) async {
    final paths = <String>{};
    final image = entry.displayImagePath;
    if (image != null && image.isNotEmpty) {
      // Jangan menghapus file yang masih direferensikan entry lain.
      final referencedElsewhere = _entries.any((other) =>
          other.id != entry.id && other.displayImagePath == image);
      if (!referencedElsewhere) {
        paths.add(image);
        paths.add(rawPathFor(image));
      }
    }
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  void _triggerSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persist());
    });
  }

  Future<void> flush() async {
    _saveDebounceTimer?.cancel();
    await _persist();
  }

  Future<void> _persist() async {
    if (_isSaving) return;
    _isSaving = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _entriesKey,
        json.encode(_entries.map((e) => e.toMap()).toList()),
      );
    } catch (e) {
      print('Error saving scan entries: $e');
    } finally {
      _isSaving = false;
    }
  }

  String? getCachedLocation(double lat, double lng) {
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    return _geoCache.get(key);
  }

  void updateGeoCache(double lat, double lng, String address) {
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    _geoCache.put(key, address);
  }
}
