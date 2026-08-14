import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
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
}

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  final List<ScanEntry> _entries = [];
  final Map<String, String> _geoCache = {}; // In-memory cache wrapper
  final LRUCache _lruGeoCache = LRUCache(capacity: 100);
  
  // Debounce timer logic
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

  // Debounced save mechanism (Wait 500ms after last change)
  void _triggerSave() {
    if (_saveDebounceTimer != null) {
      _saveDebounceTimer!.cancel();
    }
    _saveDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _persist();
    });
  }

  Future<void> _persist() async {
    if (_isSaving) return;
    _isSaving = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = json.encode(_entries.map((e) => e.toJson()).toList());
      await prefs.setString('scan_entries', jsonString);
    } finally {
      _isSaving = false;
    }
  }

  // Cached Geocoding
  Future<String?> getCachedLocation(double lat, double lng) async {
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    
    // Check LRU Cache first
    final cached = _lruGeoCache.get(key);
    if (cached != null) return cached;

    // If not in cache, return null (caller should fetch from API and update cache)
    return null;
  }

  void updateGeoCache(double lat, double lng, String address) {
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    _lruGeoCache.put(key, address);
  }

  void clear() {
    _entries.clear();
    _lruGeoCache.clear(); // Clear cache on reset if needed
  }
}
