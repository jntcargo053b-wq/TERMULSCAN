import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class LocationService {
  static final _instance = LocationService._();
  factory LocationService() => _instance;
  LocationService._();

  static const _channel = MethodChannel('com.termulscan.app/location');

  Future<({double? lat, double? lng, String? address})> getLocation({
    bool forceRefresh = false,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('getLocation');
      if (result == null) return (lat: null, lng: null, address: null);

      final lat = (result['lat'] as num?)?.toDouble();
      final lng = (result['lng'] as num?)?.toDouble();
      final accuracy = (result['accuracy'] as num?)?.toDouble();

      if (lat == null || lng == null) {
        return (lat: null, lng: null, address: null);
      }

      // Reverse geocoding via Nominatim — detail level disesuaikan akurasi GPS
      final address = await _reverseGeocode(lat, lng, accuracy: accuracy);

      return (lat: lat, lng: lng, address: address);
    } catch (e) {
      return (lat: null, lng: null, address: null);
    }
  }

  Future<String?> _reverseGeocode(double lat, double lng, {double? accuracy}) async {
    try {
      // FIX GPS DETAIL – kalau akurasi GPS kasar (>=20m), jangan tampilkan
      // jalan/dusun detail (bisa menyesatkan), cukup kecamatan & kota saja.
      // zoom Nominatim: 18 = jalan/bangunan, 14 = kecamatan/suburb, 10 = kota
      final bool isCoarse = accuracy != null && accuracy >= 20;
      final int zoom = isCoarse ? 14 : 18;

      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=$lat&lon=$lng&format=json&addressdetails=1&zoom=$zoom',
      );

      final response = await http.get(uri, headers: {
        'User-Agent': 'WHScanner/1.0',
        'Accept-Language': 'id', // Bahasa Indonesia
      }).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return null;

      final data = json.decode(response.body);
      final addr = data['address'];
      if (addr == null) return null;

      final parts = <String>[];

      final city = addr['city'] ?? addr['town'] ?? addr['regency'] ?? addr['county'];
      final state = addr['state'];

      if (isCoarse) {
        // Akurasi kasar (>= 20m): cukup kecamatan + kota, tanpa jalan/dusun
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
        // Akurasi bagus (< 20m): tampilkan detail lengkap
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
