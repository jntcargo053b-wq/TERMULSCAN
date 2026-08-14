import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/scan_entry.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  final List<ScanEntry> _entries = [];
  Future<void>? _initFuture;

  Timer? _saveDebounceTimer;
  bool _isSaving = false;

  List<ScanEntry> get entries => List.unmodifiable(_entries);

  // Beberapa layar (home/log) baca `entries` langsung tanpa await init() —
  // supaya tidak balik ke kondisi lama (list kosong kalau init() lupa
  // dipanggil), semua method publik yang menyentuh _entries menunggu
  // _ensureInit() dulu, tapi dimemoize supaya cuma load sekali dari disk.
  Future<void> _ensureInit() {
    _initFuture ??= _load();
    return _initFuture!;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString('scan_entries');
    if (data != null) {
      final List<dynamic> jsonList = json.decode(data);
      _entries.clear();
      _entries.addAll(jsonList.map((e) => ScanEntry.fromMap(e)).toList());
    }
  }

  Future<void> init() => _ensureInit();

  Future<List<ScanEntry>> loadAll() async {
    await _ensureInit();
    return _entries;
  }

  String generateId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> add(ScanEntry entry) async {
    await _ensureInit();
    _entries.insert(0, entry);
    _triggerSave();
  }

  // Alias — dipertahankan supaya nama lama masih jalan kalau ada pemanggil lain
  Future<void> addEntry(ScanEntry entry) => add(entry);

  Future<ScanEntry?> getEntry(String id) async {
    await _ensureInit();
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  Future<void> update(ScanEntry entry) async {
    await _ensureInit();
    final index = _entries.indexWhere((e) => e.id == entry.id);
    if (index != -1) {
      _entries[index] = entry;
      _triggerSave();
    }
  }

  Future<void> updateEntry(ScanEntry entry) => update(entry);

  Future<void> deleteEntry(String id) async {
    await _ensureInit();
    _entries.removeWhere((e) => e.id == id);
    _triggerSave();
  }

  void clear() {
    _entries.clear();
    _persist();
  }

  /// Salin file foto sementara (mis. hasil ImagePicker) ke direktori
  /// permanen app, dan kembalikan path barunya.
  Future<String> savePhoto(String tempPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final fileName = 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final destPath = '${dir.path}/$fileName';
    await File(tempPath).copy(destPath);
    return destPath;
  }

  void _triggerSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 500), _persist);
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
      final jsonString = json.encode(_entries.map((e) => e.toMap()).toList());
      await prefs.setString('scan_entries', jsonString);
    } catch (e) {
      debugPrint('Error saving to preferences: $e');
    } finally {
      _isSaving = false;
    }
  }
}
