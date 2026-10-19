import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Stored Image Record containing metadata, crypto SHA key, processing flag,
/// compressed thumbnail, and Float32 vector embeddings.
class CachedImageRecord {
  final String path;
  final String name;
  final int fileSize;
  final int modifiedTimestamp;
  final String? location;
  final String? shaKey;
  final bool isProcessed;
  final Uint8List? thumbnail;
  final List<double>? embedding;
  final String? extractedText;

  const CachedImageRecord({
    required this.path,
    required this.name,
    required this.fileSize,
    required this.modifiedTimestamp,
    this.location,
    this.shaKey,
    this.isProcessed = false,
    this.thumbnail,
    this.embedding,
    this.extractedText,
  });

  Map<String, dynamic> toMap() {
    return {
      'path': path,
      'name': name,
      'file_size': fileSize,
      'modified_timestamp': modifiedTimestamp,
      'location': location,
      'sha_key': shaKey,
      'is_processed': isProcessed ? 1 : 0,
      'thumbnail': thumbnail,
      'embedding': embedding != null ? _floatsToBytes(embedding!) : null,
      'extracted_text': extractedText,
    };
  }

  static Uint8List _floatsToBytes(List<double> floats) {
    final floatList = Float32List.fromList(floats);
    return floatList.buffer.asUint8List(
      floatList.offsetInBytes,
      floatList.lengthInBytes,
    );
  }

  static List<double>? _bytesToFloats(Uint8List? bytes) {
    if (bytes == null || bytes.length < 4) return null;
    try {
      if (bytes.offsetInBytes % 4 == 0) {
        final floatList = Float32List.view(
          bytes.buffer,
          bytes.offsetInBytes,
          bytes.lengthInBytes ~/ 4,
        );
        return floatList.toList();
      }
      final aligned = Uint8List.fromList(bytes);
      final floatList = Float32List.view(
        aligned.buffer,
        0,
        aligned.lengthInBytes ~/ 4,
      );
      return floatList.toList();
    } catch (_) {
      try {
        final byteData = ByteData.sublistView(bytes);
        final count = byteData.lengthInBytes ~/ 4;
        final list = List<double>.filled(count, 0.0);
        for (int i = 0; i < count; i++) {
          list[i] = byteData.getFloat32(i * 4, Endian.host);
        }
        return list;
      } catch (e) {
        return null;
      }
    }
  }

  factory CachedImageRecord.fromMap(Map<String, dynamic> map) {
    List<double>? embedding;
    try {
      embedding = _bytesToFloats(map['embedding'] as Uint8List?);
    } catch (_) {}

    return CachedImageRecord(
      path: map['path'] as String,
      name: map['name'] as String,
      fileSize: map['file_size'] as int,
      modifiedTimestamp: map['modified_timestamp'] as int,
      location: map['location'] as String?,
      shaKey: map['sha_key'] as String?,
      isProcessed: (map['is_processed'] as int? ?? 0) == 1,
      thumbnail: map['thumbnail'] as Uint8List?,
      embedding: embedding,
      extractedText: map['extracted_text'] as String?,
    );
  }
}

/// Stored Document Record
class CachedDocumentRecord {
  final String path;
  final String name;
  final String extension;
  final String category;
  final int fileSize;
  final int modifiedTimestamp;
  final String? location;
  final String? extractedText;
  final bool isOcrProcessed;
  final bool isProcessed;
  final List<double>? embedding;

  const CachedDocumentRecord({
    required this.path,
    required this.name,
    required this.extension,
    required this.category,
    required this.fileSize,
    required this.modifiedTimestamp,
    this.location,
    this.extractedText,
    this.isOcrProcessed = false,
    this.isProcessed = false,
    this.embedding,
  });

  Map<String, dynamic> toMap() {
    return {
      'path': path,
      'name': name,
      'extension': extension,
      'category': category,
      'file_size': fileSize,
      'modified_timestamp': modifiedTimestamp,
      'location': location,
      'extracted_text': extractedText,
      'is_ocr_processed': isOcrProcessed ? 1 : 0,
      'is_processed': isProcessed ? 1 : 0,
      'embedding': embedding != null ? CachedImageRecord._floatsToBytes(embedding!) : null,
    };
  }

