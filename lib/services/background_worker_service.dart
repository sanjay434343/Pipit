import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'ai_service.dart';
import 'database_service.dart';
import 'image_collector_service.dart';
import 'duplicate_remover_service.dart';
import 'text_extraction_service.dart';
import 'document_collector_service.dart';

/// Background Worker Service
/// Manages running image scanning, AI model embedding, and OCR text extraction in the background.
/// Runs ONLY when processing is in progress, and automatically stops
/// as soon as all pending tasks are completed.
class BackgroundWorkerService with ChangeNotifier {
  BackgroundWorkerService._internal();
  static final BackgroundWorkerService instance = BackgroundWorkerService._internal();

  bool _isBackgroundWorkerActive = false;
  bool _isImageEmbeddingActive = false;
  bool _isDocumentExtractionActive = false;
  int _pendingCount = 0;
  int _completedCount = 0;
  int _totalCount = 0;
  String _workerStatus = 'Idle (Worker auto-stopped)';

  bool get isBackgroundWorkerActive => _isBackgroundWorkerActive || _isDocumentExtractionActive;
  bool get isImageEmbeddingActive => _isImageEmbeddingActive;
  bool get isDocumentExtractionActive => _isDocumentExtractionActive;
  bool get isPaused => AiService.instance.isPaused;
  int get pendingCount => _pendingCount;
  int get completedCount => _completedCount;
  int get totalCount => _totalCount;
  String get workerStatus => _workerStatus;
  int? get lastBatchLatencyMs => AiService.instance.lastBatchLatencyMs;

  /// Start background embedding worker for unprocessed items (Top Priority).
  /// Runs only during the embedding duration and auto-stops immediately upon completion.
  Future<void> startWorker<T extends EmbeddableItem>(
    List<T> items, {
    VoidCallback? onBatchProgress,
    VoidCallback? onFinished,
  }) async {
    if (!AiService.instance.isModelLoaded) {
      _workerStatus = 'No AI Model Loaded';
      _isBackgroundWorkerActive = false;
      _isImageEmbeddingActive = false;
      notifyListeners();
      return;
    }

    // Process ALL items missing vector embeddings
    final pending = items.where((i) => i.embedding == null).toList();
    if (pending.isEmpty) {
      _isBackgroundWorkerActive = false;
      _isImageEmbeddingActive = false;
      _workerStatus = 'All photos processed. Worker auto-stopped.';
      notifyListeners();
      onFinished?.call();
      return;
    }

    _isBackgroundWorkerActive = true;
    _isImageEmbeddingActive = true;
    _pendingCount = pending.length;
    _totalCount = items.length;
    _completedCount = items.length - pending.length;
    _workerStatus = 'Image Vision AI: $_completedCount/${items.length} ($_pendingCount pending)';
    notifyListeners();

    debugPrint('🚀 [BackgroundWorkerService] Started TOP PRIORITY image embedding for $_pendingCount photos.');

    try {
      await AiService.instance.embedAll<T>(
        items,
        onBatchCompleted: () {
          final remaining = items.where((i) => i.embedding == null).length;
          _pendingCount = remaining;
          _completedCount = items.length - remaining;
          _workerStatus = 'Image Vision AI: $_completedCount/${items.length} processed';
          notifyListeners();
          onBatchProgress?.call();

          // Auto-stop condition: if all pending items are finished, stop worker immediately!
          if (remaining == 0) {
            _isImageEmbeddingActive = false;
            stopWorker(autoStop: true);
            onFinished?.call();
          }
        },
      );
    } catch (e) {
      debugPrint('[BackgroundWorkerService] Worker exception: $e');
    } finally {
      _isImageEmbeddingActive = false;
      stopWorker(autoStop: true);
      onFinished?.call();
    }
  }

  /// Stop the background worker immediately
  void stopWorker({bool autoStop = true}) {
    _isImageEmbeddingActive = false;
    if (_isBackgroundWorkerActive || AiService.instance.isIndexing) {
      _isBackgroundWorkerActive = false;
      _workerStatus = autoStop
          ? 'Indexing finished. Worker auto-stopped.'
          : 'Worker stopped by user.';
      AiService.instance.stopIndexing();
      debugPrint('🛑 [BackgroundWorkerService] Worker auto-stopped ($workerStatus).');
      notifyListeners();
    }
  }

  /// Pause current background processing
  void pauseWorker() {
    AiService.instance.pauseIndexing();
    _workerStatus = 'Background Worker paused';
    notifyListeners();
  }

  /// Resume background processing
  void resumeWorker() {
    AiService.instance.resumeIndexing();
    _workerStatus = 'Background Worker resumed (Processing $_pendingCount photos)...';
    notifyListeners();
  }

