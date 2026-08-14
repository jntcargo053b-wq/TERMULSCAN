import 'package:flutter/foundation.dart';

class WatermarkSettings with ChangeNotifier {
  bool _showTimestamp = true;
  bool _showLocation = true;
  bool _showBarcode = true;
  double _fontSize = 14.0;
  String _fontColor = '#FFFFFF';
  String _position = 'bottom'; // bottom, top, center

  bool get showTimestamp => _showTimestamp;
  bool get showLocation => _showLocation;
  bool get showBarcode => _showBarcode;
  double get fontSize => _fontSize;
  String get fontColor => _fontColor;
  String get position => _position;

  void toggleTimestamp() {
    _showTimestamp = !_showTimestamp;
    notifyListeners();
  }

  void toggleLocation() {
    _showLocation = !_showLocation;
    notifyListeners();
  }

  void toggleBarcode() {
    _showBarcode = !_showBarcode;
    notifyListeners();
  }

  void setFontSize(double size) {
    _fontSize = size;
    notifyListeners();
  }

  void setFontColor(String color) {
    _fontColor = color;
    notifyListeners();
  }

  void setPosition(String pos) {
    _position = pos;
    notifyListeners();
  }

  // PENTING: Method ini harus dipanggil saat widget yang menggunakan settings ini di-dispose
  @override
  void dispose() {
    // Cleanup listeners if any were added externally (optional but good practice)
    super.dispose();
  }
}
