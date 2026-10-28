import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WatermarkSettings extends ChangeNotifier {
  static const _keyOperator = 'wm_operator_name';
  static const _keyLogoPath = 'wm_logo_path';
  static const _keyWatermarkStyle = 'wm_style';
  static const _keyWatermarkPosition = 'wm_position';

  String _operatorName = '';
  String? _logoPath;
  String _watermarkStyle = 'classic';
  String _watermarkPosition = 'bottomRight';

  String get operatorName => _operatorName;
  String? get logoPath => _logoPath;
  String get watermarkStyle => _watermarkStyle;
  String get watermarkPosition => _watermarkPosition;

  bool get hasLogo => _logoPath != null && File(_logoPath!).existsSync();

  static final WatermarkSettings _instance = WatermarkSettings._internal();
  factory WatermarkSettings() => _instance;
  WatermarkSettings._internal();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _operatorName = prefs.getString(_keyOperator) ?? '';
    _logoPath = prefs.getString(_keyLogoPath);
    final savedStyle = prefs.getString(_keyWatermarkStyle) ?? 'classic';
    _watermarkStyle = const {'classic', 'compact', 'top', 'modern', 'minimal', 'badge'}.contains(savedStyle)
        ? savedStyle
        : 'classic';
    final savedPosition = prefs.getString(_keyWatermarkPosition) ?? 'bottomRight';
    _watermarkPosition = const {
      'topLeft', 'topCenter', 'topRight', 'centerLeft', 'center',
      'centerRight', 'bottomLeft', 'bottomCenter', 'bottomRight',
    }.contains(savedPosition) ? savedPosition : 'bottomRight';
    notifyListeners();
  }

  Future<void> setOperatorName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyOperator, name);
    _operatorName = name;
    notifyListeners();
  }

  Future<void> setLogoPath(String? path) async {
    // Persist first: if SharedPreferences throws, keep the in-memory value
    // consistent with the value that was previously saved.
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove(_keyLogoPath);
    } else {
      await prefs.setString(_keyLogoPath, path);
    }
    _logoPath = path;
    notifyListeners();
  }
  Future<void> setWatermarkPosition(String position) async {
    const supported = {
      'topLeft', 'topCenter', 'topRight', 'centerLeft', 'center',
      'centerRight', 'bottomLeft', 'bottomCenter', 'bottomRight',
    };
    final normalized = supported.contains(position) ? position : 'bottomRight';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWatermarkPosition, normalized);
    _watermarkPosition = normalized;
    notifyListeners();
  }

  Future<void> setWatermarkStyle(String style) async {
    const supported = {'classic', 'compact', 'top', 'modern', 'minimal', 'badge'};
    final normalized = supported.contains(style) ? style : 'classic';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWatermarkStyle, normalized);
    _watermarkStyle = normalized;
    notifyListeners();
  }
}

