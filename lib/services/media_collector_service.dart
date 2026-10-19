import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'ai_service.dart';

class DeviceVideo implements EmbeddableItem {
  @override
  final String id;
  @override
  final String path;
  @override
  final String name;
  @override
  final int fileSize;
  final DateTime modifiedDate;
  final String location;
  @override
  bool isProcessed;
  @override
  List<double>? embedding;
  @override
  double? score;
  @override
  bool isEmbedding;

  DeviceVideo({
    required this.id,
    required this.path,
    required this.name,
    required this.fileSize,
    required this.modifiedDate,
    required this.location,
    this.isProcessed = false,
    this.embedding,
    this.score,
    this.isEmbedding = false,
  });
}

class DeviceAudio implements EmbeddableItem {
  @override
  final String id;
  @override
  final String path;
  @override
  final String name;
  @override
  final int fileSize;
  final DateTime modifiedDate;
  final String location;
  @override
  bool isProcessed;
  @override
  List<double>? embedding;
  @override
  double? score;
  @override
  bool isEmbedding;

  DeviceAudio({
    required this.id,
    required this.path,
    required this.name,
    required this.fileSize,
    required this.modifiedDate,
    required this.location,
    this.isProcessed = false,
    this.embedding,
    this.score,
    this.isEmbedding = false,
  });
}

/// Service that scans and collects Videos and Audios from device storage
class MediaCollectorService {
  MediaCollectorService._internal();
  static final MediaCollectorService instance = MediaCollectorService._internal();

  static const Set<String> videoExtensions = {
    '.mp4',
    '.mkv',
    '.mov',
    '.avi',
    '.webm',
    '.3gp',
    '.flv',
    '.wmv',
  };

  static const Set<String> audioExtensions = {
    '.mp3',
    '.m4a',
    '.wav',
    '.aac',
    '.flac',
    '.ogg',
    '.opus',
    '.amr',
  };

  static bool isExcluded(String path) {
    final lower = path.toLowerCase();
    return lower.contains('/.thumbnails') ||
        lower.contains('/cache/') ||
        lower.contains('/android/data') ||
        lower.contains('/android/obb') ||
        lower.contains('whatsapp') ||
        lower.contains('sticker') ||
        lower.contains('statuses');
  }

  /// Collect all videos on device storage
  Future<List<DeviceVideo>> collectVideos({void Function(int count)? onProgress}) async {
    final List<DeviceVideo> videos = [];
    final searchDirs = [
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/DCIM/Camera',
      '/storage/emulated/0/Movies',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Pictures',
    ];

    try {
      final root = Directory('/storage/emulated/0');
      if (root.existsSync()) {
        for (final entity in root.listSync(recursive: false)) {
          if (entity is Directory) {
            final name = p.basename(entity.path);
            if (!name.startsWith('.') && name != 'Android' && !searchDirs.contains(entity.path)) {
              searchDirs.add(entity.path);
            }
          }
        }
      }
    } catch (_) {}

    final Set<String> seen = {};

    for (final dirPath in searchDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;

      try {
        await for (final entity in dir.list(recursive: true, followLinks: false).handleError((_) {})) {
          if (entity is File) {
            if (isExcluded(entity.path) || seen.contains(entity.path)) continue;
            final ext = p.extension(entity.path).toLowerCase();
            if (videoExtensions.contains(ext)) {
              seen.add(entity.path);
              try {
                final stat = entity.statSync();
                videos.add(DeviceVideo(
                  id: entity.path,
                  path: entity.path,
                  name: p.basename(entity.path),
                  fileSize: stat.size,
                  modifiedDate: stat.modified,
                  location: entity.parent.path,
                ));
                if (videos.length % 15 == 0) {
                  onProgress?.call(videos.length);
                }
              } catch (_) {}
            }
          }
        }
      } catch (e) {
        debugPrint('Error scanning videos in $dirPath: $e');
      }
    }

    videos.sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));
    return videos;
  }

  /// Collect all audios on device storage
  Future<List<DeviceAudio>> collectAudios({void Function(int count)? onProgress}) async {
    final List<DeviceAudio> audios = [];
    final searchDirs = [
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Podcasts',
      '/storage/emulated/0/Recordings',
      '/storage/emulated/0/Ringtones',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Audio',
    ];

    try {
      final root = Directory('/storage/emulated/0');
      if (root.existsSync()) {
        for (final entity in root.listSync(recursive: false)) {
          if (entity is Directory) {
            final name = p.basename(entity.path);
            if (!name.startsWith('.') && name != 'Android' && !searchDirs.contains(entity.path)) {
              searchDirs.add(entity.path);
            }
          }
        }
      }
    } catch (_) {}

    final Set<String> seen = {};

    for (final dirPath in searchDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;

      try {
        await for (final entity in dir.list(recursive: true, followLinks: false).handleError((_) {})) {
          if (entity is File) {
            if (isExcluded(entity.path) || seen.contains(entity.path)) continue;
            final ext = p.extension(entity.path).toLowerCase();
            if (audioExtensions.contains(ext)) {
              seen.add(entity.path);
              try {
                final stat = entity.statSync();
                audios.add(DeviceAudio(
                  id: entity.path,
                  path: entity.path,
                  name: p.basename(entity.path),
                  fileSize: stat.size,
                  modifiedDate: stat.modified,
                  location: entity.parent.path,
                ));
                if (audios.length % 20 == 0) {
                  onProgress?.call(audios.length);
                }
              } catch (_) {}
            }
          }
        }
      } catch (e) {
        debugPrint('Error scanning audios in $dirPath: $e');
      }
    }

    audios.sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));
    return audios;
  }
}
