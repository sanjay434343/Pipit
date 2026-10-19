import 'dart:io';
import 'package:flutter/material.dart';
import 'ai_service.dart' show EmbeddableItem;

/// Categories for device documents
enum DocumentCategory {
  pdf,
  word,
  excel,
  presentation,
  text,
  ebook,
  other,
}

/// Represents a document file located on the device
class DeviceDocument implements EmbeddableItem {
  @override
  final String id;
  @override
  final String path;
  @override
  final String name;
  final String extension;
  @override
  final int fileSize;
  final DateTime modifiedDate;
  final DocumentCategory category;
  final String location;
  String? extractedText;
  bool isOcrProcessed;

  @override
  bool isProcessed;
  @override
  List<double>? embedding;
  @override
  bool isEmbedding;
  @override
  double? score;

  DeviceDocument({
    required this.id,
    required this.path,
    required this.name,
    required this.extension,
    required this.fileSize,
    required this.modifiedDate,
    required this.category,
    required this.location,
    this.extractedText,
    this.isOcrProcessed = false,
    this.isProcessed = false,
    this.embedding,
    this.isEmbedding = false,
    this.score,
  });

  /// Get visual icon for the document category
  IconData get icon {
    switch (category) {
      case DocumentCategory.pdf:
        return Icons.picture_as_pdf;
      case DocumentCategory.word:
        return Icons.description;
      case DocumentCategory.excel:
        return Icons.table_chart;
      case DocumentCategory.presentation:
        return Icons.slideshow;
      case DocumentCategory.text:
        return Icons.article;
      case DocumentCategory.ebook:
        return Icons.menu_book;
      case DocumentCategory.other:
        return Icons.insert_drive_file;
    }
  }

  /// Get theme color for the document category
  Color get color {
    switch (category) {
      case DocumentCategory.pdf:
        return const Color(0xFFE53935); // Crimson Red
      case DocumentCategory.word:
        return const Color(0xFF1E88E5); // Royal Blue
      case DocumentCategory.excel:
        return const Color(0xFF2E7D32); // Emerald Green
      case DocumentCategory.presentation:
        return const Color(0xFFF57C00); // Amber Orange
      case DocumentCategory.text:
        return const Color(0xFF00897B); // Teal
      case DocumentCategory.ebook:
        return const Color(0xFF8E24AA); // Purple
      case DocumentCategory.other:
        return const Color(0xFF546E7A); // Slate Grey
    }
  }

  /// Category display label
  String get categoryLabel {
    switch (category) {
      case DocumentCategory.pdf:
        return 'PDF';
      case DocumentCategory.word:
        return 'Word Document';
      case DocumentCategory.excel:
        return 'Spreadsheet';
      case DocumentCategory.presentation:
        return 'Presentation';
      case DocumentCategory.text:
        return 'Text Document';
      case DocumentCategory.ebook:
        return 'E-Book';
      case DocumentCategory.other:
        return 'Document';
    }
  }
}

/// Service that scans and collects all document files stored on device storage.
class DocumentCollectorService {
  DocumentCollectorService._internal();
  static final DocumentCollectorService instance = DocumentCollectorService._internal();

  /// Supported document extensions
  static const Map<String, DocumentCategory> supportedExtensions = {
    // PDF
    '.pdf': DocumentCategory.pdf,

    // Word / Word Processing
    '.doc': DocumentCategory.word,
    '.docx': DocumentCategory.word,
    '.odt': DocumentCategory.word,
    '.rtf': DocumentCategory.word,

    // Excel / Spreadsheets
    '.xls': DocumentCategory.excel,
    '.xlsx': DocumentCategory.excel,
    '.csv': DocumentCategory.excel,
    '.ods': DocumentCategory.excel,

    // Presentations / Slides
    '.ppt': DocumentCategory.presentation,
    '.pptx': DocumentCategory.presentation,
    '.odp': DocumentCategory.presentation,

    // Text & Notes
    '.txt': DocumentCategory.text,
    '.md': DocumentCategory.text,
    '.json': DocumentCategory.text,
    '.xml': DocumentCategory.text,
    '.log': DocumentCategory.text,

    // E-Books
    '.epub': DocumentCategory.ebook,
    '.mobi': DocumentCategory.ebook,
  };

  /// Set of all supported document extensions
  static Set<String> get allSupportedExtensions => supportedExtensions.keys.toSet();

