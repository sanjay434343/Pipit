import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:path_provider/path_provider.dart';
import 'database_service.dart';
import 'model_storage_service.dart';
import 'document_collector_service.dart';

/// Configuration dynamically loaded directly from ai_config.json
class AiConfig {
  final Map<String, dynamic> raw;

  AiConfig(this.raw);

  String get serviceName => raw['service_name'] as String? ?? '';
  String get defaultBackend => (raw['backend'] as Map<String, dynamic>?)?['default'] as String? ?? 'GPU';
  int get defaultThreads => (raw['concurrency'] as Map<String, dynamic>?)?['default_threads'] as int? ?? 4;
  List<int> get threadPresets =>
      ((raw['concurrency'] as Map<String, dynamic>?)?['available_thread_presets'] as List<dynamic>?)
          ?.map((e) => (e as num).toInt())
          .toList() ??
      [1, 2, 4, 8, 12, 16];
  int get maxSequenceTokens => (raw['tokens'] as Map<String, dynamic>?)?['max_sequence_length'] as int? ?? 512;
  int get maxOutputTokens => (raw['tokens'] as Map<String, dynamic>?)?['max_output_tokens'] as int? ?? 128;
  int get contextWindowTokens => (raw['tokens'] as Map<String, dynamic>?)?['context_window_tokens'] as int? ?? 2048;
  int? get modelDimension => AiService.instance.vectorDimension;
  bool get supportImage => (raw['vision'] as Map<String, dynamic>?)?['support_image'] as bool? ?? true;
  int get maxImageDimensionPx => (raw['vision'] as Map<String, dynamic>?)?['max_image_dimension_px'] as int? ?? 384;
  int get nativeDecodingMaxBytes =>
      (raw['vision'] as Map<String, dynamic>?)?['native_decoding_max_bytes'] as int? ?? 2500000;
}

/// Image item interface for embedding operations
abstract class EmbeddableItem {
  String get id;
  String get path;
  String get name;
  int get fileSize;
  bool get isProcessed;
  set isProcessed(bool value);
  List<double>? get embedding;
  set embedding(List<double>? value);
  bool get isEmbedding;
  set isEmbedding(bool value);
  double? get score;
  set score(double? value);
}

/// Singleton AI Service that handles LiteRT-LM initialization, model lifecycle,
/// parallel worker execution, image optimization and token-aware semantic search.
class AiService with ChangeNotifier {
  AiService._internal();
  static final AiService instance = AiService._internal();

  late AiConfig _config = AiConfig({});
  AiConfig get config => _config;

  EmbeddingModel? _embeddingModel;
  EmbeddingModel? get embeddingModel => _embeddingModel;

  bool _isInitialized = false;
  bool _isModelLoaded = false;
  String? _currentModelPath;
  String? _currentModelName;
  int? _vectorDimension;
  String _activeBackend = 'GPU';
  int _parallelThreads = 4;
  bool _isIndexing = false;
  bool _isPaused = false;
  int? _lastBatchLatencyMs;
  int? _lastSearchLatencyMs;

  bool get isModelLoaded => _isModelLoaded && _embeddingModel != null;
  String? get currentModelName => _currentModelName;
  String? get currentModelPath => _currentModelPath;
  int? get vectorDimension => _vectorDimension;
  String get activeBackend => _activeBackend;
  String? _backendStatusReason;
  String? get backendStatusReason => _backendStatusReason;
  int get parallelThreads => _parallelThreads;
  bool get isIndexing => _isIndexing;
  bool get isPaused => _isPaused;
  int? get lastBatchLatencyMs => _lastBatchLatencyMs;
  int? get lastSearchLatencyMs => _lastSearchLatencyMs;

  void pauseIndexing() {
    _isPaused = true;
  }

  void resumeIndexing() {
    _isPaused = false;
  }

  void stopIndexing() {
    _isIndexing = false;
    _isPaused = false;
  }

  void setParallelThreads(int threads) {
    _parallelThreads = threads;
  }

