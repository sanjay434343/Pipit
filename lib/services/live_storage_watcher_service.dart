import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'image_collector_service.dart';
import 'document_collector_service.dart';
import 'database_service.dart';
import 'media_collector_service.dart';

/// Live Storage Watcher Service
/// Watches common storage folders (DCIM/Camera, Pictures, Download, Documents)
/// lively in real time while the app is active.
/// When any new image or document is added to the device, it immediately notifies
/// the app to load it and process it on the fly.
/// When any file is deleted on device storage, it notifies the app to purge it.
class LiveStorageWatcherService {
  LiveStorageWatcherService._internal();
  static final LiveStorageWatcherService instance = LiveStorageWatcherService._internal();

  final List<StreamSubscription<FileSystemEvent>> _subscriptions = [];
  Timer? _pollingTimer;
  bool _isWatching = false;

  void Function(String newImagePath)? onNewImageDiscovered;
  void Function(String newDocPath)? onNewDocumentDiscovered;
  void Function(String newVideoPath)? onNewVideoDiscovered;
  void Function(String newAudioPath)? onNewAudioDiscovered;
  void Function(String deletedPath)? onFileDeleted;

  final Set<String> _knownPaths = {};
  bool _isProcessingEvent = false;
  int _lastCheckIndex = 0;
  static const int _batchCheckSize = 60;

  bool get isWatching => _isWatching;