  /// Run full background scan and embedding pipeline:
  /// 1. Finds new non-WhatsApp photos
  /// 2. Deduplicates & stores to SQLite DB
  /// 3. Embeds unprocessed photos using loaded model
  /// 4. Auto-stops immediately once 0 photos remain!
  Future<void> scanAndEmbedNewImages({
    VoidCallback? onScanProgress,
    VoidCallback? onBatchProgress,
    VoidCallback? onCompleted,
  }) async {
    if (!AiService.instance.isModelLoaded) {
      _workerStatus = 'Cannot scan: Model not loaded';
      notifyListeners();
      return;
    }

    _isBackgroundWorkerActive = true;
    _workerStatus = 'Background Worker: Scanning storage for new photos...';
    notifyListeners();

    try {
      // Use lightweight query: scan only needs paths + SHA keys, not BLOBs
      final cachedDbRecords = await DatabaseService.instance.getAllRecordsLightweight();
      final knownPaths = cachedDbRecords.keys.toSet();
      final knownShaKeys = cachedDbRecords.values
          .where((r) => r.shaKey != null && r.shaKey!.isNotEmpty)
          .map((r) => r.shaKey!)
          .toSet();

      final newRawImages = await ImageCollectorService.instance.collectNewImagesOnly(
        existingPaths: knownPaths,
      );

      if (newRawImages.isNotEmpty) {
        final dedupResult = DuplicateRemoverService.instance.removeDuplicates(
          newRawImages,
          existingShaKeys: knownShaKeys,
        );

        if (dedupResult.uniqueItems.isNotEmpty) {
          final newRecords = dedupResult.uniqueItems.map((raw) {
            return CachedImageRecord(
              path: raw.path,
              name: raw.name,
              fileSize: raw.fileSize,
              modifiedTimestamp: raw.modifiedDate.millisecondsSinceEpoch,
              location: raw.location,
              shaKey: raw.shaKey,
              isProcessed: false,
              embedding: null,
            );
          }).toList();

          await DatabaseService.instance.saveBatch(newRecords);
        }
      }

      onScanProgress?.call();
    } catch (e) {
      debugPrint('[BackgroundWorkerService] Scan error: $e');
    } finally {
      // Auto-stop will be performed when embedding completes
    }
  }

  /// Process OCR on images in background and store extracted text in DB
  Future<void> runOcrOnImages(
    List<String> imagePaths, {
    void Function(String path, String text)? onOcrExtracted,
    VoidCallback? onFinished,
  }) async {
    if (imagePaths.isEmpty) {
      onFinished?.call();
      return;
    }

    // Yield to image embedding (Image embedding is Top Priority)
    while (_isImageEmbeddingActive) {
      await Future.delayed(const Duration(milliseconds: 400));
    }

    _isBackgroundWorkerActive = true;
    _pendingCount = imagePaths.length;
    _completedCount = 0;
    _totalCount = imagePaths.length;
    _workerStatus = 'Image OCR: $_pendingCount photos pending...';
    notifyListeners();

    try {
      for (int i = 0; i < imagePaths.length; i++) {
        // Yield to image embedding (Image embedding is Top Priority)
        while (_isImageEmbeddingActive) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
        final path = imagePaths[i];
        final text = await TextExtractionService.instance.extractTextFromImage(path);
        if (text.isNotEmpty) {
          await DatabaseService.instance.updateImageOcrText(path, text);
          onOcrExtracted?.call(path, text);
        }
        _completedCount = i + 1;
        _pendingCount = imagePaths.length - _completedCount;
        _workerStatus = 'Image OCR: $_completedCount/${imagePaths.length} photos';
        notifyListeners();
        // Give event loop a breath
        await Future.delayed(const Duration(milliseconds: 10));
      }
    } catch (e) {
      debugPrint('[BackgroundWorkerService] OCR exception: $e');
    } finally {
      stopWorker(autoStop: true);
      onFinished?.call();
    }
  }

  /// Process Document text extraction / OCR in background and save in DB
  Future<void> runExtractionOnDocuments(
    List<DeviceDocument> docs, {
    void Function(DeviceDocument doc, String text)? onDocExtracted,
    VoidCallback? onFinished,
  }) async {
    final pending = docs
        .where(
          (d) =>
              !d.isProcessed &&
              (!d.isOcrProcessed ||
                  (d.embedding == null && AiService.instance.isModelLoaded)),
        )
        .toList();
    if (pending.isEmpty) {
      onFinished?.call();
      return;
    }

    _isDocumentExtractionActive = true;
    _pendingCount = pending.length;
    _totalCount = pending.length;
    _completedCount = 0;
    _workerStatus = 'Document AI: ${pending.length} docs pending...';
    notifyListeners();

    try {
      for (int i = 0; i < pending.length; i++) {
        final doc = pending[i];
        if (doc.isProcessed) {
          _completedCount = i + 1;
          _pendingCount = pending.length - (i + 1);
          notifyListeners();
          continue;
        }

        String extracted = '';

        if (doc.extractedText != null && doc.extractedText!.isNotEmpty) {
          extracted = doc.extractedText!;
        } else if (!doc.isOcrProcessed) {
          if (doc.category == DocumentCategory.pdf) {
            extracted = await TextExtractionService.instance.extractTextFromPdf(doc.path);
          } else if (doc.category == DocumentCategory.text) {
            try {
              final f = File(doc.path);
              if (await f.exists()) {
                extracted = await f.readAsString();
              }
            } catch (_) {}
          }
        } else {
          extracted = doc.extractedText ?? '';
        }

        doc.isOcrProcessed = true;
        doc.extractedText = extracted;

        if (AiService.instance.isModelLoaded && doc.embedding == null) {
          await AiService.instance.embedDocument(doc);
        }

        doc.isProcessed = true;

        await DatabaseService.instance.updateDocumentOcrAndEmbedding(
          doc.path,
          extracted,
          embedding: doc.embedding,
          isProcessed: true,
        );

        if (extracted.isNotEmpty) {
          onDocExtracted?.call(doc, extracted);
        }

        _completedCount = i + 1;
        _pendingCount = pending.length - (i + 1);
        _workerStatus = 'Document OCR: ${i + 1}/${pending.length} docs';
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 10));
      }
    } catch (e) {
      debugPrint('[BackgroundWorkerService] Document extraction exception: $e');
    } finally {
      _isDocumentExtractionActive = false;
      _pendingCount = 0;
      _totalCount = 0;
      _completedCount = 0;
      _workerStatus = 'Document processing finished.';
      notifyListeners();
      onFinished?.call();
    }
  }
}