  factory CachedDocumentRecord.fromMap(Map<String, dynamic> map) {
    List<double>? embedding;
    try {
      embedding = CachedImageRecord._bytesToFloats(map['embedding'] as Uint8List?);
    } catch (_) {}
    final isOcr = (map['is_ocr_processed'] as int? ?? 0) == 1;
    final isProc = (map['is_processed'] as int? ?? (isOcr ? 1 : 0)) == 1 || embedding != null;
    return CachedDocumentRecord(
      path: map['path'] as String,
      name: map['name'] as String,
      extension: map['extension'] as String? ?? '',
      category: map['category'] as String? ?? 'other',
      fileSize: map['file_size'] as int? ?? 0,
      modifiedTimestamp: map['modified_timestamp'] as int? ?? 0,
      location: map['location'] as String?,
      extractedText: map['extracted_text'] as String?,
      isOcrProcessed: isOcr,
      isProcessed: isProc,
      embedding: embedding,
    );
  }
}

/// Stored Video Record
class CachedVideoRecord {
  final String path;
  final String name;
  final int fileSize;
  final int modifiedTimestamp;
  final String location;
  final bool isProcessed;
  final List<double>? embedding;

  const CachedVideoRecord({
    required this.path,
    required this.name,
    required this.fileSize,
    required this.modifiedTimestamp,
    required this.location,
    this.isProcessed = false,
    this.embedding,
  });

  Map<String, dynamic> toMap() {
    return {
      'path': path,
      'name': name,
      'file_size': fileSize,
      'modified_timestamp': modifiedTimestamp,
      'location': location,
      'is_processed': isProcessed ? 1 : 0,
      'embedding': embedding != null ? CachedImageRecord._floatsToBytes(embedding!) : null,
    };
  }

  factory CachedVideoRecord.fromMap(Map<String, dynamic> map) {
    List<double>? embedding;
    try {
      embedding = CachedImageRecord._bytesToFloats(map['embedding'] as Uint8List?);
    } catch (_) {}
    return CachedVideoRecord(
      path: map['path'] as String,
      name: map['name'] as String,
      fileSize: map['file_size'] as int? ?? 0,
      modifiedTimestamp: map['modified_timestamp'] as int? ?? 0,
      location: map['location'] as String? ?? '',
      isProcessed: (map['is_processed'] as int? ?? 0) == 1,
      embedding: embedding,
    );
  }
}

/// Stored Audio Record
class CachedAudioRecord {
  final String path;
  final String name;
  final int fileSize;
  final int modifiedTimestamp;
  final String location;
  final bool isProcessed;
  final List<double>? embedding;

  const CachedAudioRecord({
    required this.path,
    required this.name,
    required this.fileSize,
    required this.modifiedTimestamp,
    required this.location,
    this.isProcessed = false,
    this.embedding,
  });

  Map<String, dynamic> toMap() {
    return {
      'path': path,
      'name': name,
      'file_size': fileSize,
      'modified_timestamp': modifiedTimestamp,
      'location': location,
      'is_processed': isProcessed ? 1 : 0,
      'embedding': embedding != null ? CachedImageRecord._floatsToBytes(embedding!) : null,
    };
  }

  factory CachedAudioRecord.fromMap(Map<String, dynamic> map) {
    List<double>? embedding;
    try {
      embedding = CachedImageRecord._bytesToFloats(map['embedding'] as Uint8List?);
    } catch (_) {}
    return CachedAudioRecord(
      path: map['path'] as String,
      name: map['name'] as String,
      fileSize: map['file_size'] as int? ?? 0,
      modifiedTimestamp: map['modified_timestamp'] as int? ?? 0,
      location: map['location'] as String? ?? '',
      isProcessed: (map['is_processed'] as int? ?? 0) == 1,
      embedding: embedding,
    );
  }
}

/// Stored App Record
class CachedAppRecord {
  final String packageName;
  final String name;
  final String version;
  final bool isSystemApp;

  const CachedAppRecord({
    required this.packageName,
    required this.name,
    required this.version,
    required this.isSystemApp,
  });

  Map<String, dynamic> toMap() {
    return {
      'package_name': packageName,
      'name': name,
      'version': version,
      'is_system_app': isSystemApp ? 1 : 0,
    };
  }

  factory CachedAppRecord.fromMap(Map<String, dynamic> map) {
    return CachedAppRecord(
      packageName: map['package_name'] as String,
      name: map['name'] as String? ?? '',
      version: map['version'] as String? ?? '',
      isSystemApp: (map['is_system_app'] as int? ?? 0) == 1,
    );
  }
}

