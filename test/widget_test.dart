import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termulscan/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const WHScannerApp());
    await tester.pump();

    // WHScannerApp starts a periodic recovery monitor in initState().
    // Dispose the app in the test so the singleton timer is cancelled just
    // as it would be when the real app is disposed.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
