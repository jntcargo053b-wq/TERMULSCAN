import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termulscan/screens/watermark_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WatermarkSettings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = WatermarkSettings();
    await settings.load();
  });

  test('new installations default to the Timemark reference layout', () {
    expect(settings.watermarkStyle, 'timemark');
  });

  test('operator name and watermark style persist after reload', () async {
    await settings.setOperatorName('Operator Gudang');
    await settings.setWatermarkStyle('modern');

    // Reload from SharedPreferences, as happens when the app/screen opens again.
    await settings.load();

    expect(settings.operatorName, 'Operator Gudang');
    expect(settings.watermarkStyle, 'modern');
  });

  test('custom Timemark text persists after reload and can be cleared', () async {
    await settings.setCustomText('PT Contoh Logistik - Gudang Malang');
    await settings.load();
    expect(settings.customText, 'PT Contoh Logistik - Gudang Malang');

    await settings.setCustomText('');
    await settings.load();
    expect(settings.customText, isEmpty);
  });

  test('all supported watermark styles can be restored', () async {
    const styles = ['classic', 'timemark', 'compact', 'top', 'modern', 'minimal', 'badge'];

    for (final style in styles) {
      await settings.setWatermarkStyle(style);
      await settings.load();
      expect(settings.watermarkStyle, style);
    }
  });

  test('all nine watermark positions persist after reload', () async {
    const positions = [
      'topLeft', 'topCenter', 'topRight',
      'centerLeft', 'center', 'centerRight',
      'bottomLeft', 'bottomCenter', 'bottomRight',
    ];

    for (final position in positions) {
      await settings.setWatermarkPosition(position);
      await settings.load();
      expect(settings.watermarkPosition, position);
    }
  });

  test('unsupported position setter stores the safe default', () async {
    await settings.setWatermarkPosition('not-a-position');

    expect(settings.watermarkPosition, 'bottomRight');
    await settings.load();
    expect(settings.watermarkPosition, 'bottomRight');
  });

  test('unknown saved position safely falls back to bottomRight', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wm_position', 'unsupported-position');

    await settings.load();

    expect(settings.watermarkPosition, 'bottomRight');
  });

  test('unknown saved style safely falls back to classic', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wm_style', 'unsupported-style');

    await settings.load();

    expect(settings.watermarkStyle, 'classic');
  });

  test('logo path persists and can be cleared', () async {
    final tempDir = await Directory.systemTemp.createTemp('termulscan-settings-');
    addTearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
    final logoPath = '${tempDir.path}/wm_logo.png';

    await settings.setLogoPath(logoPath);
    await settings.load();
    expect(settings.logoPath, logoPath);

    await settings.setLogoPath(null);
    await settings.load();
    expect(settings.logoPath, isNull);
  });
}
