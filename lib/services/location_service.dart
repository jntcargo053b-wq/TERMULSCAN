import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class LocationService {
  static final _instance = LocationService._();
  factory LocationService() => _instance;
  LocationService._();

  static const _channel = MethodChannel('com.gudang.scanner/location');

  Future<({double? lat, double? lng, String? address})> getLocation({
    bool forceRefresh = false,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('getLocation');
      if (result == null) return (lat: null, lng: null, address: null);

      final lat = (result['lat'] as num?)?.toDouble();
      final lng = (result['lng'] as num?)?.toDouble();

      if (lat == null || lng == null) {
        return (lat: null, lng: null, address: null);
      }

      // Reverse geocoding via Nominatim
      final address = await _reverseGeocode(lat, lng);

      return (lat: lat, lng: lng, address: address);
    } catch (e) {
      return (lat: null, lng: null, address: null);
    }
  }

  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=$lat&lon=$lng&format=json&addressdetails=1',
      );

      final response = await http.get(uri, headers: {
        'User-Agent': 'WHScanner/1.0',
        'Accept-Language': 'id', // Bahasa Indonesia
      }).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return null;

      final data = json.decode(response.body);
      final addr = data['address'];
      if (addr == null) return null;

      // Susun alamat dari yang paling spesifik
      final parts = <String>[];

      final road = addr['road'] ?? addr['pedestrian'] ?? addr['path'];
      final village = addr['village'] ?? addr['suburb'] ?? addr['neighbourhood'];
      final city = addr['city'] ?? addr['town'] ?? addr['regency'] ?? addr['county'];
      final state = addr['state'];

      if (road != null) parts.add(road);
      if (village != null) parts.add(village);
      if (city != null) parts.add(city);
      if (state != null) parts.add(state);

      return parts.isNotEmpty ? parts.join(', ') : data['display_name'];
    } catch (e) {
      return null;
    }
  }
}
