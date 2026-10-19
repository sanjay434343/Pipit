import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path_provider/path_provider.dart';

/// Service providing Google ML Kit OCR for images and direct + OCR extraction for PDFs.
/// For digital PDFs: extracts text directly using Syncfusion PDF TextExtractor.
/// For scanned image PDFs: extracts page image streams and applies Google ML Kit Text Recognition page-by-page.
class TextExtractionService {
  TextExtractionService._internal();
  static final TextExtractionService instance = TextExtractionService._internal();

  TextRecognizer? _textRecognizer;

  TextRecognizer get textRecognizer {
    _textRecognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
    return _textRecognizer!;
  }

  /// Extracts readable text from an image file using Google ML Kit Text Recognition
  Future<String> extractTextFromImage(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return '';

      final inputImage = InputImage.fromFilePath(imagePath);
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
      return recognizedText.text.trim();
    } catch (e) {
      debugPrint('[TextExtractionService] Error extracting text from image $imagePath: $e');
      return '';
    }
  }

  /// Extracts readable text from a PDF document.
  /// 1. Attempts digital text extraction via Syncfusion PDF.
  /// 2. If text is empty or too short (scanned PDF), extracts page image streams and runs Google ML Kit OCR on each page.
  Future<String> extractTextFromPdf(String pdfPath, {int maxPagesForOcr = 10}) async {
    PdfDocument? document;
    try {
      final file = File(pdfPath);
      if (!await file.exists()) return '';

      final bytes = await file.readAsBytes();
      document = PdfDocument(inputBytes: bytes);

      // Step 1: Direct text extraction using Syncfusion PDF
      final PdfTextExtractor extractor = PdfTextExtractor(document);
      final String directText = extractor.extractText().trim();

      // If we extracted digital text, return it directly
      if (directText.isNotEmpty) {
        return directText;
      }

      // Step 2: Fallback for Scanned / Image PDFs
      // Extract embedded page images and run OCR on each page
      final List<Uint8List> embeddedImages = extractEmbeddedJpegImages(bytes, maxImages: maxPagesForOcr);
      final StringBuffer ocrBuffer = StringBuffer();

      if (directText.isNotEmpty) {
        ocrBuffer.writeln(directText);
      }

      Directory? tempDir;
      try {
        tempDir = await getTemporaryDirectory();
      } catch (_) {
        tempDir = Directory.systemTemp;
      }

      for (int i = 0; i < embeddedImages.length; i++) {
        final Uint8List imageBytes = embeddedImages[i];
        final tempFile = File('${tempDir.path}/pdf_page_${i}_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await tempFile.writeAsBytes(imageBytes);

        try {
          final pageOcr = await extractTextFromImage(tempFile.path);
          if (pageOcr.trim().isNotEmpty) {
            ocrBuffer.writeln('--- Page ${i + 1} ---');
            ocrBuffer.writeln(pageOcr.trim());
          }
        } finally {
          if (await tempFile.exists()) {
            await tempFile.delete().catchError((_) => tempFile);
          }
        }
      }

      final combined = ocrBuffer.toString().trim();
      return combined.isNotEmpty ? combined : directText;
    } catch (e) {
      debugPrint('[TextExtractionService] Error extracting text from PDF $pdfPath: $e');
      return '';
    } finally {
      document?.dispose();
    }
  }

  /// Extracts embedded JPEG image byte streams from a PDF byte array.
  /// Scanner apps (CamScanner, Google Drive Scan, printers) store scanned pages as JPEG streams.
  static List<Uint8List> extractEmbeddedJpegImages(Uint8List pdfBytes, {int maxImages = 10}) {
    final List<Uint8List> images = [];
    int index = 0;
    final int length = pdfBytes.length;

    while (index < length - 4 && images.length < maxImages) {
      // Look for JPEG SOI (Start Of Image) marker: 0xFF, 0xD8, 0xFF
      if (pdfBytes[index] == 0xFF &&
          pdfBytes[index + 1] == 0xD8 &&
          pdfBytes[index + 2] == 0xFF) {
        final int startIndex = index;
        int endIndex = -1;

        // Scan for JPEG EOI (End Of Image) marker: 0xFF, 0xD9
        int searchIdx = startIndex + 3;
        while (searchIdx < length - 1) {
          if (pdfBytes[searchIdx] == 0xFF && pdfBytes[searchIdx + 1] == 0xD9) {
            endIndex = searchIdx + 2;
            break;
          }
          searchIdx++;
        }

        if (endIndex != -1) {
          final int size = endIndex - startIndex;
          // Scanned page images are typically > 2KB
          if (size > 2048) {
            images.add(pdfBytes.sublist(startIndex, endIndex));
            index = endIndex;
            continue;
          }
        }
      }
      index++;
    }

    return images;
  }

  /// Disposes of the ML Kit text recognizer resources
  void dispose() {
    _textRecognizer?.close();
    _textRecognizer = null;
  }
}