  /// Check whether a specific document file should be excluded
  static bool isExcludedDocument(String path, String name) {
    if (name.startsWith('.')) return true;
    final lowerPath = path.toLowerCase();
    final lowerName = name.toLowerCase();

    if (lowerPath.contains('/android/data') ||
        lowerPath.contains('/android/obb') ||
        lowerPath.contains('/.thumbnails') ||
        lowerPath.contains('/cache/') ||
        lowerName.contains('cache') ||
        lowerName.endsWith('.tmp')) {
      return true;
    }
    return false;
  }

  /// Check whether a directory should be skipped completely during document scans
  static bool isExcludedDirectory(String dirPath, String dirName) {
    final lowerName = dirName.toLowerCase();
    final lowerPath = dirPath.toLowerCase();

    // Skip hidden folders, caches, system, trash
    if (dirName.startsWith('.') ||
        lowerName == 'cache' ||
        lowerName == '.thumbnails' ||
        lowerName == 'trash' ||
        lowerName == '.trashed' ||
        lowerName == 'obb' ||
        lowerName == 'build') {
      return true;
    }

    // Skip internal app sandbox data
    if (lowerPath.contains('/android/data') || lowerPath.contains('/android/obb')) {
      return true;
    }

    return false;
  }

  /// Scan storage for all documents with non-blocking event-loop yields
  Future<List<DeviceDocument>> collectAllDocuments({
    void Function(int count, int elapsedMs)? onProgress,
  }) async {
    final List<DeviceDocument> documents = [];
    final List<Directory> queue = [];
    final Set<String> visitedDirs = {};
    final Set<String> seenPaths = {};

    final stopwatch = Stopwatch()..start();
    int lastYieldMs = stopwatch.elapsedMilliseconds;

    // 1. Primary document storage paths on Android
    final primaryPaths = [
      '/storage/emulated/0/Documents',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Books',
      '/storage/emulated/0/PDF',
      '/storage/emulated/0/WPS',
      '/storage/emulated/0/DCIM',
    ];

    for (final p in primaryPaths) {
      final d = Directory(p);
      if (d.existsSync()) queue.add(d);
    }

    // 2. Discover other root directories
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

    // Fallback for non-Android environments (e.g. Windows/macOS testing)
    if (queue.isEmpty) {
      final userHome = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
      if (userHome != null) {
        final docs = Directory('$userHome/Documents');
        final dls = Directory('$userHome/Downloads');
        if (docs.existsSync()) queue.add(docs);
        if (dls.existsSync()) queue.add(dls);
      }
    }

    // 3. Breadth-First-Search traversal
    while (queue.isNotEmpty) {
      final currentDir = queue.removeAt(0);
      final dirCanonical = currentDir.path;
      if (visitedDirs.contains(dirCanonical)) continue;
      visitedDirs.add(dirCanonical);

      try {
        final entries = currentDir.listSync(recursive: false, followLinks: false);
        for (final entity in entries) {
          final fileName = entity.path.split(Platform.pathSeparator).last;

          if (entity is Directory) {
            if (!isExcludedDirectory(entity.path, fileName)) {
              queue.add(entity);
            }
          } else if (entity is File) {
            if (fileName.startsWith('.')) continue;

            final dotIndex = fileName.lastIndexOf('.');
            if (dotIndex != -1) {
              final ext = fileName.substring(dotIndex).toLowerCase();
              final category = supportedExtensions[ext];

              if (category != null && !seenPaths.contains(entity.path)) {
                seenPaths.add(entity.path);

                int fileSize = 0;
                DateTime modifiedDate = DateTime.now();
                try {
                  final stat = entity.statSync();
                  fileSize = stat.size;
                  modifiedDate = stat.modified;
                } catch (_) {}

                final location = entity.parent.path.split(Platform.pathSeparator).last;

                documents.add(DeviceDocument(
                  id: entity.path,
                  path: entity.path,
                  name: fileName,
                  extension: ext.toUpperCase().replaceAll('.', ''),
                  fileSize: fileSize,
                  modifiedDate: modifiedDate,
                  category: category,
                  location: location,
                ));

                // Notify progress periodically
                if (documents.length % 20 == 0) {
                  onProgress?.call(documents.length, stopwatch.elapsedMilliseconds);
                }
              }
            }
          }
        }
      } catch (_) {}

      // Yield event loop every 30ms to prevent UI freezing
      final currentMs = stopwatch.elapsedMilliseconds;
      if (currentMs - lastYieldMs > 30) {
        await Future.delayed(Duration.zero);
        lastYieldMs = stopwatch.elapsedMilliseconds;
      }
    }

    // Sort newest modified first
    documents.sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));
    stopwatch.stop();

    onProgress?.call(documents.length, stopwatch.elapsedMilliseconds);
    return documents;
  }
}
