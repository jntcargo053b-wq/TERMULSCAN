import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// OCR lokal untuk fallback pembacaan AWB dari foto galeri.
///
/// Barcode tetap menjadi sumber utama. AWB hanya dikembalikan jika ditemukan
/// pada baris dengan label eksplisit dan tidak ada kandidat berbeda yang
/// membuat hasilnya ambigu.
class ReceiptOcrService {
  ReceiptOcrService._();

  static final RegExp _labelledAwb = RegExp(
    r'\b(?:AWB|WAYBILL|TRACKING(?:\s*(?:NO|NUMBER))?|NO\.?\s*RESI|NOMOR\s*RESI|RESI)\b\s*[:#\-]?\s*([A-Z0-9][A-Z0-9\-/]{6,29})',
    caseSensitive: false,
  );

  static Future<String> recognizeText(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw FileSystemException('File untuk OCR tidak ditemukan', imagePath);
    }

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final input = InputImage.fromFilePath(imagePath);
      final result = await recognizer.processImage(input);
      return result.text;
    } finally {
      await recognizer.close();
    }
  }

  static String? extractAwbCandidate(String recognizedText) {
    final candidates = <String>{};
    for (final line in recognizedText.split(RegExp(r'[\r\n]+'))) {
      final match = _labelledAwb.firstMatch(line.trim());
      if (match == null) continue;
      final value = match.group(1)?.toUpperCase().trim();
      if (value == null || value.length < 8) continue;
      candidates.add(value);
    }

    // Lebih baik meminta operator input manual daripada mengisi AWB yang salah.
    if (candidates.length != 1) return null;
    return candidates.single;
  }
}