/// Stored Contact Record
class CachedContactRecord {
  final String id;
  final String name;
  final String number;

  const CachedContactRecord({
    required this.id,
    required this.name,
    required this.number,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'number': number,
    };
  }

  factory CachedContactRecord.fromMap(Map<String, dynamic> map) {
    return CachedContactRecord(
      id: map['id']?.toString() ?? '',
      name: map['name'] as String? ?? '',
      number: map['number'] as String? ?? '',
    );
  }
}

/// Stored Call Log Record
class CachedCallLogRecord {
  final String id;
  final String name;
  final String number;
  final String type;
  final int dateTimestamp;
  final int duration;

  const CachedCallLogRecord({
    required this.id,
    required this.name,
    required this.number,
    required this.type,
    required this.dateTimestamp,
    required this.duration,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'number': number,
      'type': type,
      'date_timestamp': dateTimestamp,
      'duration': duration,
    };
  }

  factory CachedCallLogRecord.fromMap(Map<String, dynamic> map) {
    return CachedCallLogRecord(
      id: map['id']?.toString() ?? '',
      name: map['name'] as String? ?? '',
      number: map['number'] as String? ?? '',
      type: map['type'] as String? ?? '',
      dateTimestamp: map['date_timestamp'] as int? ?? 0,
      duration: map['duration'] as int? ?? 0,
    );
  }
}

/// Stored SMS Record
class CachedSmsRecord {
  final String id;
  final String address;
  final String body;
  final int dateTimestamp;
  final String type;
  final bool isProcessed;

  const CachedSmsRecord({
    required this.id,
    required this.address,
    required this.body,
    required this.dateTimestamp,
    required this.type,
    this.isProcessed = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'address': address,
      'body': body,
      'date_timestamp': dateTimestamp,
      'type': type,
      'is_processed': isProcessed ? 1 : 0,
    };
  }

  factory CachedSmsRecord.fromMap(Map<String, dynamic> map) {
    return CachedSmsRecord(
      id: map['id']?.toString() ?? '',
      address: map['address'] as String? ?? '',
      body: map['body'] as String? ?? '',
      dateTimestamp: map['date_timestamp'] as int? ?? 0,
      type: map['type'] as String? ?? '',
      isProcessed: (map['is_processed'] as int? ?? 1) == 1,
    );
  }
}