  /// Reload config directly from ai_config.json so any JSON edits reflect immediately
  Future<void> reloadConfig() async {
    try {
      final jsonFile = File('lib/services/ai_config.json');
      String content;
      if (await jsonFile.exists()) {
        content = await jsonFile.readAsString();
      } else {
        content = await rootBundle.loadString('lib/services/ai_config.json');
      }
      final parsed = jsonDecode(content) as Map<String, dynamic>;
      _config = AiConfig(parsed);
      _parallelThreads = _config.defaultThreads;
    } catch (e) {
      debugPrint('Error loading ai_config.json: $e');
    }
  }

  /// Initialize engine and load JSON configuration from ai_config.json.
  /// Automatically restores the last used model from disk if available.
  Future<void> initialize() async {
    if (_isInitialized) {
      await reloadConfig();
      return;
    }

    await reloadConfig();

    // Initialize edge AI engines
    try {
      await FlutterEdgeAi.initialize(
        inferenceEngines: const [LiteRtLmEngine()],
        embeddingBackends: const [LiteRtEmbeddingBackend()],
      );
      _isInitialized = true;
    } catch (e) {
      debugPrint('FlutterEdgeAi.initialize info: $e');
      _isInitialized = true;
    }

    // Auto-restore previously loaded model from persisted path
    await _tryRestorePersistedModel();
    if (!_isModelLoaded) {
      await ModelStorageService.instance.autoLoadModelToRam();
    }
    notifyListeners();
  }

  // ─── Model Persistence ──────────────────────────────────────────────────────

  static const String _kModelPersistFile = 'pipit_model_prefs.json';

