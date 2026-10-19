import 'dart:io';
import 'image_collector_service.dart';
import 'media_collector_service.dart';
import 'document_collector_service.dart';
import 'device_info_service.dart';

/// Result of duplicate removal
class DeduplicationResult<T> {
  final List<T> uniqueItems;
  final int duplicatesCount;

  const DeduplicationResult({
    required this.uniqueItems,
    required this.duplicatesCount,
  });
}

/// Service: Comprehensive Load-time Deduplication Cleaner for Images, Videos, Audio, Documents, Contacts, and SMS.
class DuplicateRemoverService {
  DuplicateRemoverService._internal();
  static final DuplicateRemoverService instance = DuplicateRemoverService._internal();

  /// Normalizes phone numbers to standard canonical last 10 digits
  static String normalizePhone(String raw, {String fallback = ''}) {
    final cleaned = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    if (cleaned.isEmpty) return fallback.trim().toLowerCase();
    final digits = cleaned.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length >= 10) return digits.substring(digits.length - 10);
    return cleaned.toLowerCase();
  }

  /// Removes duplicates based on Crypto SHA-256 key, checking both known database SHA keys and new batch items.
  /// If duplicate is detected, it is deleted from physical storage to keep only original authentic files.
  DeduplicationResult<RawImageFile> removeDuplicates(
    List<RawImageFile> rawImages, {
    Set<String>? existingShaKeys,
  }) {
    final Set<String> seenShaKeys = Set<String>.from(existingShaKeys ?? {});
    final Set<String> seenNameSizes = {};
    final List<RawImageFile> unique = [];
    int dupCount = 0;

    for (final img in rawImages) {
      final nameSizeKey = '${img.name.toLowerCase()}_${img.fileSize}';
      final isDuplicate = (img.shaKey.isNotEmpty && seenShaKeys.contains(img.shaKey)) ||
          seenNameSizes.contains(nameSizeKey);

      if (isDuplicate) {
        dupCount++;
        // Delete duplicate from storage if saved
        try {
          final file = File(img.path);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      } else {
        if (img.shaKey.isNotEmpty) {
          seenShaKeys.add(img.shaKey);
        }
        seenNameSizes.add(nameSizeKey);
        unique.add(img);
      }
    }

    // Sort newest modified first
    unique.sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));

    return DeduplicationResult(
      uniqueItems: unique,
      duplicatesCount: dupCount,
    );
  }

  /// Generic deduplication cleaner for file items by canonical path and (name + fileSize).
  /// Once a duplicate is found, deletes it from storage and refuses to save it.
  List<T> deduplicateFiles<T>({
    required List<T> items,
    required String Function(T) path,
    required String Function(T) name,
    required int Function(T) fileSize,
    String? Function(T)? shaKey,
  }) {
    final Set<String> seenPaths = {};
    final Set<String> seenNameSize = {};
    final Set<String> seenSha = {};
    final List<T> unique = [];

    for (final item in items) {
      final p = path(item);
      final key = '${name(item).toLowerCase()}_${fileSize(item)}';
      final sha = shaKey != null ? shaKey(item) : null;
      final hasSha = sha != null && sha.isNotEmpty;

      final isDuplicate = seenPaths.contains(p) ||
          seenNameSize.contains(key) ||
          (hasSha && seenSha.contains(sha));

      if (isDuplicate) {
        // Delete duplicate file from storage if saved
        try {
          final file = File(p);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
        continue;
      }

      seenPaths.add(p);
      seenNameSize.add(key);
      if (hasSha) seenSha.add(sha);
      unique.add(item);
    }
    return unique;
  }

  /// Removes duplicate Videos while loading (checks canonical path and name + size)
  List<DeviceVideo> removeDuplicateVideos(List<DeviceVideo> videos) {
    return deduplicateFiles<DeviceVideo>(
      items: videos,
      path: (v) => v.path,
      name: (v) => v.name,
      fileSize: (v) => v.fileSize,
    );
  }

  /// Removes duplicate Audios while loading (checks canonical path and name + size)
  List<DeviceAudio> removeDuplicateAudios(List<DeviceAudio> audios) {
    return deduplicateFiles<DeviceAudio>(
      items: audios,
      path: (a) => a.path,
      name: (a) => a.name,
      fileSize: (a) => a.fileSize,
    );
  }

  /// Removes duplicate Documents while loading (checks canonical path and name + size)
  List<DeviceDocument> removeDuplicateDocuments(List<DeviceDocument> documents) {
    return deduplicateFiles<DeviceDocument>(
      items: documents,
      path: (d) => d.path,
      name: (d) => d.name,
      fileSize: (d) => d.fileSize,
    );
  }

  /// Removes duplicate Contacts while loading across accounts/providers (Google, SIM, Phone)
  List<DeviceContact> removeDuplicateContacts(List<DeviceContact> contacts) {
    final Set<String> seenKeys = {};
    final List<DeviceContact> unique = [];

    for (final c in contacts) {
      final norm = normalizePhone(c.number, fallback: c.name);
      final key = '${c.name.trim().toLowerCase()}_$norm';
      if (seenKeys.add(key)) {
        unique.add(c);
      }
    }
    return unique;
  }

  /// Removes duplicate SMS messages while loading (by normalized address, body hash and timestamp bucket)
  List<DeviceSms> removeDuplicateSms(List<DeviceSms> smsList) {
    final Set<String> seenKeys = {};
    final List<DeviceSms> unique = [];

    for (final sms in smsList) {
      final norm = normalizePhone(sms.address, fallback: sms.address);
      final timeBucket = sms.date.millisecondsSinceEpoch ~/ 2000;
      final bodyHash = sms.body.hashCode;
      final key = '${norm}_${timeBucket}_$bodyHash';
      if (seenKeys.add(key)) {
        unique.add(sms);
      }
    }
    unique.sort((a, b) => b.date.compareTo(a.date));
    return unique;
  }
}
