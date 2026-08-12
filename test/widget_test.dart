
import 'package:flutter_test/flutter_test.dart';
import 'package:termulscan/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const WHScannerApp());
  });
}
