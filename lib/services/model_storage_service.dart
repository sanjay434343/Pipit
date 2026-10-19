import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'ai_service.dart';

/// Metadata describing a detected on-device AI model file.
class StoredModelInfo {
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modifiedDate;
  final bool isPrimary;
  final String locationTag;

  StoredModelInfo({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modifiedDate,
    this.isPrimary = false,
    required this.locationTag,
  });

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Verification result for model files on disk.
enum ModelVerificationStatus {
  valid,
  tooSmall,
  corrupted,
  notFound,
  permissionDenied,
}

class ModelVerificationResult {
  final ModelVerificationStatus status;
  final String message;
  final int sizeBytes;

  const ModelVerificationResult({
    required this.status,
    required this.message,
    this.sizeBytes = 0,
  });

  bool get isValid => status == ModelVerificationStatus.valid;
}

/// Service dedicated to persistent AI model storage on Android / device storage.
///
/// Features:
/// 1. Stores models in persistent directories:
///    - Primary: `/storage/emulated/0/Android/media/com.example.pipit/models/`
///    - Mirror/Anti-deletion backup: `/storage/emulated/0/Download/Pipit/models/`
///      (Ensures that even if the app is uninstalled, the model is NEVER deleted!)
/// 2. Automatically verifies model file integrity on disk.
/// 3. Automatically detects existing models and loads them into RAM on app startup.
/// 4. RAM Caching: If the model is already in RAM, skips disk reads completely.
class ModelStorageService with ChangeNotifier {
  ModelStorageService._internal() {
    quickSyncScan();
  }
  static final ModelStorageService instance = ModelStorageService._internal();

  static const String appPackageName = 'com.example.pipit';
  static const List<String> supportedExtensions = [
    '.litertlm',
    '.bin',
    '.task',
    '.tflite',
    '.onnx',
  ];

  bool _isChecking = false;
  bool _hasModelOnDevice = false;
  bool _hasCompletedInitialScan = false;
  StoredModelInfo? _primaryModel;
  List<StoredModelInfo> _availableModels = [];

  bool get isChecking => _isChecking;
  bool get hasModelOnDevice => _hasModelOnDevice;
  bool get hasCompletedInitialScan => _hasCompletedInitialScan;
  StoredModelInfo? get primaryModel => _primaryModel;
  List<StoredModelInfo> get availableModels => List.unmodifiable(_availableModels);

