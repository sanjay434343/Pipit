import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_service.dart';

/// Centralized, high-performance Preferences Service
/// Uses SharedPreferences for instant, persistent access with SQLite fallback
/// for state synchronization across app launches, onboarding, permissions,
/// sorting modes, and individual category scanning controls.
class PreferencesService {
  PreferencesService._internal();
  static final PreferencesService instance = PreferencesService._internal();

  SharedPreferences? _prefs;

  // Key Constants
  static const String keyHasVisitedAll = 'has_visited_all';
  static const String keyHasCompletedOnboarding = 'has_completed_onboarding';
  static const String keyHasCompletedPermissions = 'has_completed_permissions';
  static const String keySortMode = 'sort_mode';
  static const String keyGridColumns = 'grid_columns';

  // Scanning Control Keys
  static const String keyScanPhotos = 'scan_photos';
  static const String keyScanVideos = 'scan_videos';
  static const String keyScanAudio = 'scan_audio';
  static const String keyScanDocuments = 'scan_documents';
  static const String keyScanApps = 'scan_apps';
  static const String keyScanContacts = 'scan_contacts';
  static const String keyScanSms = 'scan_sms';

  /// Initialize SharedPreferences instance
  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      debugPrint('PreferencesService initialized successfully.');
    } catch (e) {
      debugPrint('PreferencesService init error (falling back to SQLite): $e');
    }
  }

  // --- ROUTING & ONBOARDING STATE ---

  bool get hasVisitedAll {
    return _prefs?.getBool(keyHasVisitedAll) ?? false;
  }

  Future<void> setHasVisitedAll(bool value) async {
    await _prefs?.setBool(keyHasVisitedAll, value);
    // Sync with SQLite
    await DatabaseService.instance.setAppSetting(keyHasVisitedAll, value ? 'true' : 'false');
  }

  bool get hasCompletedOnboarding {
    return _prefs?.getBool(keyHasCompletedOnboarding) ?? false;
  }

  Future<void> setHasCompletedOnboarding(bool value) async {
    await _prefs?.setBool(keyHasCompletedOnboarding, value);
    await DatabaseService.instance.setAppSetting(keyHasCompletedOnboarding, value ? 'true' : 'false');
  }

  bool get hasCompletedPermissions {
    return _prefs?.getBool(keyHasCompletedPermissions) ?? false;
  }

  Future<void> setHasCompletedPermissions(bool value) async {
    await _prefs?.setBool(keyHasCompletedPermissions, value);
    await DatabaseService.instance.setAppSetting(keyHasCompletedPermissions, value ? 'true' : 'false');
  }

  // --- SORT MODE & GRID COLUMNS ---

  String get sortMode {
    return _prefs?.getString(keySortMode) ?? 'date_desc';
  }

  Future<void> setSortMode(String mode) async {
    await _prefs?.setString(keySortMode, mode);
    await DatabaseService.instance.setAppSetting(keySortMode, mode);
  }

  int get gridColumns {
    return _prefs?.getInt(keyGridColumns) ?? 2;
  }

  Future<void> setGridColumns(int cols) async {
    await _prefs?.setInt(keyGridColumns, cols);
    await DatabaseService.instance.setAppSetting(keyGridColumns, cols.toString());
  }

  // --- CATEGORY ORDERING & REARRANGEMENT ---

  static const String keyCategoryOrder = 'category_order';
  static const List<String> defaultCategoryOrder = [
    'photos',
    'videos',
    'audio',
    'documents',
    'apps',
    'contacts',
    'sms',
  ];

  /// Get custom ordered list of category keys.
  /// Note: 'all' is always fixed at index 0 on the Home Screen.
  List<String> get categoryOrder {
    final stored = _prefs?.getStringList(keyCategoryOrder);
    if (stored == null || stored.isEmpty) {
      return List<String>.from(defaultCategoryOrder);
    }
    final result = <String>[];
    for (final cat in stored) {
      final normalized = cat.toLowerCase().trim();
      if (defaultCategoryOrder.contains(normalized) && !result.contains(normalized)) {
        result.add(normalized);
      }
    }
    for (final cat in defaultCategoryOrder) {
      if (!result.contains(cat)) {
        result.add(cat);
      }
    }
    return result;
  }

  /// Persist custom category order to SharedPreferences and SQLite app_settings.
  Future<void> setCategoryOrder(List<String> order) async {
    await _prefs?.setStringList(keyCategoryOrder, order);
    await DatabaseService.instance.setAppSetting(keyCategoryOrder, order.join(','));
  }

  // --- CATEGORY SCANNING TOGGLES ---

  /// Check whether scanning is enabled for a specific category.
  /// Supported categories: 'photos', 'videos', 'audio', 'documents', 'apps', 'contacts', 'sms'
  /// Defaults to TRUE (scanning enabled).
  bool isCategoryScanningEnabled(String category) {
    final key = _getScanKey(category);
    return _prefs?.getBool(key) ?? true;
  }

  /// Toggle scanning on/off for a specific category.
  Future<void> setCategoryScanningEnabled(String category, bool enabled) async {
    final key = _getScanKey(category);
    await _prefs?.setBool(key, enabled);
    await DatabaseService.instance.setAppSetting(key, enabled ? 'true' : 'false');
  }

  String _getScanKey(String category) {
    switch (category.toLowerCase()) {
      case 'photos':
      case 'images':
        return keyScanPhotos;
      case 'videos':
        return keyScanVideos;
      case 'audio':
      case 'music':
        return keyScanAudio;
      case 'documents':
      case 'docs':
        return keyScanDocuments;
      case 'apps':
        return keyScanApps;
      case 'contacts':
        return keyScanContacts;
      case 'sms':
      case 'message':
      case 'messages':
        return keyScanSms;
      default:
        return 'scan_$category';
    }
  }
}
