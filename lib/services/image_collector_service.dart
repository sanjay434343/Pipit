import 'dart:io';
import 'database_service.dart';

/// Raw image file collected from the device storage
class RawImageFile {
  final String path;
  final String name;
  final int fileSize;
  final DateTime modifiedDate;
  final String location;
  final String shaKey;

  const RawImageFile({
    required this.path,
    required this.name,
    required this.fileSize,
    required this.modifiedDate,
    required this.location,
    required this.shaKey,
  });
}

/// Service 1: Incremental Image Collector
/// Collects ONLY NEW images from device storage that are not already present in the database.
/// Filters out WhatsApp media, statuses, stickers, sent/received images, and thumbnails.
class ImageCollectorService {
  ImageCollectorService._internal();
  static final ImageCollectorService instance = ImageCollectorService._internal();

  static const Set<String> defaultExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.heic',
  };

  /// Check whether a directory should be skipped completely during scanning
  static bool isExcludedDirectory(String dirPath, String dirName) {
    final lowerName = dirName.toLowerCase();
    final lowerPath = dirPath.toLowerCase();

    // Skip hidden folders, caches, trash, obb
    if (dirName.startsWith('.') ||
        lowerName == 'cache' ||
        lowerName == '.thumbnails' ||
        lowerName == 'trash' ||
        lowerName == '.trashed' ||
        lowerName == 'obb') {
      return true;
    }

    // Skip Android data & obb internal app storage
    if (lowerPath.contains('/android/data') || lowerPath.contains('/android/obb')) {
      return true;
    }

    // Exclude WhatsApp media folders completely: statuses, stickers, sent, received, private
    if (lowerName.contains('whatsapp') ||
        lowerPath.contains('com.whatsapp') ||
        lowerPath.contains('whatsapp') ||
        lowerName.contains('sticker') ||
        lowerPath.contains('sticker') ||
        lowerName.contains('status') ||
        lowerPath.contains('status') ||
        lowerPath.contains('.statuses') ||
        lowerPath.contains('/statuses') ||
        lowerName == 'sent' ||
        lowerPath.contains('/sent') ||
        lowerName == 'private' ||
        lowerPath.contains('/private') ||
        lowerPath.contains('animated gifs') ||
        lowerPath.contains('profile photos')) {
      return true;
    }

    return false;
  }

  /// Check whether a specific image file should be excluded
  static bool isExcludedFile(String path, String name) {
    final lowerPath = path.toLowerCase();
    final lowerName = name.toLowerCase();

    if (name.startsWith('.')) return true;

    // Filter out WhatsApp, stickers, status, sent, and cache files
    if (lowerPath.contains('whatsapp') ||
        lowerPath.contains('com.whatsapp') ||
        lowerPath.contains('sticker') ||
        lowerPath.contains('statuses') ||
        lowerPath.contains('.statuses') ||
        lowerPath.contains('/status/') ||
        lowerPath.contains('/sent/') ||
        lowerPath.contains('/private/') ||
        lowerPath.contains('animated gifs') ||
        lowerPath.contains('profile photos') ||
        lowerName.startsWith('stk_') ||
        lowerName.startsWith('stk-') ||
        lowerName.startsWith('sticker_') ||
        lowerName.contains('whatsapp') ||
        lowerPath.contains('/.thumbnails') ||
        lowerPath.contains('/.cache') ||
        lowerPath.contains('/cache/file_picker') ||
        lowerPath.contains('/.nomedia')) {
      return true;
    }

    return false;
  }

  /// Scan storage and collect only new images not in [existingPaths].
  /// Computes crypto SHA keys and location for all newly discovered files.
  Future<List<RawImageFile>> collectNewImagesOnly({
    Set<String>? existingPaths,
    void Function(int count, int elapsedMs)? onProgress,
  }) async {
    final List<RawImageFile> newCollected = [];
    final List<Directory> queue = [];
    final Set<String> visitedDirs = {};
    final Set<String> seenPaths = {};
    final knownPaths = existingPaths ?? {};

    // 1. Primary personal media storage paths on Android (Excluding WhatsApp Android/media)
    final primaryPaths = [
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Documents',
    ];

    for (final p in primaryPaths) {
      final d = Directory(p);
      if (d.existsSync()) queue.add(d);
    }

    // 2. Add other root directories (skipping Android folder and WhatsApp)
    try {
      final root = Directory('/storage/emulated/0');
      if (root.existsSync()) {
        for (final entity in root.listSync(recursive: false)) {
          if (entity is Directory) {
            final name = entity.path.split(Platform.pathSeparator).last;
            if (!name.startsWith('.') &&
                name != 'Android' &&
                !isExcludedDirectory(entity.path, name) &&
                !primaryPaths.contains(entity.path)) {
              queue.add(entity);
            }
          }
        }
      }
    } catch (_) {}

    // 3. Check secondary storage / SD cards if available
    try {
      final storageDir = Directory('/storage');
      if (storageDir.existsSync()) {
        for (final entity in storageDir.listSync(recursive: false)) {
          if (entity is Directory) {
            final name = entity.path.split(Platform.pathSeparator).last;
            if (name != 'self' &&
                name != 'emulated' &&
                !name.startsWith('.') &&
                !isExcludedDirectory(entity.path, name)) {
              queue.add(entity);
            }
          }
        }
      }
    } catch (_) {}

    final sw = Stopwatch()..start();
    int lastUpdate = 0;
    int dirCount = 0;
    // Accumulate files between SHA batches to allow parallel hashing
    final List<({String path, String name, int fileSize, DateTime modified, String location})> pendingFiles = [];

    Future<void> flushPending() async {
      if (pendingFiles.isEmpty) return;
      final batch = List.of(pendingFiles);
      pendingFiles.clear();
      final results = await Future.wait(batch.map((f) async {
        try {
          final shaKey = await DatabaseService.generateShaKey(f.path, f.fileSize);
          return RawImageFile(
            path: f.path,
            name: f.name,
            fileSize: f.fileSize,
            modifiedDate: f.modified,
            location: f.location,
            shaKey: shaKey,
          );
        } catch (_) {
          return null;
        }
      }));
      for (final r in results) {
        if (r != null) {
          newCollected.add(r);
          final count = newCollected.length;
          if ((count == 1 || count % 15 == 0 || count - lastUpdate >= 15) && onProgress != null) {
            lastUpdate = count;
            onProgress(count, sw.elapsedMilliseconds);
          }
        }
      }
    }

    while (queue.isNotEmpty) {
      final currentDir = queue.removeAt(0);
      if (!visitedDirs.add(currentDir.path)) continue;

      // Yield every 3 directories to maintain 60fps
      dirCount++;
      if (dirCount % 3 == 0) {
        await Future.delayed(Duration.zero);
      }

      try {
        final List<FileSystemEntity> entities = currentDir.listSync(recursive: false, followLinks: false);
        for (final entity in entities) {
          if (entity is Directory) {
            final dirName = entity.path.split(Platform.pathSeparator).last;
            if (isExcludedDirectory(entity.path, dirName)) continue;
            queue.add(entity);
          } else if (entity is File) {
            final path = entity.path;
            final name = path.split(Platform.pathSeparator).last;

            if (knownPaths.contains(path)) continue;
            if (isExcludedFile(path, name)) continue;

            final lowerPath = path.toLowerCase();
            final dotIndex = lowerPath.lastIndexOf('.');
            if (dotIndex != -1 && defaultExtensions.contains(lowerPath.substring(dotIndex))) {
              if (seenPaths.add(path)) {
                try {
                  final stat = entity.statSync();
                  final fileSize = stat.size;
                  if (fileSize < 3072) continue;

                  pendingFiles.add((
                    path: path,
                    name: name,
                    fileSize: fileSize,
                    modified: stat.modified,
                    location: currentDir.path,
                  ));

                  // Flush in batches of 8 with parallel SHA computation
                  if (pendingFiles.length >= 8) {
                    await flushPending();
                    // Yield after each batch to keep UI smooth
                    await Future.delayed(Duration.zero);
                  }
                } catch (_) {}
              }
            }
          }
        }
      } catch (_) {}
    }

    // Flush any remaining files
    await flushPending();

    sw.stop();
    return newCollected;
  }
}