/// Offline SQLite Database Service storing image & document metadata, SHA keys, processing state,
/// compressed thumbnails (70% quality), LiteRT embeddings, and extracted OCR text.
class DatabaseService {
  DatabaseService._internal();
  static final DatabaseService instance = DatabaseService._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null && _db!.isOpen) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final dbDir = await getDatabasesPath();
    final dbPath = p.join(dbDir, 'pipit_vision.db');

    return await openDatabase(
      dbPath,
      version: 6,
      onOpen: (db) async {
        // sqflite requires rawQuery (not execute) inside onOpen callbacks
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.rawQuery('PRAGMA cache_size=-16384');
        await db.rawQuery('PRAGMA synchronous=NORMAL');
        await db.rawQuery('PRAGMA mmap_size=67108864');
        try {
          await db.execute('ALTER TABLE documents ADD COLUMN embedding BLOB');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE documents ADD COLUMN is_processed INTEGER NOT NULL DEFAULT 0');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE sms ADD COLUMN is_processed INTEGER NOT NULL DEFAULT 0');
        } catch (_) {}
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE images (
            path TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            modified_timestamp INTEGER NOT NULL,
            location TEXT,
            sha_key TEXT,
            is_processed INTEGER NOT NULL DEFAULT 0,
            thumbnail BLOB,
            embedding BLOB,
            extracted_text TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_images_sha ON images(sha_key)');
        await db.execute(
          'CREATE INDEX idx_images_processed ON images(is_processed)',
        );

        await db.execute('''
          CREATE TABLE documents (
            path TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            extension TEXT,
            category TEXT,
            file_size INTEGER NOT NULL,
            modified_timestamp INTEGER NOT NULL,
            location TEXT,
            extracted_text TEXT,
            is_ocr_processed INTEGER NOT NULL DEFAULT 0,
            is_processed INTEGER NOT NULL DEFAULT 0,
            embedding BLOB
          )
        ''');
        await db.execute('CREATE INDEX idx_docs_processed ON documents(is_ocr_processed)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_docs_is_processed ON documents(is_processed)');

        await _createV4Tables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute('ALTER TABLE images ADD COLUMN location TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE images ADD COLUMN sha_key TEXT');
          } catch (_) {}
          try {
            await db.execute(
              'ALTER TABLE images ADD COLUMN is_processed INTEGER NOT NULL DEFAULT 0',
            );
          } catch (_) {}
          try {
            await db.execute('CREATE INDEX idx_images_sha ON images(sha_key)');
          } catch (_) {}
          try {
            await db.execute(
              'CREATE INDEX idx_images_processed ON images(is_processed)',
            );
          } catch (_) {}
        }
        if (oldVersion < 3) {
          try {
            await db.execute('ALTER TABLE images ADD COLUMN extracted_text TEXT');
          } catch (_) {}
          try {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS documents (
                path TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                extension TEXT,
                category TEXT,
                file_size INTEGER NOT NULL,
                modified_timestamp INTEGER NOT NULL,
                location TEXT,
                extracted_text TEXT,
                is_ocr_processed INTEGER NOT NULL DEFAULT 0,
                embedding BLOB
              )
            ''');
            await db.execute('CREATE INDEX IF NOT EXISTS idx_docs_processed ON documents(is_ocr_processed)');
          } catch (_) {}
        }
        if (oldVersion < 4) {
          await _createV4Tables(db);
        }
        if (oldVersion < 5) {
          try {
            await db.execute('ALTER TABLE documents ADD COLUMN embedding BLOB');
          } catch (_) {}
        }
        if (oldVersion < 6) {
          try {
            await db.execute('ALTER TABLE documents ADD COLUMN is_processed INTEGER NOT NULL DEFAULT 0');
          } catch (_) {}
          try {
            await db.execute('CREATE INDEX IF NOT EXISTS idx_docs_is_processed ON documents(is_processed)');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE sms ADD COLUMN is_processed INTEGER NOT NULL DEFAULT 0');
          } catch (_) {}
        }
      },
    );
  }

  static Future<void> _createV4Tables(Database db) async {
    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS videos (
          path TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          file_size INTEGER NOT NULL,
          modified_timestamp INTEGER NOT NULL,
          location TEXT,
          is_processed INTEGER NOT NULL DEFAULT 0,
          embedding BLOB
        )
      ''');
    } catch (_) {}

    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS audios (
          path TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          file_size INTEGER NOT NULL,
          modified_timestamp INTEGER NOT NULL,
          location TEXT,
          is_processed INTEGER NOT NULL DEFAULT 0,
          embedding BLOB
        )
      ''');
    } catch (_) {}

    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS apps (
          package_name TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          version TEXT,
          is_system_app INTEGER NOT NULL DEFAULT 0
        )
      ''');
    } catch (_) {}

    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS contacts (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          number TEXT NOT NULL
        )
      ''');
    } catch (_) {}

    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS call_logs (
          id TEXT PRIMARY KEY,
          name TEXT,
          number TEXT NOT NULL,
          type TEXT,
          date_timestamp INTEGER NOT NULL,
          duration INTEGER NOT NULL DEFAULT 0
        )
      ''');
    } catch (_) {}

    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS sms (
          id TEXT PRIMARY KEY,
          address TEXT NOT NULL,
          body TEXT NOT NULL,
          date_timestamp INTEGER NOT NULL,
          type TEXT,
          is_processed INTEGER NOT NULL DEFAULT 0
        )
      ''');
    } catch (_) {}
  }

  /// Generate SHA-256 hash using the crypto package to prevent duplicate images
  static Future<String> generateShaKey(String filePath, int fileSize) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return '';
      final length = await file.length();
      if (length <= 512 * 1024) {
        final bytes = await file.readAsBytes();
        return sha256.convert(bytes).toString();
      } else {
        // High efficiency chunked reading for large image files
        final raf = await file.open(mode: FileMode.read);
        final headerBytes = await raf.read(64 * 1024);
        await raf.close();
        final composite = BytesBuilder()
          ..add(headerBytes)
          ..add(utf8.encode('-$length'));
        return sha256.convert(composite.toBytes()).toString();
      }
    } catch (_) {
      return sha256.convert(utf8.encode('$filePath-$fileSize')).toString();
    }
  }

  /// Compress image bytes into high-speed 70% quality compressed thumbnail
  Future<Uint8List?> createCompressedThumbnail(
    String filePath, {
    int maxDimension = 280,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final rawBytes = await file.readAsBytes();

      final buffer = await ui.ImmutableBuffer.fromUint8List(rawBytes);
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) {
          if (width >= height) {
            return ui.TargetImageSize(width: maxDimension);
          } else {
            return ui.TargetImageSize(height: maxDimension);
          }
        },
      );

      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      frame.image.dispose();
      codec.dispose();

      if (byteData != null) {
        return byteData.buffer.asUint8List();
      }
    } catch (_) {}
    return null;
  }

  /// Save or replace single image record
  Future<void> saveImageRecord(CachedImageRecord record) async {
    final db = await database;
    await db.insert(
      'images',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Mark an image as processed (is_processed = 1) and save its embedding and thumbnail
  Future<void> markAsProcessed(
    String path, {
    required List<double> embedding,
    Uint8List? thumbnail,
  }) async {
    final db = await database;
    final bytes = CachedImageRecord._floatsToBytes(embedding);
    final Map<String, dynamic> updateValues = {
      'is_processed': 1,
      'embedding': bytes,
    };
    if (thumbnail != null) {
      updateValues['thumbnail'] = thumbnail;
    }
    await db.update(
      'images',
      updateValues,
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  /// Update extracted OCR text for an image
  Future<void> updateImageOcrText(String path, String ocrText) async {
    final db = await database;
    await db.update(
      'images',
      {'extracted_text': ocrText},
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  /// Save or replace single document record
  Future<void> saveDocumentRecord(CachedDocumentRecord record) async {
    final db = await database;
    await db.insert(
      'documents',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Batch save document records
  Future<void> saveDocumentBatch(List<CachedDocumentRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final doc in records) {
      batch.insert(
        'documents',
        doc.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Update document extracted text and OCR flag
  Future<void> updateDocumentOcrText(String path, String text) async {
    final db = await database;
    await db.update(
      'documents',
      {
        'extracted_text': text,
        'is_ocr_processed': 1,
      },
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  /// Update document extracted text, OCR flag, vector embedding, and is_processed
  Future<void> updateDocumentOcrAndEmbedding(
    String path,
    String text, {
    List<double>? embedding,
    bool isProcessed = true,
  }) async {
    final db = await database;
    final Map<String, dynamic> values = {
      'extracted_text': text,
      'is_ocr_processed': 1,
      'is_processed': isProcessed ? 1 : 0,
    };
    if (embedding != null) {
      values['embedding'] = CachedImageRecord._floatsToBytes(embedding);
    }
    await db.update(
      'documents',
      values,
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  /// Update document vector embedding directly
  Future<void> updateDocumentEmbedding(String path, List<double> embedding) async {
    final db = await database;
    await db.update(
      'documents',
      {
        'embedding': CachedImageRecord._floatsToBytes(embedding),
        'is_processed': 1,
      },
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  /// Batch update document vector embeddings
  Future<void> saveDocumentEmbeddingBatch(List<MapEntry<String, List<double>>> batch) async {
    if (batch.isEmpty) return;
    final db = await database;
    final txn = db.batch();
    for (final entry in batch) {
      txn.update(
        'documents',
        {
          'embedding': CachedImageRecord._floatsToBytes(entry.value),
          'is_processed': 1,
        },
        where: 'path = ?',
        whereArgs: [entry.key],
      );
    }
    await txn.commit(noResult: true);
  }

  /// Update document is_processed status directly
  Future<void> updateDocumentProcessedStatus(String path, {required bool isProcessed}) async {
    final db = await database;
    await db.update(
      'documents',
      {'is_processed': isProcessed ? 1 : 0},
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  /// Update SMS is_processed status directly
  Future<void> updateSmsProcessedStatus(String id, {required bool isProcessed}) async {
    final db = await database;
    await db.update(
      'sms',
      {'is_processed': isProcessed ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Fetch all cached document records
  Future<Map<String, CachedDocumentRecord>> getAllDocumentRecords() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('documents');
      final Map<String, CachedDocumentRecord> result = {};
      for (final map in maps) {
        try {
          final record = CachedDocumentRecord.fromMap(map);
          result[record.path] = record;
        } catch (e) {
          debugPrint('Skipping unreadable DB doc record: $e');
        }
      }
      return result;
    } catch (e) {
      debugPrint('Error querying cached documents from DB: $e');
      return {};
    }
  }

  /// Batch insert new records in a single database transaction
  Future<void> saveBatch(List<CachedImageRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final record in records) {
      batch.insert(
        'images',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Fetch all cached image records from database (includes BLOBs — use sparingly)
  Future<Map<String, CachedImageRecord>> getAllRecords() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('images');
      final Map<String, CachedImageRecord> result = {};
      for (final map in maps) {
        try {
          final record = CachedImageRecord.fromMap(map);
          result[record.path] = record;
        } catch (e) {
          debugPrint('Skipping unreadable DB record: $e');
        }
      }
      return result;
    } catch (e) {
      debugPrint('Error querying cached images from DB: $e');
      return {};
    }
  }

  /// Lightweight fetch: loads metadata and vector embeddings, skipping heavy thumbnail BLOBs.
  /// Use this for instant display, scanning, and fast semantic vector search.
  Future<Map<String, CachedImageRecord>> getAllRecordsLightweight() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query(
        'images',
        columns: [
          'path',
          'name',
          'file_size',
          'modified_timestamp',
          'location',
          'sha_key',
          'is_processed',
          'extracted_text',
          'embedding',
        ],
      );
      final Map<String, CachedImageRecord> result = {};
      for (final map in maps) {
        try {
          final record = CachedImageRecord(
            path: map['path'] as String,
            name: map['name'] as String,
            fileSize: map['file_size'] as int,
            modifiedTimestamp: map['modified_timestamp'] as int,
            location: map['location'] as String?,
            shaKey: map['sha_key'] as String?,
            isProcessed: (map['is_processed'] as int? ?? 0) == 1,
            thumbnail: null, // intentionally not loaded to save RAM
            embedding: CachedImageRecord._bytesToFloats(map['embedding'] as Uint8List?),
            extractedText: map['extracted_text'] as String?,
          );
          result[record.path] = record;
        } catch (e) {
          debugPrint('Skipping lightweight record: $e');
        }
      }
      return result;
    } catch (e) {
      debugPrint('Error querying lightweight image records: $e');
      return {};
    }
  }

  /// High-speed batch commit of newly generated embeddings to SQLite
  Future<void> saveEmbeddingBatch(List<MapEntry<String, List<double>>> entries) async {
    if (entries.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final e in entries) {
      final bytes = CachedImageRecord._floatsToBytes(e.value);
      batch.update(
        'images',
        {'is_processed': 1, 'embedding': bytes},
        where: 'path = ?',
        whereArgs: [e.key],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Fetch ONLY records that have embeddings stored, used for semantic search.
  /// Loads embeddings but skips thumbnails to minimize RAM usage.
  Future<Map<String, CachedImageRecord>> getAllRecordsWithEmbeddings() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query(
        'images',
        columns: ['path', 'name', 'file_size', 'modified_timestamp', 'location', 'sha_key', 'is_processed', 'extracted_text', 'embedding'],
        where: 'is_processed = 1 AND embedding IS NOT NULL',
      );
      final Map<String, CachedImageRecord> result = {};
      for (final map in maps) {
        try {
          final record = CachedImageRecord.fromMap(map);
          result[record.path] = record;
        } catch (e) {
          debugPrint('Skipping embedding record: $e');
        }
      }
      return result;
    } catch (e) {
      debugPrint('Error querying embedding records: $e');
      return {};
    }
  }

  /// Get set of all stored paths to skip existing files during disk scans
  Future<Set<String>> getAllKnownPaths() async {
    final db = await database;
    final List<Map<String, dynamic>> rows = await db.query(
      'images',
      columns: ['path'],
    );
    return rows.map((r) => r['path'] as String).toSet();
  }

  /// Get map of path → isProcessed flag. Much lighter than getAllRecords() for syncing.
  Future<Map<String, bool>> getAllKnownPathsAndStatus() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> rows = await db.query(
        'images',
        columns: ['path', 'is_processed'],
      );
      return {for (final r in rows) r['path'] as String: (r['is_processed'] as int? ?? 0) == 1};
    } catch (_) {
      return {};
    }
  }

  /// Get set of all stored SHA keys to avoid duplicates
  Future<Set<String>> getAllKnownShaKeys() async {
    final db = await database;
    final List<Map<String, dynamic>> rows = await db.query(
      'images',
      columns: ['sha_key'],
      where: 'sha_key IS NOT NULL',
    );
    return rows.map((r) => r['sha_key'] as String).toSet();
  }

  /// Count how many images are marked as processed
  Future<int> countProcessedImages() async {
    final db = await database;
    final res = await db.rawQuery(
      'SELECT COUNT(*) as count FROM images WHERE is_processed = 1',
    );
    if (res.isNotEmpty) {
      return (res.first['count'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  /// Count total images in database
  Future<int> countTotalImages() async {
    final db = await database;
    final res = await db.rawQuery('SELECT COUNT(*) as count FROM images');
    if (res.isNotEmpty) {
      return (res.first['count'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  /// Delete WhatsApp, stickers, statuses, and sent/private images from database
  Future<int> removeExcludedMedia() async {
    final db = await database;
    return await db.delete(
      'images',
      where: '''
        LOWER(path) LIKE '%whatsapp%' OR
        LOWER(path) LIKE '%stickers%' OR
        LOWER(path) LIKE '%sticker%' OR
        LOWER(path) LIKE '%statuses%' OR
        LOWER(path) LIKE '%/.statuses/%' OR
        LOWER(path) LIKE '%/status/%' OR
        LOWER(path) LIKE '%/sent/%' OR
        LOWER(path) LIKE '%/private/%'
      ''',
    );
  }

  // --- VIDEOS DB METHODS ---
  Future<void> saveVideoBatch(List<CachedVideoRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final v in records) {
      batch.insert('videos', v.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// High-speed batch commit of newly generated video embeddings to SQLite
  Future<void> saveVideoEmbeddingBatch(List<MapEntry<String, List<double>>> entries) async {
    if (entries.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final e in entries) {
      final bytes = CachedImageRecord._floatsToBytes(e.value);
      batch.update(
        'videos',
        {'is_processed': 1, 'embedding': bytes},
        where: 'path = ?',
        whereArgs: [e.key],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<Map<String, CachedVideoRecord>> getAllVideoRecords() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('videos');
      final Map<String, CachedVideoRecord> result = {};
      for (final map in maps) {
        try {
          final record = CachedVideoRecord.fromMap(map);
          result[record.path] = record;
        } catch (_) {}
      }
      return result;
    } catch (e) {
      debugPrint('Error getting cached videos from DB: $e');
      return {};
    }
  }

  // --- AUDIOS DB METHODS ---
  Future<void> saveAudioBatch(List<CachedAudioRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final a in records) {
      batch.insert('audios', a.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// High-speed batch commit of newly generated audio embeddings to SQLite
  Future<void> saveAudioEmbeddingBatch(List<MapEntry<String, List<double>>> entries) async {
    if (entries.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final e in entries) {
      final bytes = CachedImageRecord._floatsToBytes(e.value);
      batch.update(
        'audios',
        {'is_processed': 1, 'embedding': bytes},
        where: 'path = ?',
        whereArgs: [e.key],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<Map<String, CachedAudioRecord>> getAllAudioRecords() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('audios');
      final Map<String, CachedAudioRecord> result = {};
      for (final map in maps) {
        try {
          final record = CachedAudioRecord.fromMap(map);
          result[record.path] = record;
        } catch (_) {}
      }
      return result;
    } catch (e) {
      debugPrint('Error getting cached audios from DB: $e');
      return {};
    }
  }

  // --- APPS DB METHODS ---
  Future<void> saveAppBatch(List<CachedAppRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final a in records) {
      batch.insert('apps', a.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<CachedAppRecord>> getAllAppRecords() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('apps');
      return maps.map((m) => CachedAppRecord.fromMap(m)).toList();
    } catch (e) {
      debugPrint('Error getting cached apps from DB: $e');
      return [];
    }
  }

  // --- CONTACTS DB METHODS ---
  Future<void> saveContactBatch(List<CachedContactRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final c in records) {
      batch.insert('contacts', c.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<CachedContactRecord>> getAllContactRecords() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('contacts');
      return maps.map((m) => CachedContactRecord.fromMap(m)).toList();
    } catch (e) {
      debugPrint('Error getting cached contacts from DB: $e');
      return [];
    }
  }

  // --- CALL LOGS DB METHODS ---
  Future<void> saveCallLogBatch(List<CachedCallLogRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final l in records) {
      batch.insert('call_logs', l.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<CachedCallLogRecord>> getAllCallLogRecords() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('call_logs', orderBy: 'date_timestamp DESC');
      return maps.map((m) => CachedCallLogRecord.fromMap(m)).toList();
    } catch (e) {
      debugPrint('Error getting cached call logs from DB: $e');
      return [];
    }
  }

  // --- SMS DB METHODS ---
  Future<void> saveSmsBatch(List<CachedSmsRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final s in records) {
      batch.insert('sms', s.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<CachedSmsRecord>> getAllSmsRecords() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('sms', orderBy: 'date_timestamp DESC');
      return maps.map((m) => CachedSmsRecord.fromMap(m)).toList();
    } catch (e) {
      debugPrint('Error getting cached sms from DB: $e');
      return [];
    }
  }

  /// Delete a file record across all media tables by its absolute path
  Future<int> deleteRecordByPath(String path) async {
    try {
      final db = await database;
      int deletedCount = 0;
      deletedCount += await db.delete('images', where: 'path = ?', whereArgs: [path]);
      deletedCount += await db.delete('videos', where: 'path = ?', whereArgs: [path]);
      deletedCount += await db.delete('audios', where: 'path = ?', whereArgs: [path]);
      deletedCount += await db.delete('documents', where: 'path = ?', whereArgs: [path]);
      return deletedCount;
    } catch (e) {
      debugPrint('Error deleting record $path from DB: $e');
      return 0;
    }
  }

  /// Batch delete multiple records across all media tables
  Future<int> deleteRecordsBatch(List<String> paths) async {
    if (paths.isEmpty) return 0;
    try {
      final db = await database;
      final batch = db.batch();
      for (final p in paths) {
        batch.delete('images', where: 'path = ?', whereArgs: [p]);
        batch.delete('videos', where: 'path = ?', whereArgs: [p]);
        batch.delete('audios', where: 'path = ?', whereArgs: [p]);
        batch.delete('documents', where: 'path = ?', whereArgs: [p]);
      }
      await batch.commit(noResult: true);
      return paths.length;
    } catch (e) {
      debugPrint('Error batch deleting records from DB: $e');
      return 0;
    }
  }

  /// Completely purge all database records, cached text, and LiteRT embeddings
  /// for a specific category when scanning is disabled in Settings.
  Future<int> purgeCategoryData(String category) async {
    try {
      final db = await database;
      int deletedCount = 0;
      switch (category.toLowerCase()) {
        case 'sms':
        case 'message':
        case 'messages':
          deletedCount = await db.delete('sms');
          debugPrint('🗑️ [DatabaseService] Purged all $deletedCount SMS records from SQLite');
          break;
        case 'contacts':
          deletedCount += await db.delete('contacts');
          deletedCount += await db.delete('call_logs');
          debugPrint('🗑️ [DatabaseService] Purged all $deletedCount Contacts/CallLog records from SQLite');
          break;
        case 'apps':
          deletedCount = await db.delete('apps');
          debugPrint('🗑️ [DatabaseService] Purged all $deletedCount Apps records from SQLite');
          break;
        case 'photos':
        case 'images':
          deletedCount = await db.delete('images');
          debugPrint('🗑️ [DatabaseService] Purged all $deletedCount Photos & embeddings from SQLite');
          break;
        case 'videos':
          deletedCount = await db.delete('videos');
          debugPrint('🗑️ [DatabaseService] Purged all $deletedCount Videos & embeddings from SQLite');
          break;
        case 'audio':
        case 'music':
          deletedCount = await db.delete('audios');
          debugPrint('🗑️ [DatabaseService] Purged all $deletedCount Audio & embeddings from SQLite');
          break;
        case 'documents':
        case 'docs':
          deletedCount = await db.delete('documents');
          debugPrint('🗑️ [DatabaseService] Purged all $deletedCount Documents, OCR text & embeddings from SQLite');
          break;
      }
      return deletedCount;
    } catch (e) {
      debugPrint('Error purging category data for $category: $e');
      return 0;
    }
  }

  /// Store a persistent application setting key-value pair
  Future<void> setAppSetting(String key, String value) async {
    try {
      final db = await database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
      await db.insert(
        'app_settings',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      debugPrint('Error saving app setting $key: $e');
    }
  }

  /// Retrieve a persistent application setting by key
  Future<String?> getAppSetting(String key) async {
    try {
      final db = await database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
      final res = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (res.isNotEmpty) {
        return res.first['value'] as String?;
      }
    } catch (e) {
      debugPrint('Error reading app setting $key: $e');
    }
    return null;
  }

  /// Close database connection
  Future<void> close() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }
  }
}
