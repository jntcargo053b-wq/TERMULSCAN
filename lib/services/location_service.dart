import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class LocationService {
  static final _instance = LocationService._();
  factory LocationService() => _instance;
  LocationService._();

  static const _channel = MethodChannel('com.termulscan.app/location');

  static ({double? lat, double? lng, String? address})? _cachedLocation;
  static DateTime? _cacheTime;
  static const _cacheDuration = Duration(seconds: 30);

  Future<({double? lat, double? lng})> getCoordinatesOnly() async {
    try {
      final result = await _channel.invokeMethod<Map>('getLocation');
      if (result == null) return (lat: null, lng: null);
      final lat = (result['lat'] as num?)?.toDouble();
      final lng = (result['lng'] as num?)?.toDouble();
      return (lat: lat, lng: lng);
    } catch (e) {
      return (lat: null, lng: null);
    }
  }

  Future<({double? lat, double? lng, String? address})> getLocation({
    bool withAddress = true,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _cachedLocation != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < _cacheDuration) {
      final cached = _cachedLocation!;
      if (!withAddress || cached.address != null) {
        return cached;
      }
    }

    final coords = await getCoordinatesOnly();
    if (coords.lat == null || coords.lng == null) {
      return (lat: null, lng: null, address: null);
    }

    String? address;
    if (withAddress) {
      address = await _reverseGeocode(coords.lat!, coords.lng!);
    }

    final result = (lat: coords.lat, lng: coords.lng, address: address);
    _cachedLocation = result;
    _cacheTime = DateTime.now();
    return result;
  }

  Future<String?> reverseGeocode(double lat, double lng, {double? accuracy}) async {
    return await _reverseGeocode(lat, lng, accuracy: accuracy);
  }

  Future<void> updateAddressForEntry({
    required String entryId,
    required double lat,
    required double lng,
    required Future<void> Function(String entryId, String address) onAddressReceived,
    double? accuracy,
  }) async {
    try {
      final address = await _reverseGeocode(lat, lng, accuracy: accuracy);
      if (address != null) {
        await onAddressReceived(entryId, address);
        if (_cachedLocation != null &&
            _cachedLocation!.lat == lat &&
            _cachedLocation!.lng == lng) {
          _cachedLocation = (lat: lat, lng: lng, address: address);
          _cacheTime = DateTime.now();
        }
      }
    } catch (e) {
      // ignore
    }
  }

  Future<String?> _reverseGeocode(double lat, double lng, {double? accuracy}) async {
    try {
      final isCoarse = accuracy != null && accuracy >= 20;
      final zoom = isCoarse ? 14 : 18;
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=$lat&lon=$lng&format=json&addressdetails=1&zoom=$zoom',
      );
      final response = await http.get(uri, headers: {
        'User-Agent': 'WHScanner/1.0',
        'Accept-Language': 'id',
      }).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body);
      final addr = data['address'];
      if (addr == null) return null;
      final parts = <String>[];
      final city = addr['city'] ?? addr['town'] ?? addr['regency'] ?? addr['county'];
      final state = addr['state'];
      if (isCoarse) {
        final district = addr['suburb'] ??
            addr['city_district'] ??
            addr['district'] ??
            addr['subdistrict'] ??
            addr['village'] ??
            addr['neighbourhood'];
        if (district != null) parts.add(district);
        if (city != null) parts.add(city);
        if (state != null) parts.add(state);
      } else {
        final road = addr['road'] ?? addr['pedestrian'] ?? addr['path'];
        final village = addr['village'] ?? addr['suburb'] ?? addr['neighbourhood'];
        if (road != null) parts.add(road);
        if (village != null) parts.add(village);
        if (city != null) parts.add(city);
        if (state != null) parts.add(state);
      }
      return parts.isNotEmpty ? parts.join(', ') : data['display_name'];
    } catch (e) {
      return null;
    }
  }
}
