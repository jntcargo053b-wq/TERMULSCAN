import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/scan_entry.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  static const _entriesKey = 'scan_entries';
  static const _photoTasksKey = 'pending_photo_tasks_v1';

  final List<ScanEntry> _entries = [];
  final Map<String, Map<String, dynamic>> _pendingPhotoTasks = {};

  Timer? _saveDebounceTimer;
  Future<void> _persistChain = Future.value();
  bool _initialized = false;
  int _idCounter = 0;

  List<ScanEntry> get entries => List.unmodifiable(_entries);

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_entriesKey);
    final taskData = prefs.getString(_photoTasksKey);
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
    if (taskData != null && taskData.isNotEmpty) {
      try {
        final List<dynamic> tasks = json.decode(taskData);
        for (final raw in tasks.whereType<Map>()) {
          final task = Map<String, dynamic>.from(raw);
          final id = task['entryId']?.toString();
          if (id != null && id.isNotEmpty && task['retryExhausted'] != true) {
            _pendingPhotoTasks[id] = task;
          }
        }
      } catch (_) {
        // Task recovery korup tidak boleh menggagalkan startup.
      }
    }

    // Normalisasi data lama: foto lama hanya menyimpan path di `value`.
    // Simpan ulang dengan imagePath yang eksplisit dan path yang sudah
    // direlokasi bila file masih dapat ditemukan.
    await _repairImageReferences();
    await cleanupOrphanPhotoFiles();
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

  Future<ScanEntry?> getEntryByImagePath(String path) async {
    if (!_initialized) await init();
    try {
      return _entries.firstWhere((e) => e.displayImagePath == path);
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
    _pendingPhotoTasks.remove(id);
    await _deleteEntryFiles(entry);
    _triggerSave();
  }

  Future<void> clear() async {
    final oldEntries = List<ScanEntry>.from(_entries);
    _entries.clear();
    _pendingPhotoTasks.clear();
    for (final entry in oldEntries) {
      await _deleteEntryFiles(entry);
    }
    await _persist();
  }

  String generateId() {
    _idCounter = (_idCounter + 1) % 1000000;
    return '${DateTime.now().millisecondsSinceEpoch}_$_idCounter';
  }

  static const MethodChannel _locationChannel =
      MethodChannel('com.termulscan.app/location');

  Future<int?> getAvailableStorageBytes() async {
    try {
      final result =
          await _locationChannel.invokeMethod<Map<dynamic, dynamic>>('getStorageInfo');
      return (result?['availableBytes'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  Future<int?> getTotalStorageBytes() async {
    try {
      final result =
          await _locationChannel.invokeMethod<Map<dynamic, dynamic>>('getStorageInfo');
      return (result?['totalBytes'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  Future<void> cleanupOrphanPhotoFiles() async {
    Directory dir;
    try {
      dir = await _photosDir();
    } catch (_) {
      return;
    }

    final referenced = <String>{};
    for (final entry in _entries) {
      if (!entry.isPhoto) continue;
      final path = entry.displayImagePath;
      if (path != null && path.isNotEmpty) {
        referenced.add(File(path).absolute.path);
        // Keep RAW while the corresponding history entry still exists; this
        // avoids deleting a recovery source if cleanup races with persistence.
        referenced.add(File(rawPathFor(path)).absolute.path);
      }
    }

    // A pending recovery task owns its RAW file even if the public path has
    // temporarily disappeared from history.
    for (final task in _pendingPhotoTasks.values) {
      final entryId = task['entryId']?.toString();
      if (entryId == null) continue;
      try {
        final entry = _entries.firstWhere((e) => e.id == entryId);
        final publicPath = entry.displayImagePath;
        if (publicPath != null && publicPath.isNotEmpty) {
          referenced.add(File(publicPath).absolute.path);
          referenced.add(File(rawPathFor(publicPath)).absolute.path);
        }
      } catch (_) {}
    }

    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last
            : '';
        if (!name.startsWith('photo_')) continue;
        final absolute = entity.absolute.path;
        if (referenced.contains(absolute)) continue;
        // Only remove files belonging to our own generated photo naming scheme.
        if (!RegExp(r'^photo_\d+_\d+(_raw)?\.[a-z0-9]{2,5}$',
                caseSensitive: false)
            .hasMatch(name)) {
          continue;
        }
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
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

  /// Jadwalkan snapshot terbaru. Jika write sebelumnya masih berjalan,
  /// snapshot baru diantrikan setelahnya — tidak pernah dibuang.
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
    final entriesSnapshot = _entries.map((e) => e.toMap()).toList();
    final tasksSnapshot = _pendingPhotoTasks.values
        .map((task) => Map<String, dynamic>.from(task))
        .toList();

    // History kecil tetap lebih cepat di UI isolate; history besar memakai
    // isolate agar json.encode() tidak membuat micro-jank pada layar.
    final entriesJson = entriesSnapshot.length >= 300
        ? await compute(_encodeJsonList, entriesSnapshot)
        : json.encode(entriesSnapshot);
    final tasksJson = tasksSnapshot.length >= 300
        ? await compute(_encodeJsonList, tasksSnapshot)
        : json.encode(tasksSnapshot);

    _persistChain = _persistChain.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_entriesKey, entriesJson);
        await prefs.setString(_photoTasksKey, tasksJson);
      } catch (e) {
        print('Error saving scan storage: $e');
      }
    });
    return _persistChain;
  }

  /// Simpan task sebelum proses GPS/watermark background dimulai.
  Future<void> enqueuePhotoTask(
    String entryId, {
    double? latitude,
    double? longitude,
  }) async {
    final previous = _pendingPhotoTasks[entryId];
    _pendingPhotoTasks[entryId] = {
      'entryId': entryId,
      'createdAt': previous?['createdAt'] ?? DateTime.now().toIso8601String(),
      'attempts': (previous?['attempts'] as int?) ?? 0,
      'watermarkCompleted': previous?['watermarkCompleted'] == true,
      'addressResolved': previous?['addressResolved'] == true,
      'retryExhausted': previous?['retryExhausted'] == true,
      // Capture-time coordinates are persisted with the task. Recovery must
      // never silently replace an old photo's location with the phone's
      // current location after the process has been killed.
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
    };
    await _persist();
  }

  List<String> get pendingPhotoTaskIds => List.unmodifiable(_pendingPhotoTasks.keys);

  Map<String, dynamic>? getPhotoTask(String entryId) {
    final task = _pendingPhotoTasks[entryId];
    return task == null ? null : Map<String, dynamic>.from(task);
  }

  Future<void> _cleanupRawForEntry(String entryId) async {
    try {
      final entry = await getEntry(entryId);
      final publicPath = entry?.displayImagePath;
      if (publicPath == null || publicPath.isEmpty) return;
      final raw = File(rawPathFor(publicPath));
      if (await raw.exists()) await raw.delete();
    } catch (_) {
      // Kegagalan hapus RAW tidak boleh menggagalkan penyelesaian task.
    }
  }

  Future<void> markPhotoTaskCompleted(String entryId) async {
    await _cleanupRawForEntry(entryId);
    _pendingPhotoTasks.remove(entryId);
    await _persist();
  }

  Future<void> markPhotoTaskWatermarkCompleted(String entryId) async {
    final task = _pendingPhotoTasks[entryId];
    if (task == null) return;
    task['watermarkCompleted'] = true;
    await _persist();
  }

  Future<void> markPhotoTaskAddressResolved(String entryId) async {
    final task = _pendingPhotoTasks[entryId];
    if (task == null) return;
    task['addressResolved'] = true;
    await _persist();
  }

  Future<void> markPhotoTaskRetryExhausted(String entryId) async {
    // A task that has permanently failed is no longer recoverable. Remove it
    // from the pending queue so it cannot accumulate or be revisited forever.
    await _cleanupRawForEntry(entryId);
    _pendingPhotoTasks.remove(entryId);
    await _persist();
  }

  Future<void> markPhotoTaskAttempt(String entryId) async {
    final task = _pendingPhotoTasks[entryId];
    if (task == null) return;
    task['attempts'] = ((task['attempts'] as int?) ?? 0) + 1;
    task['lastAttemptAt'] = DateTime.now().toIso8601String();
    await _persist();
  }

}


String _encodeJsonList(List<Map<String, dynamic>> value) => json.encode(value);