  /// Fast synchronous scan of designated directories for instant detection at frame 0.
  bool quickSyncScan() {
    try {
      final List<StoredModelInfo> found = [];
      final Set<String> seenPaths = {};

      final dirsToCheck = <String>[
        designatedMediaPath,
        '/storage/emulated/0/Download/Pipit/models',
        '/storage/emulated/0/Download',
      ];

      for (final path in dirsToCheck) {
        final dir = Directory(path);
        if (!dir.existsSync()) continue;
        try {
          final entities = dir.listSync();
          for (final entity in entities) {
            if (entity is File && !seenPaths.contains(entity.path)) {
              try {
                final len = entity.lengthSync();
                if (_isSupportedModelFile(entity.path, len)) {
                  seenPaths.add(entity.path);
                  found.add(StoredModelInfo(
                    name: entity.path.split(Platform.pathSeparator).last,
                    path: entity.path,
                    sizeBytes: len,
                    modifiedDate: entity.lastModifiedSync(),
                    isPrimary: found.isEmpty,
                    locationTag: 'Android Persistent Storage',
                  ));
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
      }

      _hasCompletedInitialScan = true;
      _hasModelOnDevice = found.isNotEmpty;
      _availableModels = found;
      _primaryModel = found.isNotEmpty ? found.first : null;
      notifyListeners();
      return found.isNotEmpty;
    } catch (e) {
      debugPrint('[ModelStorageService] quickSyncScan error: $e');
      _hasCompletedInitialScan = true;
      _hasModelOnDevice = false;
      _availableModels = [];
      _primaryModel = null;
      notifyListeners();
    }
    return false;
  }

  /// The sole persistent directory on Android where models must be saved & loaded from:
  /// /storage/emulated/0/Android/media/com.example.pipit/models
  static const String designatedMediaPath = '/storage/emulated/0/Android/media/$appPackageName/models';

  /// Candidate persistent directories.
  /// Strictly restricted to designated Android media path only.
  Future<List<Directory>> getCandidateStorageDirectories() async {
    final List<Directory> dirs = [];

    if (Platform.isAndroid) {
      // ONLY load from Android/media/appname/models
      dirs.add(Directory(designatedMediaPath));
    } else {
      // Non-Android testing fallback
      try {
        final docDir = await getApplicationDocumentsDirectory();
        dirs.add(Directory('${docDir.path}/models'));
      } catch (_) {}
    }

    return dirs;
  }

  /// Returns the designated model directory: Android/media/appname/models.
  /// Automatically creates the directory tree if it does not exist.
  Future<Directory> getPreferredModelDirectory() async {
    if (Platform.isAndroid) {
      final mediaDir = Directory(designatedMediaPath);
      try {
        if (!await mediaDir.exists()) {
          await mediaDir.create(recursive: true);
        }
        return mediaDir;
      } catch (e) {
        debugPrint('[ModelStorageService] Media dir creation error: $e');
        return mediaDir;
      }
    }

    // Fallback for non-Android platforms
    final docDir = await getApplicationDocumentsDirectory();
    final fallbackDir = Directory('${docDir.path}/models');
    if (!await fallbackDir.exists()) {
      await fallbackDir.create(recursive: true);
    }
    return fallbackDir;
  }

  /// Mirror model to anti-deletion directory so even if app is deleted, model remains.
  Future<void> mirrorModelToAntiDeletionPath(File sourceFile) async {
    if (!Platform.isAndroid) return;
    try {
      final backupDir = Directory('/storage/emulated/0/Download/Pipit/models');
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }
      final fileName = sourceFile.path.split(Platform.pathSeparator).last;
      final backupFile = File('${backupDir.path}/$fileName');
      if (!await backupFile.exists() || (await backupFile.length()) != (await sourceFile.length())) {
        debugPrint('[ModelStorageService] Mirroring model to anti-deletion backup: ${backupFile.path}');
        await sourceFile.copy(backupFile.path);
      }
    } catch (e) {
      debugPrint('[ModelStorageService] Could not mirror model to backup path: $e');
    }
  }

  /// Scans device storage for available AI model files.
  Future<List<StoredModelInfo>> scanAvailableModels() async {
    _isChecking = true;
    notifyListeners();

    final List<StoredModelInfo> found = [];
    final Set<String> seenPaths = {};

    try {
      // 1. Check active path in AiService if loaded (only if from designated path)
      final currentLoadedPath = AiService.instance.currentModelPath;
      if (currentLoadedPath != null &&
          (!Platform.isAndroid || currentLoadedPath.contains(designatedMediaPath)) &&
          await File(currentLoadedPath).exists()) {
        final f = File(currentLoadedPath);
        final stat = await f.stat();
        if (_isSupportedModelFile(f.path, stat.size)) {
          seenPaths.add(f.path);
          found.add(StoredModelInfo(
            name: f.path.split(Platform.pathSeparator).last,
            path: f.path,
            sizeBytes: stat.size,
            modifiedDate: stat.modified,
            isPrimary: true,
            locationTag: 'Active in RAM',
          ));
        }
      }

      // 2. Scan designated media directory
      final dirs = await getCandidateStorageDirectories();
      for (final dir in dirs) {
        if (!await dir.exists()) continue;
        try {
          final entities = dir.listSync();
          for (final entity in entities) {
            if (entity is File && !seenPaths.contains(entity.path)) {
              final stat = await entity.stat();
              if (_isSupportedModelFile(entity.path, stat.size)) {
                seenPaths.add(entity.path);
                found.add(StoredModelInfo(
                  name: entity.path.split(Platform.pathSeparator).last,
                  path: entity.path,
                  sizeBytes: stat.size,
                  modifiedDate: stat.modified,
                  isPrimary: found.isEmpty,
                  locationTag: 'Android Media (Persistent)',
                ));
              }
            }
          }
        } catch (e) {
          debugPrint('[ModelStorageService] Error listing dir ${dir.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('[ModelStorageService] Scan error: $e');
    } finally {
      _isChecking = false;
      _hasCompletedInitialScan = true;
      _availableModels = found;
      _hasModelOnDevice = found.isNotEmpty;
      _primaryModel = found.isNotEmpty ? found.first : null;
      notifyListeners();
    }

    return _availableModels;
  }

  bool _isSupportedModelFile(String path, int sizeBytes) {
    if (sizeBytes < 5 * 1024 * 1024) return false; // Minimum 5MB for an AI model
    final lower = path.toLowerCase();
    final fileName = path.split(Platform.pathSeparator).last.toLowerCase();

    // If file is located in general root /Download/ (not Pipit's dedicated folder or media directory),
    // require the filename to explicitly match LiteRT, Embedding, or Pipit model keywords
    if (!path.contains('com.example.pipit') && !path.contains('Pipit')) {
      final isExplicitModel = fileName.endsWith('.litertlm') ||
          fileName.contains('embeddinggemma') ||
          fileName.contains('litert') ||
          fileName.contains('gecko');
      if (!isExplicitModel) return false;
    }

    return supportedExtensions.any((ext) => lower.endsWith(ext));
  }

  /// Verifies file existence, size threshold, and non-empty readable contents.
  Future<ModelVerificationResult> verifyModelFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return const ModelVerificationResult(
        status: ModelVerificationStatus.notFound,
        message: 'Model file does not exist on device storage.',
      );
    }

    try {
      final stat = await file.stat();
      if (stat.size < 1024 * 1024) {
        return ModelVerificationResult(
          status: ModelVerificationStatus.tooSmall,
          message: 'Model file is too small (${stat.size} bytes). Likely an incomplete download.',
          sizeBytes: stat.size,
        );
      }

      // Read initial header bytes to ensure file is readable and not locked
      final raf = await file.open(mode: FileMode.read);
      final header = await raf.read(64);
      await raf.close();

      if (header.isEmpty) {
        return ModelVerificationResult(
          status: ModelVerificationStatus.corrupted,
          message: 'Model file header could not be read.',
          sizeBytes: stat.size,
        );
      }

      return ModelVerificationResult(
        status: ModelVerificationStatus.valid,
        message: 'Model file verified successfully (${(stat.size / (1024 * 1024)).toStringAsFixed(1)} MB).',
        sizeBytes: stat.size,
      );
    } catch (e) {
      return ModelVerificationResult(
        status: ModelVerificationStatus.corrupted,
        message: 'Model verification error: $e',
      );
    }
  }

  /// Auto-load model from device storage directly to RAM.
  ///
  /// CRITICAL CACHE RULE: If the model is ALREADY loaded in RAM, this method
  /// skips disk I/O completely and preserves the in-memory cache!
  Future<bool> autoLoadModelToRam({bool forceReload = false}) async {
    // 1. RAM Cache Check: If model already loaded in memory and matches, avoid reload!
    if (!forceReload &&
        AiService.instance.isModelLoaded &&
        AiService.instance.embeddingModel != null) {
      debugPrint('⚡ [ModelStorageService] Model is ALREADY loaded in RAM cache. Skipping storage reload.');
      _hasModelOnDevice = true;
      notifyListeners();
      return true;
    }

    // 2. Discover available models on device
    await scanAvailableModels();
    if (_availableModels.isEmpty) {
      debugPrint('ℹ️ [ModelStorageService] No model files found on device storage.');
      return false;
    }

    // 3. Pick primary model
    final candidate = _primaryModel ?? _availableModels.first;

    // RAM Cache Check for specific path:
    if (!forceReload &&
        AiService.instance.isModelLoaded &&
        AiService.instance.currentModelPath == candidate.path) {
      debugPrint('⚡ [ModelStorageService] Target model already active in RAM.');
      return true;
    }

    // 4. Verify integrity before loading
    final verifyResult = await verifyModelFile(candidate.path);
    if (!verifyResult.isValid) {
      debugPrint('⚠️ [ModelStorageService] Model file verification failed: ${verifyResult.message}');
      return false;
    }

    // 5. Load model into RAM
    try {
      debugPrint('🚀 [ModelStorageService] Auto-loading model to RAM: ${candidate.name} (${candidate.path})...');
      await AiService.instance.loadModel(candidate.path, candidate.name);
      final success = AiService.instance.isModelLoaded;
      if (success) {
        debugPrint('✅ [ModelStorageService] Model successfully cached in RAM!');
        // Also ensure anti-deletion backup is mirrored in Download/Pipit/models
        mirrorModelToAntiDeletionPath(File(candidate.path));
      }
      notifyListeners();
      return success;
    } catch (e) {
      debugPrint('❌ [ModelStorageService] Failed to load model to RAM: $e');
      return false;
    }
  }

  /// Deletes a model file from storage, removes any anti-deletion mirror copy,
  /// unloads it from memory if active, and triggers a storage rescan.
  Future<bool> deleteModel(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('[ModelStorageService] Deleted model file: $filePath');
      }

      // Also clean mirror copy from /storage/emulated/0/Download/Pipit/models/
      if (Platform.isAndroid) {
        final fileName = filePath.split(Platform.pathSeparator).last;
        final backupFile = File('/storage/emulated/0/Download/Pipit/models/$fileName');
        if (await backupFile.exists()) {
          await backupFile.delete();
          debugPrint('[ModelStorageService] Deleted backup model file: ${backupFile.path}');
        }
      }

      // Unload from RAM if currently active
      if (AiService.instance.currentModelPath == filePath) {
        await AiService.instance.unloadModel();
      }

      // Refresh storage inventory
      await scanAvailableModels();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[ModelStorageService] Error deleting model: $e');
      return false;
    }
  }
}

