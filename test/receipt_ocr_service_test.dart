import 'package:flutter_test/flutter_test.dart';
import 'package:termulscan/services/receipt_ocr_service.dart';

void main() {
  group('ReceiptOcrService AWB extraction', () {
    test('extracts AWB from an explicit label', () {
      expect(
        ReceiptOcrService.extractAwbCandidate(
          'PENERIMA: BUDI\nAWB: JX1234567890\nTOTAL: 125000',
        ),
        'JX1234567890',
      );
    });

    test('supports Indonesian receipt labels and numeric resi', () {
      expect(
        ReceiptOcrService.extractAwbCandidate(
          'NOMOR RESI : 123456789012\nTUJUAN: MALANG',
        ),
        '123456789012',
      );
    });

    test('does not guess AWB from unlabeled numbers', () {
      expect(
        ReceiptOcrService.extractAwbCandidate(
          '123456789012\nTOTAL: 125000\nTANGGAL: 14/11/2026',
        ),
        isNull,
      );
    });

    test('returns null when multiple different AWBs are labelled', () {
      expect(
        ReceiptOcrService.extractAwbCandidate(
          'AWB: JX12345678\nRESI: NX98765432',
        ),
        isNull,
      );
    });

    test('ignores short values after a label', () {
      expect(
        ReceiptOcrService.extractAwbCandidate('AWB: 12345'),
        isNull,
      );
    });
  });
}
