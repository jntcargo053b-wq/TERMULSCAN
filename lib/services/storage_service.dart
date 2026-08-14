import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/scan_entry.dart';

// Simple LRU Cache implementation for Geocoding
class LRUCache {
  final int capacity;
  final Map<String, String> _cache = {};
  final List<String> _order = [];

  LRUCache({this.capacity = 50});

  String? get(String key) {
    if (_cache.containsKey(key)) {
      _order.remove(key);
      _order.add(key);
      return _cache[key];
    }
    return null;
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

  final List<ScanEntry> _entries = [];
  final LRUCache _geoCache = LRUCache(capacity: 100);
  
  Timer? _saveDebounceTimer;
  bool _isSaving = false;

  List<ScanEntry> get entries => List.unmodifiable(_entries);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString('scan_entries');
    if (data != null) {
      final List<dynamic> jsonList = json.decode(data);
      _entries.clear();
      _entries.addAll(jsonList.map((e) => ScanEntry.fromJson(e)).toList());
    }
  }

  // Method untuk load data secara eksplisit jika diperlukan
  Future<List<ScanEntry>> loadAll() async {
    return _entries;
  }

  Future<void> addEntry(ScanEntry entry) async {
    _entries.insert(0, entry);
    _triggerSave();
  }

  Future<void> updateEntry(ScanEntry entry) async {
    final index = _entries.indexWhere((e) => e.id == entry.id);
    if (index != -1) {
      _entries[index] = entry;
      _triggerSave();
    }
  }

  Future<void> deleteEntry(String id) async {
    _entries.removeWhere((e) => e.id == id);
    _triggerSave();
  }

  void clear() {
    _entries.clear();
    _geoCache.clear();
    _persist(); // Immediate save on clear
  }

  // Debounced save mechanism (Wait 500ms after last change)
  void _triggerSave() {
    if (_saveDebounceTimer != null) {
      _saveDebounceTimer!.cancel();
    }
    _saveDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _persist();
    });
  }

  // Forced immediate save (untuk flush manual)
  Future<void> flush() async {
    if (_saveDebounceTimer != null) {
      _saveDebounceTimer!.cancel();
    }
    await _persist();
  }

  Future<void> _persist() async {
    if (_isSaving) return;
    _isSaving = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = json.encode(_entries.map((e) => e.toJson()).toList());
      await prefs.setString('scan_entries', jsonString);
    } catch (e) {
      print("Error saving to preferences: $e");
    } finally {
      _isSaving = false;
    }
  }

  // Cached Geocoding helpers
  String? getCachedLocation(double lat, double lng) {
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    return _geoCache.get(key);
  }

  void updateGeoCache(double lat, double lng, String address) {
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    _geoCache.put(key, address);
  }
}