  /// Start watching storage directories for live updates
  Future<void> startWatching({
    void Function(String imagePath)? onNewImage,
    void Function(String docPath)? onNewDoc,
    void Function(String videoPath)? onNewVideo,
    void Function(String audioPath)? onNewAudio,
    void Function(String deletedPath)? onFileDeleted,
  }) async {
    if (_isWatching) return;
    _isWatching = true;

    onNewImageDiscovered = onNewImage;
    onNewDocumentDiscovered = onNewDoc;
    onNewVideoDiscovered = onNewVideo;
    onNewAudioDiscovered = onNewAudio;
    this.onFileDeleted = onFileDeleted;

    // Pre-populate known paths from database
    try {
      final dbImages = await DatabaseService.instance.getAllKnownPaths();
      _knownPaths.addAll(dbImages);

      final dbDocs = await DatabaseService.instance.getAllDocumentRecords();
      _knownPaths.addAll(dbDocs.keys);

      final dbVids = await DatabaseService.instance.getAllVideoRecords();
      _knownPaths.addAll(dbVids.keys);

      final dbAuds = await DatabaseService.instance.getAllAudioRecords();
      _knownPaths.addAll(dbAuds.keys);
    } catch (_) {}

    final watchDirs = [
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/DCIM/Camera',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Pictures/Screenshots',
      '/storage/emulated/0/Movies',
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Documents',
    ];

    // 1. Setup FileSystemWatcher on available directories including delete events
    for (final path in watchDirs) {
      final dir = Directory(path);
      if (dir.existsSync()) {
        try {
          final sub = dir.watch(
            events: FileSystemEvent.create | FileSystemEvent.modify | FileSystemEvent.delete,
            recursive: true,
          ).listen(
            (event) {
              _handleFileSystemEvent(event);
            },
            onError: (err) {
              debugPrint('[LiveWatcher] Watch error on $path: $err');
            },
          );
          _subscriptions.add(sub);
        } catch (e) {
          debugPrint('[LiveWatcher] Could not watch $path: $e');
        }
      }
    }

    // 2. Fallback gentle polling every 6 seconds to catch items missed by Android scoped storage
    _pollingTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      _pollForNewFiles(watchDirs);
    });

    debugPrint('👀 [LiveStorageWatcherService] Active: Watching storage lively for photos, documents & deletions.');
  }

  void _handleFileSystemEvent(FileSystemEvent event) {
    final filePath = event.path;

    // Check if file was deleted
    if ((event.type & FileSystemEvent.delete) != 0 ||
        event is FileSystemDeleteEvent ||
        !File(filePath).existsSync()) {
      if (_knownPaths.remove(filePath)) {
        debugPrint('🗑️ [LiveWatcher] Real-time file deleted: $filePath');
        onFileDeleted?.call(filePath);
      }
      return;
    }

    final ext = p.extension(filePath).toLowerCase();

    // Check if image
    if (ImageCollectorService.defaultExtensions.contains(ext)) {
      final name = p.basename(filePath);
      if (!ImageCollectorService.isExcludedFile(filePath, name)) {
        if (!_knownPaths.contains(filePath)) {
          _knownPaths.add(filePath);
          debugPrint('✨ [LiveWatcher] Real-time image created: $filePath');
          onNewImageDiscovered?.call(filePath);
        }
      }
      return;
    }

    // Check if document
    if (DocumentCollectorService.allSupportedExtensions.contains(ext)) {
      final name = p.basename(filePath);
      if (!DocumentCollectorService.isExcludedDocument(filePath, name)) {
        if (!_knownPaths.contains(filePath)) {
          _knownPaths.add(filePath);
          debugPrint('✨ [LiveWatcher] Real-time document created: $filePath');
          onNewDocumentDiscovered?.call(filePath);
        }
      }
      return;
    }

    // Check if video
    if (MediaCollectorService.videoExtensions.contains(ext)) {
      if (!MediaCollectorService.isExcluded(filePath)) {
        if (!_knownPaths.contains(filePath)) {
          _knownPaths.add(filePath);
          debugPrint('✨ [LiveWatcher] Real-time video created: $filePath');
          onNewVideoDiscovered?.call(filePath);
        }
      }
      return;
    }

    // Check if audio
    if (MediaCollectorService.audioExtensions.contains(ext)) {
      if (!MediaCollectorService.isExcluded(filePath)) {
        if (!_knownPaths.contains(filePath)) {
          _knownPaths.add(filePath);
          debugPrint('✨ [LiveWatcher] Real-time audio created: $filePath');
          onNewAudioDiscovered?.call(filePath);
        }
      }
      return;
    }
  }

  /// Gentle shallow poll of recent camera and download folders
  Future<void> _pollForNewFiles(List<String> watchDirs) async {
    if (_isProcessingEvent) return;
    _isProcessingEvent = true;
    try {
      for (final path in watchDirs) {
        final dir = Directory(path);
        if (!dir.existsSync()) continue;
        try {
          final entities = dir.listSync(recursive: false);
          for (final entity in entities) {
            if (entity is File) {
              final filePath = entity.path;
              if (_knownPaths.contains(filePath)) continue;

              final ext = p.extension(filePath).toLowerCase();
              final name = p.basename(filePath);

              if (ImageCollectorService.defaultExtensions.contains(ext)) {
                if (!ImageCollectorService.isExcludedFile(filePath, name)) {
                  _knownPaths.add(filePath);
                  debugPrint('✨ [LiveWatcher] Polled new image: $filePath');
                  onNewImageDiscovered?.call(filePath);
                }
              } else if (DocumentCollectorService.allSupportedExtensions.contains(ext)) {
                if (!DocumentCollectorService.isExcludedDocument(filePath, name)) {
                  _knownPaths.add(filePath);
                  debugPrint('✨ [LiveWatcher] Polled new document: $filePath');
                  onNewDocumentDiscovered?.call(filePath);
                }
              } else if (MediaCollectorService.videoExtensions.contains(ext)) {
                if (!MediaCollectorService.isExcluded(filePath)) {
                  _knownPaths.add(filePath);
                  debugPrint('✨ [LiveWatcher] Polled new video: $filePath');
                  onNewVideoDiscovered?.call(filePath);
                }
              } else if (MediaCollectorService.audioExtensions.contains(ext)) {
                if (!MediaCollectorService.isExcluded(filePath)) {
                  _knownPaths.add(filePath);
                  debugPrint('✨ [LiveWatcher] Polled new audio: $filePath');
                  onNewAudioDiscovered?.call(filePath);
                }
              }
            }
          }
        } catch (_) {}
      }

      // Also periodically verify known paths to catch background deletions
      await _checkDeletedFiles();
    } finally {
      _isProcessingEvent = false;
    }
  }

  Future<void> _checkDeletedFiles() async {
    if (_knownPaths.isEmpty) return;
    final all = _knownPaths.toList();
    final count = all.length;
    if (_lastCheckIndex >= count) {
      _lastCheckIndex = 0;
    }
    final end = math.min(_lastCheckIndex + _batchCheckSize, count);
    final batch = all.sublist(_lastCheckIndex, end);
    _lastCheckIndex = (end >= count) ? 0 : end;

    final List<String> deleted = [];
    for (final p in batch) {
      try {
        if (!await File(p).exists()) {
          deleted.add(p);
        }
      } catch (_) {}
    }

    for (final p in deleted) {
      _knownPaths.remove(p);
      debugPrint('🗑️ [LiveWatcher] Polled file deletion detected: $p');
      onFileDeleted?.call(p);
    }
  }

  /// Register a path as already known so it's not re-triggered
  void registerPath(String path) {
    _knownPaths.add(path);
  }

  /// Remove a path from known paths cache when deleted
  void removeKnownPath(String path) {
    _knownPaths.remove(path);
  }

  /// Stop watching
  void stopWatching() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _isWatching = false;
    debugPrint('🛑 [LiveStorageWatcherService] Stopped live watching.');
  }
}
