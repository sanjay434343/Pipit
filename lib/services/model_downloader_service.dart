import 'dart:async';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'model_storage_service.dart';

/// Available status states during model download.
enum DownloadStatus {
  idle,
  connecting,
  downloading,
  paused,
  verifying,
  completed,
  failed,
  cancelled,
}

/// Information about a single download chunk (kept for compatibility).
class DownloadChunkState {
  final int chunkIndex;
  final int startByte;
  final int endByte;
  int downloadedBytes;
  bool isCompleted;

  DownloadChunkState({
    required this.chunkIndex,
    required this.startByte,
    required this.endByte,
    this.downloadedBytes = 0,
    this.isCompleted = false,
  });

  int get totalChunkBytes => (endByte - startByte) + 1;
  double get progress => totalChunkBytes > 0
      ? (downloadedBytes / totalChunkBytes).clamp(0.0, 1.0)
      : 0.0;
}

/// Model preset option for the UI.
class ModelPreset {
  final String id;
  final String name;
  final String description;
  final String downloadUrl;
  final String filename;
  final int estimatedSizeBytes;
  final String tag;
  final bool isMultimodal;

  const ModelPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.downloadUrl,
    required this.filename,
    required this.estimatedSizeBytes,
    required this.tag,
    this.isMultimodal = true,
  });

  String get formattedEstimatedSize {
    return '${(estimatedSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// High-performance Background Model Downloader Service.
///
/// Features:
/// 1. Native Android Background Worker (WorkManager & Foreground Service):
///    Downloads continue seamlessly even when the app is minimized, screen is locked,
///    or the user closes / swipes away the app!
/// 2. Native System Notifications:
///    Displays an active Android notification drawer item with a live progress bar,
///    pause/cancel actions, and ETA.
/// 3. Resumable & Persistent:
///    Uses persistent SQLite database to remember task progress across app kills.
/// 4. Persistent Dual-Storage:
///    Saves verified model to `/storage/emulated/0/Android/media/com.example.pipit/models/`
///    and mirrors to `/storage/emulated/0/Download/Pipit/models/` for anti-deletion safety.
/// 5. Auto Integrity Verification & RAM Caching:
///    Verifies model upon completion and auto-loads into RAM with GPU acceleration.
class ModelDownloaderService with ChangeNotifier {
  ModelDownloaderService._internal() {
    initBackgroundDownloader();
  }

  static final ModelDownloaderService instance =
      ModelDownloaderService._internal();

  static const String kModelTaskId = 'pipit_model_embeddinggemma_440m';

  static const ModelPreset targetModel = ModelPreset(
    id: 'embeddinggemma_2_440m',
    name: 'EmbeddingGemma-2 Text & Vision 440M (LiteRT-LM)',
    description:
        'Official Google LiteRT-LM multimodal model. State-of-the-art semantic vision, photo search, OCR indexing, documents, and text embeddings.',
    downloadUrl:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/main/embeddinggemma-2-text-vision-440m.litertlm',
    filename: 'embeddinggemma-2-text-vision-440m.litertlm',
    estimatedSizeBytes: 440 * 1024 * 1024,
    tag: 'Official LiteRT-LM Multimodal',
    isMultimodal: true,
  );

  static const List<ModelPreset> presetModels = [targetModel];

  DownloadStatus _status = DownloadStatus.idle;
  String? _errorMessage;
  String? _activeUrl;
  String? _activeFileName;
  int _totalBytes = 440 * 1024 * 1024;
  int _downloadedBytes = 0;
  double _progress = 0.0;
  double _speedBytesPerSec = 0.0;
  int _estimatedSecondsRemaining = 0;
  String _networkSpeedStr = '';
  String _timeRemainingStr = '';
  final List<DownloadChunkState> _chunks = [];
  DownloadTask? _activeTask;
  StreamSubscription<TaskUpdate>? _updateSubscription;
  bool _isInitialized = false;

  // Getters
  DownloadStatus get status => _status;
  bool get isDownloading => _status == DownloadStatus.downloading;
  bool get isPaused => _status == DownloadStatus.paused;
  bool get isBusy =>
      _status == DownloadStatus.connecting ||
      _status == DownloadStatus.downloading ||
      _status == DownloadStatus.verifying;
  String? get errorMessage => _errorMessage;
  String? get activeUrl => _activeUrl;
  String? get activeFileName => _activeFileName;
  int get totalBytes => _totalBytes;
  int get downloadedBytes => _downloadedBytes;
  double get progress => _progress;
  double get speedBytesPerSec => _speedBytesPerSec;
  int get estimatedSecondsRemaining => _estimatedSecondsRemaining;
  List<DownloadChunkState> get chunks => List.unmodifiable(_chunks);

  String get formattedSpeed {
    if (_networkSpeedStr.isNotEmpty) return _networkSpeedStr;
    if (_speedBytesPerSec < 1024) {
      return '${_speedBytesPerSec.toStringAsFixed(0)} B/s';
    }
    if (_speedBytesPerSec < 1024 * 1024) {
      return '${(_speedBytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(_speedBytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String get formattedEta {
    if (_timeRemainingStr.isNotEmpty) return _timeRemainingStr;
    if (_estimatedSecondsRemaining <= 0) return '--';
    if (_estimatedSecondsRemaining < 60) {
      return '${_estimatedSecondsRemaining}s';
    }
    final mins = _estimatedSecondsRemaining ~/ 60;
    final secs = _estimatedSecondsRemaining % 60;
    return '${mins}m ${secs}s';
  }

  String get formattedProgress {
    final mbDown = (downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
    final mbTotal = totalBytes > 0
        ? (totalBytes / (1024 * 1024)).toStringAsFixed(1)
        : '440.0';
    return '$mbDown MB / $mbTotal MB';
  }

  /// Request storage permissions on Android.
  Future<bool> checkAndRequestPermissions() async {
    if (!Platform.isAndroid) return true;
    try {
      final manageGranted = await Permission.manageExternalStorage.isGranted;
      if (manageGranted) return true;

      final storageStatus = await Permission.storage.request();
      if (storageStatus.isGranted) return true;

      final manageStatus = await Permission.manageExternalStorage.request();
      return manageStatus.isGranted || storageStatus.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Initialize background downloader listener and restore any active task state.
  Future<void> initBackgroundDownloader() async {
    if (_isInitialized) return;
    _isInitialized = true;

    // Listen to background updates
    _updateSubscription?.cancel();
    _updateSubscription = FileDownloader().updates.listen(_handleUpdate);

    // Replay any events that occurred while app was in background or terminated
    try {
      FileDownloader().resumeFromBackground();
    } catch (_) {}

    // Check if target model is already on device storage
    await ModelStorageService.instance.scanAvailableModels();
    final hasTarget = ModelStorageService.instance.availableModels.any(
      (m) =>
          m.name.toLowerCase() == targetModel.filename.toLowerCase() ||
          m.name.toLowerCase().contains('embeddinggemma'),
    );
    if (hasTarget) {
      _status = DownloadStatus.completed;
      _progress = 1.0;
      notifyListeners();
      return;
    }

    // Reconcile with active tasks in the native queue
    try {
      final task = await FileDownloader().taskForId(kModelTaskId);
      if (task is DownloadTask) {
        _activeTask = task;
        _activeFileName = task.filename;
        _activeUrl = task.url;

        final record =
            await FileDownloader().database.recordForId(kModelTaskId);
        if (record != null) {
          if (record.status == TaskStatus.running ||
              record.status == TaskStatus.enqueued) {
            _status = DownloadStatus.downloading;
            _progress = record.progress.clamp(0.0, 1.0);
            _totalBytes = targetModel.estimatedSizeBytes;
            _downloadedBytes = (_totalBytes * _progress).toInt();
            debugPrint(
              '[ModelDownloader] Restored active background download at: ${(_progress * 100).toStringAsFixed(1)}%',
            );
            notifyListeners();
          } else if (record.status == TaskStatus.paused) {
            _status = DownloadStatus.paused;
            _progress = record.progress.clamp(0.0, 1.0);
            _totalBytes = targetModel.estimatedSizeBytes;
            _downloadedBytes = (_totalBytes * _progress).toInt();
            notifyListeners();
          } else if (record.status == TaskStatus.complete) {
            await _onDownloadComplete(task);
          }
        }
      }
    } catch (e) {
      debugPrint('[ModelDownloader] Error reconciling background task: $e');
    }
  }

  /// Internal handler for background download progress and status updates.
  Future<void> _handleUpdate(TaskUpdate update) async {
    if (update.task.taskId != kModelTaskId &&
        update.task.filename != targetModel.filename) {
      return;
    }

    if (update is TaskProgressUpdate) {
      _progress = update.progress.clamp(0.0, 1.0);
      _totalBytes = update.hasExpectedFileSize && update.expectedFileSize > 0
          ? update.expectedFileSize
          : targetModel.estimatedSizeBytes;
      _downloadedBytes = (_totalBytes * _progress).toInt();

      if (update.hasNetworkSpeed) {
        _networkSpeedStr = update.networkSpeedAsString;
        _speedBytesPerSec = update.networkSpeed * 1024 * 1024;
      }
      if (update.hasTimeRemaining) {
        _timeRemainingStr = update.timeRemainingAsString;
        _estimatedSecondsRemaining = update.timeRemaining.inSeconds;
      }

      if (_status != DownloadStatus.downloading && _progress < 1.0) {
        _status = DownloadStatus.downloading;
      }
      notifyListeners();
    } else if (update is TaskStatusUpdate) {
      debugPrint('[ModelDownloader] Background task status: ${update.status}');
      switch (update.status) {
        case TaskStatus.enqueued:
          _status = DownloadStatus.connecting;
          notifyListeners();
          break;
        case TaskStatus.running:
          _status = DownloadStatus.downloading;
          notifyListeners();
          break;
        case TaskStatus.paused:
          _status = DownloadStatus.paused;
          notifyListeners();
          break;
        case TaskStatus.canceled:
          _status = DownloadStatus.idle;
          _progress = 0.0;
          _downloadedBytes = 0;
          _speedBytesPerSec = 0.0;
          _estimatedSecondsRemaining = 0;
          _networkSpeedStr = '';
          _timeRemainingStr = '';
          notifyListeners();
          break;
        case TaskStatus.failed:
          _status = DownloadStatus.failed;
          _errorMessage =
              update.exception?.description ?? 'Background download failed.';
          notifyListeners();
          break;
        case TaskStatus.complete:
          await _onDownloadComplete(update.task as DownloadTask);
          break;
        default:
          break;
      }
    }
  }

  /// Start or resume model download in native background worker with system notifications.
  Future<void> startDownload({
    String? url,
    String? fileName,
    int parallelChunks = 4,
    bool isResume = false,
  }) async {
    final targetUrl = url ?? targetModel.downloadUrl;
    final targetFileName = fileName ?? targetModel.filename;

    if (Platform.isAndroid) {
      // 1. Request notification permission on Android 13+ so system notification displays
      try {
        await Permission.notification.request();
        await FileDownloader().permissions.request(PermissionType.notifications);
      } catch (_) {}
      await checkAndRequestPermissions();
    }

    _status = DownloadStatus.connecting;
    _errorMessage = null;
    _activeUrl = targetUrl;
    _activeFileName = targetFileName;
    _speedBytesPerSec = 0.0;
    _estimatedSecondsRemaining = 0;
    _networkSpeedStr = '';
    _timeRemainingStr = '';
    _totalBytes = targetModel.estimatedSizeBytes;
    notifyListeners();

    // Check if task exists to resume
    try {
      final existingTask = await FileDownloader().taskForId(kModelTaskId);
      if (existingTask is DownloadTask && isResume) {
        _activeTask = existingTask;
        final resumed = await FileDownloader().resume(existingTask);
        if (resumed) {
          _status = DownloadStatus.downloading;
          notifyListeners();
          return;
        }
      }
    } catch (_) {}

    final task = DownloadTask(
      taskId: kModelTaskId,
      url: targetUrl,
      filename: targetFileName,
      directory: 'models',
      baseDirectory: BaseDirectory.applicationSupport,
      updates: Updates.statusAndProgress,
      allowPause: true,
      retries: 5,
      displayName: 'EmbeddingGemma-2 Text & Vision 440M',
    );

    _activeTask = task;
    final enqueued = await FileDownloader().enqueue(task);
    if (enqueued) {
      _status = DownloadStatus.downloading;
      debugPrint(
        '[ModelDownloader] Background download successfully enqueued with native notifications.',
      );
    } else {
      _status = DownloadStatus.failed;
      _errorMessage = 'Could not start background download task.';
      debugPrint('[ModelDownloader] Failed to enqueue background task.');
    }
    notifyListeners();
  }

  /// Pause the ongoing background download.
  Future<void> pauseDownload() async {
    try {
      DownloadTask? taskToPause = _activeTask;
      if (taskToPause == null) {
        final t = await FileDownloader().taskForId(kModelTaskId);
        if (t is DownloadTask) {
          taskToPause = t;
          _activeTask = t;
        }
      }
      if (taskToPause != null) {
        final success = await FileDownloader().pause(taskToPause);
        if (success) {
          _status = DownloadStatus.paused;
          notifyListeners();
          return;
        }
      }
      _status = DownloadStatus.paused;
    } catch (e) {
      debugPrint('[ModelDownloader] pause error: $e');
    }
    notifyListeners();
  }

  /// Resume a paused background download.
  Future<void> resumeDownload() async {
    try {
      DownloadTask? taskToResume = _activeTask;
      if (taskToResume == null) {
        final t = await FileDownloader().taskForId(kModelTaskId);
        if (t is DownloadTask) {
          taskToResume = t;
          _activeTask = t;
        }
      }
      if (taskToResume != null) {
        final success = await FileDownloader().resume(taskToResume);
        if (success) {
          _status = DownloadStatus.downloading;
          notifyListeners();
          return;
        }
      }
    } catch (e) {
      debugPrint('[ModelDownloader] resume error: $e');
    }
    // Fallback: re-enqueue with isResume
    await startDownload(isResume: true);
  }

  /// Cancel background download and reset state.
  Future<void> cancelDownload() async {
    try {
      if (_activeTask != null) {
        await FileDownloader().cancelTaskWithId(_activeTask!.taskId);
      } else {
        await FileDownloader().cancelTaskWithId(kModelTaskId);
      }
    } catch (e) {
      debugPrint('[ModelDownloader] cancel error: $e');
    }
    _status = DownloadStatus.idle;
    _progress = 0.0;
    _downloadedBytes = 0;
    _speedBytesPerSec = 0.0;
    _estimatedSecondsRemaining = 0;
    _networkSpeedStr = '';
    _timeRemainingStr = '';
    notifyListeners();
  }

  /// Reset downloader state to clean idle.
  void resetToIdle() {
    try {
      if (_activeTask != null) {
        FileDownloader().cancelTaskWithId(_activeTask!.taskId);
      } else {
        FileDownloader().cancelTaskWithId(kModelTaskId);
      }
    } catch (_) {}
    _status = DownloadStatus.idle;
    _errorMessage = null;
    _activeUrl = null;
    _activeFileName = null;
    _totalBytes = 0;
    _downloadedBytes = 0;
    _progress = 0.0;
    _speedBytesPerSec = 0.0;
    _estimatedSecondsRemaining = 0;
    _networkSpeedStr = '';
    _timeRemainingStr = '';
    _chunks.clear();
    notifyListeners();
  }

  /// Process the completed file, move to persistent media path, verify integrity, and load to RAM.
  Future<void> _onDownloadComplete(DownloadTask task) async {
    _status = DownloadStatus.verifying;
    _progress = 1.0;
    notifyListeners();

    try {
      final downloadedPath = await task.filePath();
      final downloadedFile = File(downloadedPath);
      if (!await downloadedFile.exists()) {
        throw Exception('Downloaded file not found at $downloadedPath');
      }

      debugPrint(
        '[ModelDownloader] Download completed in background at: $downloadedPath (${await downloadedFile.length()} bytes)',
      );

      // 1. Designated persistent directory: /storage/emulated/0/Android/media/com.example.pipit/models
      final targetDir =
          await ModelStorageService.instance.getPreferredModelDirectory();
      final destinationFile = File('${targetDir.path}/${task.filename}');

      if (downloadedFile.path != destinationFile.path) {
        if (await destinationFile.exists()) {
          await destinationFile.delete();
        }
        await downloadedFile.copy(destinationFile.path);
        debugPrint(
          '[ModelDownloader] Saved model to designated media path: ${destinationFile.path}',
        );
        // Clean up temporary downloaded file to save space
        try {
          await downloadedFile.delete();
        } catch (_) {}
      }

      // 2. Anti-deletion mirror copy to /storage/emulated/0/Download/Pipit/models
      await ModelStorageService.instance
          .mirrorModelToAntiDeletionPath(destinationFile);

      // 3. Verify file integrity
      final verifyResult =
          await ModelStorageService.instance.verifyModelFile(destinationFile.path);
      if (verifyResult.isValid) {
        _status = DownloadStatus.completed;
        _errorMessage = null;
        debugPrint(
          '✅ [ModelDownloader] Model verified successfully! Auto-loading into RAM...',
        );
        await ModelStorageService.instance.scanAvailableModels();
        await ModelStorageService.instance.autoLoadModelToRam();
      } else {
        _status = DownloadStatus.failed;
        _errorMessage =
            'Integrity verification failed: ${verifyResult.message}';
        debugPrint('⚠️ [ModelDownloader] ${_errorMessage!}');
      }
    } catch (e) {
      _status = DownloadStatus.failed;
      _errorMessage = 'Failed finalizing model file: $e';
      debugPrint('❌ [ModelDownloader] Error finalizing model: $e');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _updateSubscription?.cancel();
    super.dispose();
  }
}
