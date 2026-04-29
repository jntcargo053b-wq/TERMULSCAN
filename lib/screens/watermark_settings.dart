import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WatermarkSettings extends ChangeNotifier {
  static const _keyOperator = 'wm_operator_name';
  static const _keyLogoPath = 'wm_logo_path';

  String _operatorName = '';
  String? _logoPath;

  String get operatorName => _operatorName;
  String? get logoPath => _logoPath;

  bool get hasLogo => _logoPath != null && File(_logoPath!).existsSync();

  static final WatermarkSettings _instance = WatermarkSettings._internal();
  factory WatermarkSettings() => _instance;
  WatermarkSettings._internal();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _operatorName = prefs.getString(_keyOperator) ?? '';
    _logoPath = prefs.getString(_keyLogoPath);
    notifyListeners();
  }

  Future<void> setOperatorName(String name) async {
    _operatorName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyOperator, name);
    notifyListeners();
  }

  Future<void> setLogoPath(String? path) async {
    _logoPath = path;
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove(_keyLogoPath);
    } else {
      await prefs.setString(_keyLogoPath, path);
    }
    notifyListeners();
  }
}