  Future<File> _modelPrefsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_kModelPersistFile');
  }

  /// Save current model path + backend selection so it can be restored on next launch.
  Future<void> _persistModelPrefs() async {
    if (_currentModelPath == null || _currentModelName == null) return;
    try {
      final file = await _modelPrefsFile();
      final data = jsonEncode({
        'model_path': _currentModelPath,
        'model_name': _currentModelName,
        'backend': _preferredBackend.name,
      });
      await file.writeAsString(data);
    } catch (e) {
      debugPrint('[AiService] Could not persist model prefs: $e');
    }
  }

  /// Attempt to restore the last used model from disk.
  Future<void> _tryRestorePersistedModel() async {
    try {
      final file = await _modelPrefsFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final path = data['model_path'] as String?;
      final name = data['model_name'] as String?;
      final backendStr = data['backend'] as String? ?? 'gpu';
      if (path == null || name == null) return;
      if (!await File(path).exists()) {
        debugPrint('[AiService] Persisted model file no longer exists: $path');
        return;
      }
      final backend = PreferredBackend.values.firstWhere(
        (b) => b.name == backendStr,
        orElse: () => PreferredBackend.gpu,
      );
      debugPrint('[AiService] Auto-restoring model: $name from $path');
      await loadModel(path, name, preferredBackend: backend);
    } catch (e) {
      debugPrint('[AiService] Could not restore persisted model: $e');
    }
  }

  PreferredBackend _preferredBackend = PreferredBackend.gpu;
  PreferredBackend get preferredBackend => _preferredBackend;

  void setPreferredBackend(PreferredBackend backend) {
    _preferredBackend = backend;
  }

  /// Switch the active backend of currently loaded model (e.g. from CPU to GPU or vice-versa)
  Future<void> switchBackend(PreferredBackend targetBackend) async {
    _preferredBackend = targetBackend;
    if (_currentModelPath != null && _currentModelName != null) {
      await loadModel(_currentModelPath!, _currentModelName!, preferredBackend: targetBackend);
    }
  }

  /// Load a model from file with strict GPU priority if available.
  /// Skips reload if the exact same model file + backend is already loaded.
  Future<void> loadModel(
    String filePath,
    String fileName, {
    PreferredBackend? preferredBackend,
  }) async {
    final targetBackend = preferredBackend ?? _preferredBackend;

    // ── Guard: skip reload if same model + same backend are already active ──
    if (_isModelLoaded &&
        _embeddingModel != null &&
        _currentModelPath == filePath &&
        _currentModelName == fileName &&
        _preferredBackend == targetBackend) {
      debugPrint('[AiService] Model already loaded, skipping redundant reload.');
      return;
    }

    _currentModelPath = filePath;
    _currentModelName = fileName;
    if (preferredBackend != null) {
      _preferredBackend = preferredBackend;
    }

    // Install model file into embedder
    await FlutterEdgeAi.installEmbedder()
        .modelFromFile(filePath)
        .install();

    // 1. Try GPU first (with vision if configured)
    _backendStatusReason = null;
    String? gpuError;
    if (_preferredBackend == PreferredBackend.gpu) {
      try {
        debugPrint('🚀 Requesting GPU backend for embedder (supportImage: ${_config.supportImage})...');
        _embeddingModel = await FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: PreferredBackend.gpu,
          supportImage: _config.supportImage,
        );
      } catch (eGpu) {
        gpuError = '$eGpu';
        debugPrint('GPU embedder with supportImage failed: $eGpu. Trying GPU without supportImage...');
        try {
          _embeddingModel = await FlutterEdgeAi.getActiveEmbedder(
            preferredBackend: PreferredBackend.gpu,
            supportImage: false,
          );
        } catch (eGpu2) {
          gpuError = '$eGpu2';
          debugPrint('GPU embedder without supportImage failed: $eGpu2. Falling back to CPU...');
        }
      }
    } else if (_preferredBackend == PreferredBackend.npu) {
      try {
        _embeddingModel = await FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: PreferredBackend.npu,
          supportImage: _config.supportImage,
        );
      } catch (_) {
        try {
          _embeddingModel = await FlutterEdgeAi.getActiveEmbedder(
            preferredBackend: PreferredBackend.npu,
            supportImage: false,
          );
        } catch (_) {}
      }
    }

    // Fallback to CPU only if GPU/NPU was not available or threw an error
    if (_embeddingModel == null) {
      debugPrint('ℹ️ Attempting CPU embedder...');
      try {
        _embeddingModel = await FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: PreferredBackend.cpu,
          supportImage: _config.supportImage,
        );
      } catch (eCpu) {
        _embeddingModel = await FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: PreferredBackend.cpu,
          supportImage: false,
        );
      }
    }

    if (_embeddingModel != null) {
      _vectorDimension = _embeddingModel!.dimension;
      final backend = _embeddingModel!.activeBackend;
      _activeBackend = backend == PreferredBackend.gpu
          ? 'GPU'
          : backend == PreferredBackend.npu
              ? 'NPU'
              : 'CPU';
      _isModelLoaded = true;

      if (_preferredBackend == PreferredBackend.gpu && _activeBackend == 'CPU') {
        _backendStatusReason = gpuError != null
            ? 'GPU delegate unavailable on device: $gpuError'
            : 'LiteRT delegated EmbeddingGemma int4 quantized ops to multi-threaded CPU for numerical stability.';
      } else {
        _backendStatusReason = 'Model accelerated via $_activeBackend.';
      }
      debugPrint('✅ Model successfully loaded! Active Backend: $_activeBackend, Dimension: $_vectorDimension, Reason: $_backendStatusReason');

      // Persist successful model load so it can be restored on next app start
      unawaited(_persistModelPrefs());
      notifyListeners();
    } else {
      _isModelLoaded = false;
      notifyListeners();
      throw Exception('Failed to obtain active embedder on GPU or CPU.');
    }
  }

  /// Unloads the active in-memory model and clears cached state.
  Future<void> unloadModel() async {
    _embeddingModel = null;
    _isModelLoaded = false;
    _currentModelPath = null;
    _currentModelName = null;
    _vectorDimension = 0;
    _activeBackend = 'None';
    _backendStatusReason = null;
    try {
      final file = await _modelPrefsFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Prepare and downscale/format image bytes for high-efficiency embedding
  Future<Uint8List> prepareImageBytes(Uint8List rawBytes, [String? filePath]) async {
    final path = filePath?.toLowerCase() ?? '';
    final isNativeFormat = path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.png') ||
        (rawBytes.length >= 3 && rawBytes[0] == 0xFF && rawBytes[1] == 0xD8 && rawBytes[2] == 0xFF) ||
        (rawBytes.length >= 4 && rawBytes[0] == 0x89 && rawBytes[1] == 0x50 && rawBytes[2] == 0x4E && rawBytes[3] == 0x47);

    // Bypass decode only for already-compact images (< 150KB)
    if (isNativeFormat && rawBytes.length < 150 * 1024) {
      return rawBytes;
    }

    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(rawBytes);
      final maxDim = _config.maxImageDimensionPx.toDouble();
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (w, h) => math.max(w, h) <= maxDim
            ? const ui.TargetImageSize()
            : w >= h
                ? ui.TargetImageSize(width: maxDim.toInt())
                : ui.TargetImageSize(height: maxDim.toInt()),
      );
      final frame = await codec.getNextFrame();
      final pngData = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (pngData != null) {
        return pngData.buffer.asUint8List();
      }
    } catch (e) {
      debugPrint('prepareImageBytes exception: $e');
    }

    return rawBytes;
  }

  /// Embed single item with database caching and mark as processed
  Future<void> embedItem(EmbeddableItem item) async {
    if (_embeddingModel == null || item.embedding != null) {
      item.isEmbedding = false;
      return;
    }
    try {
      final ext = item.path.toLowerCase();
      final isImage = ext.endsWith('.jpg') ||
          ext.endsWith('.jpeg') ||
          ext.endsWith('.png') ||
          ext.endsWith('.webp') ||
          ext.endsWith('.gif') ||
          ext.endsWith('.bmp');

      if (!isImage) {
        if (item is DeviceDocument) {
          await embedDocument(item);
          return;
        }
        // For video, audio, and non-image files, use fast text embedding on name & path
        await embedItemByText(item, '${item.name} (${item.path})');
        return;
      }

      final file = File(item.path);
      if (await file.exists()) {
        final rawBytes = await file.readAsBytes();
        final prepBytes = await prepareImageBytes(rawBytes, item.path);
        final embeddingResult = await _embeddingModel!.embed(
          EmbeddingInput.image(prepBytes),
          taskType: TaskType.retrievalDocument,
        );
        item.embedding = embeddingResult;
        item.isProcessed = true;

        // Persist embedding and mark as processed in SQLite database
        DatabaseService.instance.markAsProcessed(
          item.path,
          embedding: embeddingResult,
        );
      }
    } catch (e) {
      debugPrint('Embedding error on ${item.name}: $e');
    } finally {
      item.isEmbedding = false;
    }
  }

  /// Embed an item via its text metadata (e.g. video / audio name & tags) without reading heavy binary media
  Future<void> embedItemByText(EmbeddableItem item, [String? customText]) async {
    if (_embeddingModel == null || item.isProcessed) {
      item.isEmbedding = false;
      return;
    }
    try {
      final textToEmbed = (customText != null && customText.isNotEmpty)
          ? customText
          : '${item.name} (${item.path})';
      final embeddingResult = await _embeddingModel!.embed(
        EmbeddingInput.text(textToEmbed),
        taskType: TaskType.retrievalDocument,
      );
      item.embedding = embeddingResult;
      item.isProcessed = true;
    } catch (e) {
      debugPrint('Text Embedding error on ${item.name}: $e');
    } finally {
      item.isEmbedding = false;
    }
  }

  /// Embed a document using its extracted text (or filename) and persist embedding in SQLite
  Future<void> embedDocument(DeviceDocument doc) async {
    if (_embeddingModel == null || doc.embedding != null) {
      doc.isEmbedding = false;
      return;
    }
    try {
      doc.isEmbedding = true;
      final textContent = doc.extractedText?.trim() ?? '';
      final String textToEmbed;
      if (textContent.isNotEmpty) {
        final snippet = textContent.length > 1200 ? textContent.substring(0, 1200) : textContent;
        textToEmbed = '${doc.name}\n$snippet';
      } else {
        textToEmbed = doc.name;
      }
      final embeddingResult = await _embeddingModel!.embed(
        EmbeddingInput.text(textToEmbed),
        taskType: TaskType.retrievalDocument,
      );
      doc.embedding = embeddingResult;
      doc.isProcessed = true;
      unawaited(DatabaseService.instance.updateDocumentEmbedding(doc.path, embeddingResult));
    } catch (e) {
      debugPrint('[AiService] Error embedding document ${doc.name}: $e');
    } finally {
      doc.isEmbedding = false;
    }
  }

  /// Embed all items using text embeddings (e.g. for Video and Audio items)
  Future<void> embedAllByText<T extends EmbeddableItem>(
    List<T> items, {
    String Function(T item)? textProvider,
    VoidCallback? onBatchCompleted,
  }) async {
    if (_embeddingModel == null || items.isEmpty || _isIndexing) return;

    _isIndexing = true;
    _isPaused = false;
    final pending = items.where((i) => !i.isProcessed && i.embedding == null).toList();
    if (pending.isEmpty) {
      _isIndexing = false;
      return;
    }

    final int batchSize = _parallelThreads.clamp(1, 16);
    int cursor = 0;

    while (cursor < pending.length && !_isPaused) {
      final currentBatch = pending.skip(cursor).take(batchSize).toList();
      for (final item in currentBatch) {
        item.isEmbedding = true;
      }

      await Future.wait(currentBatch.map((item) {
        final text = textProvider?.call(item) ?? item.name;
        return embedItemByText(item, text);
      }));

      // High-speed batch commit of newly generated embeddings to SQLite
      final videoBatch = <MapEntry<String, List<double>>>[];
      final audioBatch = <MapEntry<String, List<double>>>[];
      for (final item in currentBatch) {
        if (item.embedding != null) {
          final pLower = item.path.toLowerCase();
          final isVid = pLower.endsWith('.mp4') || pLower.endsWith('.mkv') || pLower.endsWith('.mov') || pLower.endsWith('.avi') || pLower.endsWith('.3gp') || pLower.endsWith('.webm');
          if (isVid) {
            videoBatch.add(MapEntry(item.path, item.embedding!));
          } else {
            audioBatch.add(MapEntry(item.path, item.embedding!));
          }
        }
      }
      if (videoBatch.isNotEmpty) {
        unawaited(DatabaseService.instance.saveVideoEmbeddingBatch(videoBatch));
      }
      if (audioBatch.isNotEmpty) {
        unawaited(DatabaseService.instance.saveAudioEmbeddingBatch(audioBatch));
      }

      cursor += currentBatch.length;
      onBatchCompleted?.call();
      await Future.delayed(const Duration(milliseconds: 10));
    }

    _isIndexing = false;
    _isPaused = false;
    onBatchCompleted?.call();
  }

  /// Run parallel batch indexing with specified threads and live callback
  Future<void> embedAll<T extends EmbeddableItem>(
    List<T> items, {
    VoidCallback? onBatchCompleted,
  }) async {
    if (_embeddingModel == null || items.isEmpty || _isIndexing) return;

    _isIndexing = true;
    _isPaused = false;
    // Process ALL items that do not yet have vector embeddings
    final pending = items.where((img) => img.embedding == null).toList();
    if (pending.isEmpty) {
      _isIndexing = false;
      return;
    }

    final int batchSize = _parallelThreads.clamp(1, 16);
    int cursor = 0;

    // Process first single photo if beginning from zero
    final alreadyIndexed = items.length - pending.length;
    if (alreadyIndexed == 0 && pending.isNotEmpty) {
      final first = pending[0];
      first.isEmbedding = true;
      onBatchCompleted?.call();

      final sw = Stopwatch()..start();
      await embedItem(first);
      sw.stop();

      cursor = 1;
      _lastBatchLatencyMs = sw.elapsedMilliseconds;
      onBatchCompleted?.call();
    }

    // Process remaining in batches using parallel workers (Future.wait)
    while (_isIndexing && cursor < pending.length) {
      // If paused, wait gently without consuming CPU
      if (_isPaused) {
        onBatchCompleted?.call();
        while (_isIndexing && _isPaused) {
          await Future.delayed(const Duration(milliseconds: 250));
        }
        if (!_isIndexing) break;
        onBatchCompleted?.call();
      }

      int currentBatchCount = batchSize;
      final currentIndexed = items.where((img) => img.embedding != null).length;
      if (currentIndexed == 1 && batchSize > 1) {
        currentBatchCount = batchSize - 1;
      }

      final int end = math.min(cursor + currentBatchCount, pending.length);
      final batch = pending.sublist(cursor, end);
      cursor = end;

      for (final img in batch) {
        img.isEmbedding = true;
      }
      onBatchCompleted?.call();

      final sw = Stopwatch()..start();
      await Future.wait(batch.map((img) => embedItem(img)));
      sw.stop();

      // Fast batch save newly generated embeddings to SQLite
      final batchEntries = batch
          .where((img) => img.embedding != null)
          .map((img) => MapEntry(img.path, img.embedding!))
          .toList();
      if (batchEntries.isNotEmpty) {
        unawaited(DatabaseService.instance.saveEmbeddingBatch(batchEntries));
      }

      _lastBatchLatencyMs = sw.elapsedMilliseconds;
      onBatchCompleted?.call();

      // Yield event loop so UI animations and scrolling remain 60-120fps smooth
      await Future.delayed(const Duration(milliseconds: 25));
    }

    _isIndexing = false;
    _isPaused = false;
    onBatchCompleted?.call();
  }

  /// Cosine similarity calculation between 2 vectors (loop-unrolled for speed).
  double cosineSimilarity(List<double> a, List<double> b) {
    final len = a.length;
    if (len != b.length || len == 0) return 0.0;
    double dot = 0.0, na = 0.0, nb = 0.0;
    // Unroll 4-wide to reduce loop overhead
    final end4 = len - (len % 4);
    for (int i = 0; i < end4; i += 4) {
      dot += a[i] * b[i] + a[i+1] * b[i+1] + a[i+2] * b[i+2] + a[i+3] * b[i+3];
      na  += a[i] * a[i] + a[i+1] * a[i+1] + a[i+2] * a[i+2] + a[i+3] * a[i+3];
      nb  += b[i] * b[i] + b[i+1] * b[i+1] + b[i+2] * b[i+2] + b[i+3] * b[i+3];
    }
    for (int i = end4; i < len; i++) {
      dot += a[i] * b[i];
      na  += a[i] * a[i];
      nb  += b[i] * b[i];
    }
    if (na == 0.0 || nb == 0.0) return 0.0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  /// Execute text query search against all items using tokenized query embedding
  Future<List<T>> search<T extends EmbeddableItem>(
    String query,
    List<T> allItems, {
    VoidCallback? onProgress,
  }) async {
    if (_embeddingModel == null) {
      throw Exception('Model is not initialized.');
    }

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      for (final item in allItems) {
        item.score = null;
      }
      _lastSearchLatencyMs = null;
      return List<T>.from(allItems);
    }

    final sw = Stopwatch()..start();
    debugPrint('🔍 [AI Search] ======================================================');
    debugPrint('🔍 [AI Search] Query: "$trimmed"');
    debugPrint('🔍 [AI Search] Evaluating ${allItems.length} items of type ${T.toString()}');
    debugPrint('🔍 [AI Search] Active Model: ${_currentModelName ?? "unknown"} | Backend: $_activeBackend');

    // 1. Query Embedding (retrievalQuery)
    final qSw = Stopwatch()..start();
    final queryEmbedding = await _embeddingModel!.embed(
      EmbeddingInput.text(trimmed),
      taskType: TaskType.retrievalQuery,
    );
    qSw.stop();
    debugPrint('⚡ [AI Search] Query embedding computed in ${qSw.elapsedMilliseconds}ms (${queryEmbedding.length} dimensions)');

    // 2. Score un-embedded items in fast parallel thread batches
    final pending = allItems.where((i) => i.embedding == null).toList();
    if (pending.isNotEmpty) {
      debugPrint('⏳ [AI Search] Generating embeddings for ${pending.length} un-embedded items...');
      final int batchSize = _parallelThreads.clamp(1, 16);
      for (int i = 0; i < pending.length; i += batchSize) {
        final end = math.min(i + batchSize, pending.length);
        final batch = pending.sublist(i, end);
        await Future.wait(batch.map((img) => embedItem(img)));
        final videoBatch = <MapEntry<String, List<double>>>[];
        final audioBatch = <MapEntry<String, List<double>>>[];
        final docBatch = <MapEntry<String, List<double>>>[];
        final imageBatch = <MapEntry<String, List<double>>>[];
        for (final item in batch) {
          if (item.embedding != null) {
            if (item is DeviceDocument) {
              docBatch.add(MapEntry(item.path, item.embedding!));
            } else {
              final pLower = item.path.toLowerCase();
              final isVid = pLower.endsWith('.mp4') || pLower.endsWith('.mkv') || pLower.endsWith('.mov') || pLower.endsWith('.avi') || pLower.endsWith('.3gp') || pLower.endsWith('.webm');
              final isAud = pLower.endsWith('.mp3') || pLower.endsWith('.m4a') || pLower.endsWith('.wav') || pLower.endsWith('.aac') || pLower.endsWith('.flac') || pLower.endsWith('.ogg');
              final isDoc = pLower.endsWith('.pdf') || pLower.endsWith('.doc') || pLower.endsWith('.docx') || pLower.endsWith('.txt') || pLower.endsWith('.xls') || pLower.endsWith('.xlsx') || pLower.endsWith('.ppt') || pLower.endsWith('.pptx');
              if (isVid) {
                videoBatch.add(MapEntry(item.path, item.embedding!));
              } else if (isAud) {
                audioBatch.add(MapEntry(item.path, item.embedding!));
              } else if (isDoc) {
                docBatch.add(MapEntry(item.path, item.embedding!));
              } else {
                imageBatch.add(MapEntry(item.path, item.embedding!));
              }
            }
          }
        }
        if (videoBatch.isNotEmpty) {
          unawaited(DatabaseService.instance.saveVideoEmbeddingBatch(videoBatch));
        }
        if (audioBatch.isNotEmpty) {
          unawaited(DatabaseService.instance.saveAudioEmbeddingBatch(audioBatch));
        }
        if (docBatch.isNotEmpty) {
          unawaited(DatabaseService.instance.saveDocumentEmbeddingBatch(docBatch));
        }
        if (imageBatch.isNotEmpty) {
          unawaited(DatabaseService.instance.saveEmbeddingBatch(imageBatch));
        }
        onProgress?.call();
      }
    }

    // 3. Compute cosine similarity scores and smoothly calibrate without saturation
    final Map<String, double> rawScores = {};
    double maxRawSim = -1.0;
    double minRawSim = 2.0;

    for (final item in allItems) {
      if (item.embedding != null) {
        final rawSim = cosineSimilarity(queryEmbedding, item.embedding!);
        rawScores[item.path] = rawSim;
        if (rawSim > maxRawSim) maxRawSim = rawSim;
        if (rawSim < minRawSim) minRawSim = rawSim;

        // Monotonic progression:
        // Ambient noise is ~0.18.
        // If rawSim >= 0.18: score >= 0.70 (visual match range)
        // If rawSim < 0.18: score < 0.70 (background / noise range)
        if (rawSim >= 0.18) {
          item.score = 0.70 + (rawSim - 0.18) * 1.05;
        } else if (rawSim >= 0.12) {
          final norm = (rawSim - 0.12) / 0.06;
          item.score = 0.50 + (norm * 0.19);
        } else if (rawSim > 0.0) {
          item.score = (rawSim / 0.12) * 0.49;
        } else {
          item.score = 0.0;
        }
      } else {
        item.score = -1.0;
      }
    }

    sw.stop();
    _lastSearchLatencyMs = sw.elapsedMilliseconds;

    // 4. Rank highest similarity first
    final ranked = List<T>.from(allItems)
      ..sort((a, b) => (b.score ?? -1.0).compareTo(a.score ?? -1.0));

    debugPrint('📊 [AI Search] Scored ${allItems.length} items in ${sw.elapsedMilliseconds}ms:');
    debugPrint('   • Top Similarity: ${maxRawSim.toStringAsFixed(4)}');
    debugPrint('   • Lowest Similarity: ${minRawSim.toStringAsFixed(4)}');
    debugPrint('   • Ambient Cutoff: 0.1800 (Score >= 0.70)');
    final logLimit = math.min(6, ranked.length);
    for (int i = 0; i < logLimit; i++) {
      final it = ranked[i];
      final sim = rawScores[it.path] ?? 0.0;
      final matchLabel = (it.score ?? 0.0) >= 0.70 ? 'MATCH' : 'BELOW_THRESHOLD';
      debugPrint('   #${i + 1} [$matchLabel] rawSim=${sim.toStringAsFixed(4)} | score=${it.score?.toStringAsFixed(3)} | ${it.name}');
    }
    debugPrint('🔍 [AI Search] ======================================================');

    return ranked;
  }

  /// Close resources
  @override
  void dispose() {
    _embeddingModel?.close();
    _embeddingModel = null;
    _isModelLoaded = false;
    super.dispose();
  }
}
