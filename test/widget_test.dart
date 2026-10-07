import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termulscan/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const WHScannerApp(home: SizedBox.shrink()),
    );
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);

    // WHScannerApp starts a periodic recovery monitor in initState().
    // Dispose the app so the singleton timer is cancelled at test teardown.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
