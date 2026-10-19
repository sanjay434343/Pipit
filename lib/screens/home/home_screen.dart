import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:go_router/go_router.dart';
import '../../services/ai_service.dart';
import '../../services/image_collector_service.dart';
import '../../services/duplicate_remover_service.dart';
import '../../services/database_service.dart';
import '../../services/background_worker_service.dart';
import '../../services/document_collector_service.dart';
import '../../services/text_extraction_service.dart';
import '../../services/live_storage_watcher_service.dart';
import '../../services/device_info_service.dart';
import '../../services/media_collector_service.dart';
import '../../services/model_storage_service.dart';
import '../../services/model_downloader_service.dart';
import '../../services/preferences_service.dart';
import 'package:flutter/services.dart';

class DeviceImage implements EmbeddableItem {
  @override
  final String id;
  @override
  final String path;
  @override
  final String name;
  @override
  final int fileSize;
  final DateTime modifiedDate;
  final String? location;
  final String? shaKey;
  @override
  bool isProcessed;
  @override
  List<double>? embedding;
  @override
  double? score;
  @override
  bool isEmbedding = false;
  String? extractedText;

  DeviceImage({
    required this.id,
    required this.path,
    required this.name,
    this.fileSize = 0,
    DateTime? modifiedDate,
    this.location,
    this.shaKey,
    this.isProcessed = false,
    this.embedding,
    this.score,
    this.isEmbedding = false,
    this.extractedText,
  }) : modifiedDate = modifiedDate ?? DateTime.fromMillisecondsSinceEpoch(0);
}

enum TimelineItemType {
  photo,
  video,
  audio,
  document,
  app,
  contact,
  sms,
}

class TimelineItem {
  final TimelineItemType type;
  final String id;
  final String title;
  final String subtitle;
  final DateTime timestamp;
  final String? path;
  final int? fileSize;
  final dynamic originalObject;
  double? score;

  TimelineItem({
    required this.type,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.timestamp,
    this.path,
    this.fileSize,
    required this.originalObject,
    this.score,
  });

  String get typeLabel {
    switch (type) {
      case TimelineItemType.photo:
        return 'PHOTO';
      case TimelineItemType.video:
        return 'VIDEO';
      case TimelineItemType.audio:
        return 'AUDIO';
      case TimelineItemType.document:
        return 'DOC';
      case TimelineItemType.app:
        return 'APP';
      case TimelineItemType.contact:
        return 'CONTACT';
      case TimelineItemType.sms:
        return 'SMS';
    }
  }

  IconData get icon {
    switch (type) {
      case TimelineItemType.photo:
        return Icons.photo_library_outlined;
      case TimelineItemType.video:
        return Icons.videocam_outlined;
      case TimelineItemType.audio:
        return Icons.audiotrack_outlined;
      case TimelineItemType.document:
        return Icons.description_outlined;
      case TimelineItemType.app:
        return Icons.apps_outlined;
      case TimelineItemType.contact:
        return Icons.contacts_outlined;
      case TimelineItemType.sms:
        return Icons.sms_outlined;
    }
  }

  Color get color {
    switch (type) {
      case TimelineItemType.photo:
        return const Color(0xFF00897B); // Teal
      case TimelineItemType.video:
        return const Color(0xFFE53935); // Red
      case TimelineItemType.audio:
        return const Color(0xFFFB8C00); // Orange
      case TimelineItemType.document:
        return const Color(0xFF1E88E5); // Blue
      case TimelineItemType.app:
        return const Color(0xFF5C6BC0); // Indigo
      case TimelineItemType.contact:
        return const Color(0xFF00ACC1); // Cyan
      case TimelineItemType.sms:
        return const Color(0xFF8E24AA); // Purple
    }
  }
}

class _CategoryTabDef {
  final String key;
  final String label;
  final String assetPath;
  final IconData icon;
  final int Function() countGetter;
  final Widget Function() viewBuilder;
  const _CategoryTabDef({
    required this.key,
    required this.label,
    required this.assetPath,
    required this.icon,
    required this.countGetter,
    required this.viewBuilder,
  });
}

class HomeScreen extends StatefulWidget {
  final bool isSplashPreview;
  const HomeScreen({super.key, this.isSplashPreview = false});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late TabController _tabController;
  String _lastActiveTabKeysSignature = '';

  List<_CategoryTabDef> _getActiveTabDefs({
    int? indexedCount,
    bool? isWorkerRunning,
    bool? isPaused,
  }) {
    final prefs = PreferencesService.instance;
    // 'All' is always fixed at index 0 (pinned in same space)
    final List<_CategoryTabDef> tabs = [
      _CategoryTabDef(
        key: 'all',
        label: 'All',
        assetPath: 'assets/iamges/all.png',
        icon: Icons.auto_awesome_motion_outlined,
        countGetter: () => _hasSubmittedSearch ? _filteredTimelineItems.length : _timelineItems.length,
        viewBuilder: () => _buildAllTimelineTab(),
      ),
    ];

    // Build remaining tabs in the user's custom-ordered sequence
    final orderedKeys = prefs.categoryOrder;
    for (final key in orderedKeys) {
      if (!prefs.isCategoryScanningEnabled(key)) continue;

      switch (key.toLowerCase()) {
        case 'photos':
          tabs.add(_CategoryTabDef(
            key: 'photos',
            label: 'Photos',
            assetPath: 'assets/iamges/images.png',
            icon: Icons.photo_library_outlined,
            countGetter: () => _hasSubmittedSearch ? _searchResults.length : _images.length,
            viewBuilder: () => _buildPhotosTab(
              indexedCount ?? _images.where((i) => i.isProcessed || i.embedding != null).length,
              isWorkerRunning ?? BackgroundWorkerService.instance.isImageEmbeddingActive,
              isPaused ?? BackgroundWorkerService.instance.isPaused,
            ),
          ));
          break;
        case 'videos':
          tabs.add(_CategoryTabDef(
            key: 'videos',
            label: 'Videos',
            assetPath: 'assets/iamges/video.png',
            icon: Icons.videocam_outlined,
            countGetter: () => _hasSubmittedSearch ? _filteredVideos.length : _videos.length,
            viewBuilder: () => _buildVideosTab(),
          ));
          break;
        case 'audio':
          tabs.add(_CategoryTabDef(
            key: 'audio',
            label: 'Audio',
            assetPath: 'assets/iamges/music.png',
            icon: Icons.audiotrack_outlined,
            countGetter: () => _hasSubmittedSearch ? _filteredAudios.length : _audios.length,
            viewBuilder: () => _buildAudiosTab(),
          ));
          break;
        case 'documents':
          tabs.add(_CategoryTabDef(
            key: 'documents',
            label: 'Docs',
            assetPath: 'assets/iamges/documents.png',
            icon: Icons.description_outlined,
            countGetter: () => _hasSubmittedSearch ? _filteredDocuments.length : _documents.length,
            viewBuilder: () => _buildDocumentsTab(),
          ));
          break;
        case 'apps':
          tabs.add(_CategoryTabDef(
            key: 'apps',
            label: 'Apps',
            assetPath: 'assets/iamges/apps.png',
            icon: Icons.apps_rounded,
            countGetter: () => _hasSubmittedSearch ? _filteredApps.length : _apps.where((a) => _isUserFacingApp(a)).length,
            viewBuilder: () => _buildAppsTab(),
          ));
          break;
        case 'contacts':
          tabs.add(_CategoryTabDef(
            key: 'contacts',
            label: 'Contacts',
            assetPath: 'assets/iamges/contacts.png',
            icon: Icons.contacts_outlined,
            countGetter: () => _hasSubmittedSearch ? _filteredContacts.length : _contacts.length,
            viewBuilder: () => _buildContactsTab(),
          ));
          break;
        case 'sms':
          tabs.add(_CategoryTabDef(
            key: 'sms',
            label: 'SMS',
            assetPath: 'assets/iamges/message.png',
            icon: Icons.sms_outlined,
            countGetter: () => _hasSubmittedSearch ? _filteredSms.length : _smsList.length,
            viewBuilder: () => _buildSmsTab(),
          ));
          break;
      }
    }

    return tabs;
  }

  // Real Device Documents State
  List<DeviceDocument> _documents = [];
  List<DeviceDocument> _filteredDocuments = [];
  bool _isLoadingDocuments = false;
  String _documentsStatus = 'No documents loaded yet.';
  DocumentCategory? _selectedDocCategory;
  final String _docSortBy = 'date'; // 'date', 'name', 'size'

  // Videos State
  List<DeviceVideo> _videos = [];
  List<DeviceVideo> _filteredVideos = [];
  bool _isLoadingVideos = false;

  // Audios State
  List<DeviceAudio> _audios = [];
  List<DeviceAudio> _filteredAudios = [];
  bool _isLoadingAudios = false;

  // Apps State
  List<DeviceApp> _apps = [];
  List<DeviceApp> _filteredApps = [];
  bool _isLoadingApps = false;

  // Contacts State
  List<DeviceContact> _contacts = [];
  List<DeviceContact> _filteredContacts = [];
  bool _isLoadingContacts = false;

  // SMS State
  List<DeviceSms> _smsList = [];
  List<DeviceSms> _filteredSms = [];
  bool _isLoadingSms = false;

  // Permissions Tracking State
  List<String> _missingPermissions = [];
  bool _hasDeniedPermissions = false;
  bool _wasMissingPermissions = false;
  bool _isPermanentlyDenied = false;
  bool _isCheckingPermissions = false;
  bool _bannerDismissed = false;
  bool _modelBannerDismissed = false;
  int _gridColumns = 2;
  double get _cardRadius => _gridColumns == 2 ? 23.0 : (_gridColumns == 3 ? 18.0 : 14.0);
  String _sortMode = 'date_desc';

  Future<void> _loadGridColumnsSetting() async {
    final cols = PreferencesService.instance.gridColumns;
    if (_gridColumns != cols && mounted) {
      setState(() {
        _gridColumns = cols;
      });
    }
  }

  Future<void> _loadSortModeSetting({bool force = false}) async {
    final effective = PreferencesService.instance.sortMode;
    if ((_sortMode != effective || force) && mounted) {
      setState(() {
        _sortMode = effective;
      });
      _applyAllSorting();
    }
  }

  String _getSortModeLabel() {
    switch (_sortMode) {
      case 'date_asc':
        return 'Sorted: Oldest first';
      case 'name_asc':
        return 'Sorted: Name (A-Z)';
      case 'name_desc':
        return 'Sorted: Name (Z-A)';
      case 'size_desc':
        return 'Sorted: Largest size';
      case 'size_asc':
        return 'Sorted: Smallest size';
      case 'date_desc':
      default:
        return 'Sorted: Newest first';
    }
  }

  void _sortTimelineItemsList(List<TimelineItem> list) {
    list.sort((a, b) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        final sA = a.score ?? 0.0;
        final sB = b.score ?? 0.0;
        final diff = sB.compareTo(sA);
        if (diff != 0) return diff;
      }
      switch (_sortMode) {
        case 'date_asc':
          return a.timestamp.compareTo(b.timestamp);
        case 'name_asc':
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case 'name_desc':
          return b.title.toLowerCase().compareTo(a.title.toLowerCase());
        case 'size_desc':
          final sizeDiff = (b.fileSize ?? 0).compareTo(a.fileSize ?? 0);
          return sizeDiff != 0 ? sizeDiff : b.timestamp.compareTo(a.timestamp);
        case 'size_asc':
          final sizeDiff = (a.fileSize ?? 0).compareTo(b.fileSize ?? 0);
          return sizeDiff != 0 ? sizeDiff : b.timestamp.compareTo(a.timestamp);
        case 'date_desc':
        default:
          return b.timestamp.compareTo(a.timestamp);
      }
    });
  }

  void _sortImagesList(List<DeviceImage> list) {
    list.sort((a, b) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        final sA = a.score ?? 0.0;
        final sB = b.score ?? 0.0;
        final diff = sB.compareTo(sA);
        if (diff != 0) return diff;
      }
      switch (_sortMode) {
        case 'date_asc':
          return a.modifiedDate.compareTo(b.modifiedDate);
        case 'name_asc':
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'name_desc':
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case 'size_desc':
          final sDiff = b.fileSize.compareTo(a.fileSize);
          return sDiff != 0 ? sDiff : b.modifiedDate.compareTo(a.modifiedDate);
        case 'size_asc':
          final sDiff = a.fileSize.compareTo(b.fileSize);
          return sDiff != 0 ? sDiff : b.modifiedDate.compareTo(a.modifiedDate);
        case 'date_desc':
        default:
          return b.modifiedDate.compareTo(a.modifiedDate);
      }
    });
  }

  void _sortVideosList(List<DeviceVideo> list) {
    list.sort((a, b) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        final sA = a.score ?? 0.0;
        final sB = b.score ?? 0.0;
        final diff = sB.compareTo(sA);
        if (diff != 0) return diff;
      }
      switch (_sortMode) {
        case 'date_asc':
          return a.modifiedDate.compareTo(b.modifiedDate);
        case 'name_asc':
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'name_desc':
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case 'size_desc':
          final sDiff = b.fileSize.compareTo(a.fileSize);
          return sDiff != 0 ? sDiff : b.modifiedDate.compareTo(a.modifiedDate);
        case 'size_asc':
          final sDiff = a.fileSize.compareTo(b.fileSize);
          return sDiff != 0 ? sDiff : b.modifiedDate.compareTo(a.modifiedDate);
        case 'date_desc':
        default:
          return b.modifiedDate.compareTo(a.modifiedDate);
      }
    });
  }

  void _sortAudiosList(List<DeviceAudio> list) {
    list.sort((a, b) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        final sA = a.score ?? 0.0;
        final sB = b.score ?? 0.0;
        final diff = sB.compareTo(sA);
        if (diff != 0) return diff;
      }
      switch (_sortMode) {
        case 'date_asc':
          return a.modifiedDate.compareTo(b.modifiedDate);
        case 'name_asc':
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'name_desc':
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case 'size_desc':
          final sDiff = b.fileSize.compareTo(a.fileSize);
          return sDiff != 0 ? sDiff : b.modifiedDate.compareTo(a.modifiedDate);
        case 'size_asc':
          final sDiff = a.fileSize.compareTo(b.fileSize);
          return sDiff != 0 ? sDiff : b.modifiedDate.compareTo(a.modifiedDate);
        case 'date_desc':
        default:
          return b.modifiedDate.compareTo(a.modifiedDate);
      }
    });
  }

  void _sortDocumentsList(List<DeviceDocument> list) {
    list.sort((a, b) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        final sA = a.score ?? 0.0;
        final sB = b.score ?? 0.0;
        final diff = sB.compareTo(sA);
        if (diff != 0) return diff;
      }
      switch (_sortMode) {
        case 'date_asc':
          return a.modifiedDate.compareTo(b.modifiedDate);
        case 'name_asc':
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'name_desc':
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case 'size_desc':
          final sDiff = b.fileSize.compareTo(a.fileSize);
          return sDiff != 0 ? sDiff : b.modifiedDate.compareTo(a.modifiedDate);
        case 'size_asc':
          final sDiff = a.fileSize.compareTo(b.fileSize);
          return sDiff != 0 ? sDiff : b.modifiedDate.compareTo(a.modifiedDate);
        case 'date_desc':
        default:
          return b.modifiedDate.compareTo(a.modifiedDate);
      }
    });
  }

  void _sortAppsList(List<DeviceApp> list) {
    list.sort((a, b) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        final q = _searchController.text.trim().toLowerCase();
        final sDiff = _scoreAppMatch(b, q).compareTo(_scoreAppMatch(a, q));
        if (sDiff != 0) return sDiff;
      }
      switch (_sortMode) {
        case 'name_desc':
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case 'name_asc':
        default:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    });
  }

  void _sortContactsList(List<DeviceContact> list) {
    list.sort((a, b) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        final q = _searchController.text.trim().toLowerCase();
        final aNameMatch = a.name.toLowerCase().startsWith(q);
        final bNameMatch = b.name.toLowerCase().startsWith(q);
        if (aNameMatch && !bNameMatch) return -1;
        if (!aNameMatch && bNameMatch) return 1;
      }
      switch (_sortMode) {
        case 'name_desc':
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case 'name_asc':
        default:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    });
  }

  void _sortSmsList(List<DeviceSms> list) {
    list.sort((a, b) {
      switch (_sortMode) {
        case 'date_asc':
          return a.date.compareTo(b.date);
        case 'name_asc':
          final nDiff = a.address.toLowerCase().compareTo(b.address.toLowerCase());
          return nDiff != 0 ? nDiff : b.date.compareTo(a.date);
        case 'name_desc':
          final nDiff = b.address.toLowerCase().compareTo(a.address.toLowerCase());
          return nDiff != 0 ? nDiff : b.date.compareTo(a.date);
        case 'size_desc':
          final sDiff = b.body.length.compareTo(a.body.length);
          return sDiff != 0 ? sDiff : b.date.compareTo(a.date);
        case 'size_asc':
          final sDiff = a.body.length.compareTo(b.body.length);
          return sDiff != 0 ? sDiff : b.date.compareTo(a.date);
        case 'date_desc':
        default:
          return b.date.compareTo(a.date);
      }
    });
  }

  void _applyAllSorting() {
    _sortTimelineItemsList(_timelineItems);
    _sortTimelineItemsList(_filteredTimelineItems);
    _sortTimelineItemsList(_universalSearchResults);
    _sortImagesList(_images);
    _sortImagesList(_searchResults);
    _sortVideosList(_videos);
    _sortVideosList(_filteredVideos);
    _sortAudiosList(_audios);
    _sortAudiosList(_filteredAudios);
    _sortDocumentsList(_documents);
    _sortDocumentsList(_filteredDocuments);
    _sortAppsList(_apps);
    _sortAppsList(_filteredApps);
    _sortContactsList(_contacts);
    _sortContactsList(_filteredContacts);
    _sortSmsList(_smsList);
    _sortSmsList(_filteredSms);
    if (mounted) setState(() {});
  }

  bool _isModelReady = false;
  int _parallelWorkers = 4;
  int? _lastBatchLatencyMs;
  String? _activeBackendName;
  String? _selectedFileName;
  String? _selectedFilePath;
  String? _statusMessage;

  // Embedding & Search State
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final GlobalKey _searchBarKey = GlobalKey();
  Timer? _searchDebounceTimer;
  bool _isSearching = false;
  bool _hasSubmittedSearch = false;
  int _searchEpoch = 0;
  int _searchRequestId = 0;
  int? _lastSearchLatencyMs;
  int? _vectorDimension;

  // Real Device Images State (Deduplicated)
  List<DeviceImage> _images = [];
  List<DeviceImage> _searchResults = [];
  bool _isLoadingImages = false;
  bool _isIndexing = false;
  String _imageStatus = 'No photos loaded yet.';
  int _duplicatesCount = 0;
  int _displayLimit = 24;
  int _timelineDisplayLimit = 24;
  int _videoDisplayLimit = 24;
  int _audioDisplayLimit = 24;
  int _docDisplayLimit = 24;
  int _appDisplayLimit = 60;
  int _contactDisplayLimit = 24;
  int _smsDisplayLimit = 24;
  final ScrollController _scrollController = ScrollController();

  // Timeline State ("All" Category)
  List<TimelineItem> _timelineItems = [];
  List<TimelineItem> _filteredTimelineItems = [];
  List<TimelineItem> _universalSearchResults = [];
  bool _isLoadingTimeline = false;
  bool _isInitialLoading = true;
  bool _hasInitialTimerElapsed = false;
  Timer? _initialLoadTimer;
  Timer? _maxInitialLoadTimer;

  bool get _isStillLoadingContent {
    return _isLoadingImages ||
        _isLoadingVideos ||
        _isLoadingAudios ||
        _isLoadingDocuments ||
        _isLoadingApps ||
        _isLoadingContacts ||
        _isLoadingSms;
  }

  void _checkAndFinishInitialLoading() {
    if (!mounted || !_isInitialLoading) return;
    if (_hasInitialTimerElapsed) {
      final bool hasAnyData = _timelineItems.isNotEmpty ||
          _images.isNotEmpty ||
          _videos.isNotEmpty ||
          _documents.isNotEmpty ||
          _apps.isNotEmpty ||
          _contacts.isNotEmpty ||
          _smsList.isNotEmpty;
      final bool isStillScanningPrimary = _isLoadingImages && _images.isEmpty;

      if (hasAnyData || !isStillScanningPrimary) {
        setState(() {
          _isInitialLoading = false;
        });
      }
    }
  }

  // Live Processing Status Ticker
  String? _liveProcessingStatus;
  Timer? _liveStatusTimer;

  void _setLiveProcessing(
    String? status, {
    Duration autoDismiss = const Duration(seconds: 4),
  }) {
    if (!mounted) return;
    _liveStatusTimer?.cancel();
    setState(() {
      _liveProcessingStatus = status;
    });
    if (status != null) {
      _liveStatusTimer = Timer(autoDismiss, () {
        if (mounted) {
          setState(() {
            _liveProcessingStatus = null;
          });
        }
      });
    }
  }

  String? get _currentProcessingStatus {
    if (_isSearching) return 'AI Searching...';

    final isWorkerActive = BackgroundWorkerService.instance.isBackgroundWorkerActive ||
        BackgroundWorkerService.instance.isImageEmbeddingActive ||
        BackgroundWorkerService.instance.isDocumentExtractionActive;

    if (isWorkerActive) {
      final pendingImages = _images.where((i) => i.embedding == null).length;
      final pendingDocs = _documents
          .where(
            (d) =>
                (!d.isOcrProcessed ||
                    (d.embedding == null && AiService.instance.isModelLoaded)) &&
                (d.category == DocumentCategory.pdf ||
                    d.category == DocumentCategory.text),
          )
          .length;
      final workerPending = BackgroundWorkerService.instance.pendingCount;

      if (pendingImages == 0 && pendingDocs == 0 && workerPending == 0) {
        return null;
      }
      return BackgroundWorkerService.instance.workerStatus;
    }

    if (_liveProcessingStatus != null) {
      final s = _liveProcessingStatus!.toLowerCase();
      if (s.contains('stopped') ||
          s.contains('finished') ||
          s.contains('idle') ||
          s.contains('auto-stopped')) {
        return null;
      }
      return _liveProcessingStatus;
    }

    return null;
  }

  String _normalizePhoneNumber(String raw, {String fallback = ''}) {
    final cleaned = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    if (cleaned.isEmpty) return fallback.trim().toLowerCase();
    final digits = cleaned.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length >= 10) return digits.substring(digits.length - 10);
    return cleaned.toLowerCase();
  }

  void _updateTimeline() {
    final List<TimelineItem> items = [];

    // 1. Photos
    if (PreferencesService.instance.isCategoryScanningEnabled('photos')) {
      final sortedImages = List<DeviceImage>.from(_images);
      _sortImagesList(sortedImages);
      final seenPhotoPaths = <String>{};
      for (final img in sortedImages) {
        if (seenPhotoPaths.add(img.path)) {
          items.add(
            TimelineItem(
              type: TimelineItemType.photo,
              id: img.path,
              title: img.name,
              subtitle: _formatDate(img.modifiedDate).split(' ').first,
              timestamp: img.modifiedDate,
              path: img.path,
              fileSize: img.fileSize,
              originalObject: img,
            ),
          );
        }
      }
    }

    // 2. Videos
    if (PreferencesService.instance.isCategoryScanningEnabled('videos')) {
      final sortedVideos = List<DeviceVideo>.from(_videos);
      _sortVideosList(sortedVideos);
      final seenVideoPaths = <String>{};
      for (final vid in sortedVideos) {
        if (seenVideoPaths.add(vid.path)) {
          items.add(
            TimelineItem(
              type: TimelineItemType.video,
              id: vid.path,
              title: vid.name,
              subtitle: _formatDate(vid.modifiedDate).split(' ').first,
              timestamp: vid.modifiedDate,
              path: vid.path,
              fileSize: vid.fileSize,
              originalObject: vid,
            ),
          );
        }
      }
    }

    // 3. Audio
    if (PreferencesService.instance.isCategoryScanningEnabled('audio')) {
      final sortedAudios = List<DeviceAudio>.from(_audios);
      _sortAudiosList(sortedAudios);
      final seenAudioPaths = <String>{};
      for (final aud in sortedAudios) {
        if (seenAudioPaths.add(aud.path)) {
          items.add(
            TimelineItem(
              type: TimelineItemType.audio,
              id: aud.path,
              title: aud.name,
              subtitle: _formatDate(aud.modifiedDate).split(' ').first,
              timestamp: aud.modifiedDate,
              path: aud.path,
              fileSize: aud.fileSize,
              originalObject: aud,
            ),
          );
        }
      }
    }

    // 4. Documents
    if (PreferencesService.instance.isCategoryScanningEnabled('documents')) {
      final sortedDocs = List<DeviceDocument>.from(_documents);
      _sortDocumentsList(sortedDocs);
      final seenDocPaths = <String>{};
      for (final doc in sortedDocs) {
        if (seenDocPaths.add(doc.path)) {
          items.add(
            TimelineItem(
              type: TimelineItemType.document,
              id: doc.path,
              title: doc.name,
              subtitle: doc.categoryLabel,
              timestamp: doc.modifiedDate,
              path: doc.path,
              fileSize: doc.fileSize,
              originalObject: doc,
            ),
          );
        }
      }
    }

    // 5. Apps (User-installed and launchable apps)
    if (PreferencesService.instance.isCategoryScanningEnabled('apps')) {
      final userApps = _apps.where((a) => _isUserFacingApp(a)).toList();
      final topApps = userApps;
      final seenAppPackages = <String>{};
      for (final app in topApps) {
        if (seenAppPackages.add(app.packageName)) {
          items.add(
            TimelineItem(
              type: TimelineItemType.app,
              id: 'app_${app.packageName}',
              title: app.name,
              subtitle: '${app.category} • Installed',
              timestamp: DateTime.fromMillisecondsSinceEpoch(0),
              originalObject: app,
            ),
          );
        }
      }
    }

    // 6. Contacts (Deduplicated by normalized phone number and name)
    if (PreferencesService.instance.isCategoryScanningEnabled('contacts')) {
      final seenContacts = <String>{};
      for (final contact in _contacts) {
        final norm = _normalizePhoneNumber(
          contact.number,
          fallback: contact.name,
        );
        final key = '${contact.name.trim().toLowerCase()}_$norm';
        if (seenContacts.add(key)) {
          items.add(
            TimelineItem(
              type: TimelineItemType.contact,
              id: 'contact_${contact.id}_$norm',
              title: contact.name,
              subtitle: contact.number,
              timestamp: DateTime.fromMillisecondsSinceEpoch(0),
              originalObject: contact,
            ),
          );
        }
      }
    }

    // 7. SMS Messages (Deduplicated by sender: only the latest SMS per contact/sender)
    if (PreferencesService.instance.isCategoryScanningEnabled('sms')) {
      final seenSmsSenders = <String>{};
      for (final sms in _smsList) {
        final key = _normalizePhoneNumber(sms.address, fallback: sms.address);
        if (seenSmsSenders.add(key)) {
          items.add(
            TimelineItem(
              type: TimelineItemType.sms,
              id: 'sms_${sms.date.millisecondsSinceEpoch}_$key',
              title: sms.address,
              subtitle: sms.body,
              timestamp: sms.date,
              originalObject: sms,
            ),
          );
        }
      }
    }

    // Apply Universal Sort Mode
    _sortTimelineItemsList(items);

    if (mounted) {
      setState(() {
        _timelineItems = items;
        _applyTimelineFilters();
      });
      _checkAndFinishInitialLoading();
    }
  }

  void _applyTimelineFilters() {
    final q = _searchController.text.trim().toLowerCase();
    if (_hasSubmittedSearch && q.isNotEmpty) {
      _filteredTimelineItems = List.from(_universalSearchResults);
    } else {
      _filteredTimelineItems = List.from(_timelineItems);
    }
    _sortTimelineItemsList(_filteredTimelineItems);
  }

  void _openMediaFile(String path, {String? mimeType}) {
    if (!File(path).existsSync()) {
      _handleLiveFileDeleted(path);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File was deleted from device storage and removed.'),
          duration: Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    DeviceInfoService.instance.openFile(path, mimeType: mimeType);
  }

  void _onTimelineItemTapped(TimelineItem item) {
    if (item.path != null && item.path!.isNotEmpty && !File(item.path!).existsSync()) {
      _handleLiveFileDeleted(item.path!);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File was deleted from device storage and removed.'),
          duration: Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    switch (item.type) {
      case TimelineItemType.photo:
        final img = item.originalObject as DeviceImage;
        _openMediaFile(img.path);
        break;
      case TimelineItemType.video:
        final vid = item.originalObject as DeviceVideo;
        _openMediaFile(vid.path);
        break;
      case TimelineItemType.audio:
        final aud = item.originalObject as DeviceAudio;
        _openMediaFile(aud.path);
        break;
      case TimelineItemType.document:
        final doc = item.originalObject as DeviceDocument;
        _openMediaFile(doc.path);
        break;
      case TimelineItemType.app:
        final app = item.originalObject as DeviceApp;
        DeviceInfoService.instance.openApp(app.packageName);
        break;
      case TimelineItemType.contact:
        final contact = item.originalObject as DeviceContact;
        DeviceInfoService.instance.openContact(number: contact.number);
        break;
      case TimelineItemType.sms:
        final sms = item.originalObject as DeviceSms;
        DeviceInfoService.instance.openSms(address: sms.address, body: sms.body);
        break;
    }
  }

  String _formatTimelineDate(DateTime dt) {
    if (dt.millisecondsSinceEpoch <= 0) return '';
    final now = DateTime.now();
    final difference = now.difference(dt);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays == 0) {
      return 'Today ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (difference.inDays == 1) {
      return 'Yesterday ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  void _onTabControllerTick() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    final initialTabs = _getActiveTabDefs();
    _lastActiveTabKeysSignature = initialTabs.map((t) => t.key).join(',');
    _tabController = TabController(length: initialTabs.length, vsync: this);
    _tabController.addListener(_onTabControllerTick);

    if (widget.isSplashPreview) {
      _isInitialLoading = true;
      return;
    }

    _isModelReady = AiService.instance.isModelLoaded;
    _parallelWorkers = AiService.instance.parallelThreads;
    WidgetsBinding.instance.addObserver(this);
    BackgroundWorkerService.instance.addListener(_onBackgroundWorkerUpdate);
    AiService.instance.addListener(_onAiServiceUpdate);
    ModelStorageService.instance.addListener(_onModelServiceUpdate);
    ModelDownloaderService.instance.addListener(_onModelServiceUpdate);
    ModelStorageService.instance.quickSyncScan();
    ModelStorageService.instance.scanAvailableModels();
    _loadGridColumnsSetting();
    _loadSortModeSetting();
    _scrollController.addListener(_onScroll);
    _initApp();
    _startLiveWatcher();

    // Show shimmer for 3 seconds as default on Home Screen
    _isInitialLoading = true;
    _hasInitialTimerElapsed = false;
    _initialLoadTimer = Timer(const Duration(seconds: 3), () {
      _hasInitialTimerElapsed = true;
      _checkAndFinishInitialLoading();
    });

    // Safety fallback: Never keep shimmer active longer than 8 seconds
    _maxInitialLoadTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _isInitialLoading) {
        setState(() {
          _isInitialLoading = false;
        });
      }
    });
  }

  void _startLiveWatcher() {
    LiveStorageWatcherService.instance.startWatching(
      onNewImage: (newImagePath) async {
        if (!PreferencesService.instance.isCategoryScanningEnabled('photos')) return;
        debugPrint(
          '📸 [HomeScreen] Realtime new image received: $newImagePath',
        );
        try {
          final file = File(newImagePath);
          if (!await file.exists()) return;
          final stat = await file.stat();
          final name = file.path.split(Platform.pathSeparator).last;
          _setLiveProcessing('Live Photo Added: $name');

          final shaKey = await DatabaseService.generateShaKey(
            newImagePath,
            stat.size,
          );

          final newRecord = CachedImageRecord(
            path: newImagePath,
            name: name,
            fileSize: stat.size,
            modifiedTimestamp: stat.modified.millisecondsSinceEpoch,
            location: file.parent.path,
            shaKey: shaKey,
            isProcessed: false,
          );
          await DatabaseService.instance.saveImageRecord(newRecord);

          final newDeviceImg = DeviceImage(
            id: newImagePath,
            path: newImagePath,
            name: name,
            fileSize: stat.size,
            modifiedDate: stat.modified,
            location: file.parent.path,
            shaKey: shaKey,
            isProcessed: false,
          );

          if (mounted) {
            setState(() {
              _images.insert(0, newDeviceImg);
              if (_searchController.text.trim().isEmpty) {
                _searchResults.insert(0, newDeviceImg);
              }
              _imageStatus =
                  '${_images.length} photos (1 new live photo added)';
              _updateTimeline();
            });
          }

          // Trigger OCR extraction in background immediately
          _setLiveProcessing('Image OCR: Extracting $name...');
          TextExtractionService.instance
              .extractTextFromImage(newImagePath)
              .then((ocrText) {
                if (ocrText.isNotEmpty) {
                  DatabaseService.instance.updateImageOcrText(
                    newImagePath,
                    ocrText,
                  );
                  newDeviceImg.extractedText = ocrText;
                  debugPrint('📝 [OCR] Processed live image OCR: $ocrText');
                  _setLiveProcessing(
                    'Image OCR: Extracted text from $name',
                    autoDismiss: const Duration(seconds: 2),
                  );
                  _updateTimeline();
                }
              });

          // Trigger embedding if model loaded
          if (AiService.instance.isModelLoaded) {
            _setLiveProcessing('Image Vision AI: Embedding $name...');
            _embedAllImages();
          }
        } catch (e) {
          debugPrint('Error handling live image: $e');
        }
      },
      onNewDoc: (newDocPath) async {
        if (!PreferencesService.instance.isCategoryScanningEnabled('documents')) return;
        debugPrint(
          '📄 [HomeScreen] Realtime new document received: $newDocPath',
        );
        try {
          final file = File(newDocPath);
          if (!await file.exists()) return;
          final stat = await file.stat();
          final name = file.path.split(Platform.pathSeparator).last;
          _setLiveProcessing('Live Doc Added: $name');

          final ext = file.path.contains('.')
              ? '.${file.path.split('.').last.toLowerCase()}'
              : '';
          final category =
              DocumentCollectorService.supportedExtensions[ext] ??
              DocumentCategory.other;

          final newDoc = DeviceDocument(
            id: newDocPath,
            path: newDocPath,
            name: name,
            extension: ext,
            fileSize: stat.size,
            modifiedDate: stat.modified,
            category: category,
            location: file.parent.path,
          );

          await DatabaseService.instance.saveDocumentRecord(
            CachedDocumentRecord(
              path: newDoc.path,
              name: newDoc.name,
              extension: newDoc.extension,
              category: newDoc.category.name,
              fileSize: newDoc.fileSize,
              modifiedTimestamp: newDoc.modifiedDate.millisecondsSinceEpoch,
              location: newDoc.location,
              isOcrProcessed: false,
            ),
          );

          if (mounted) {
            setState(() {
              _documents.insert(0, newDoc);
              _applyDocumentFilters();
              _documentsStatus =
                  '${_documents.length} documents (1 new doc added)';
              _updateTimeline();
            });
          }

          // Trigger OCR / text extraction immediately in background
          if (category == DocumentCategory.pdf) {
            _setLiveProcessing('Doc OCR: Extracting $name...');
            TextExtractionService.instance.extractTextFromPdf(newDocPath).then((
              extracted,
            ) {
              if (extracted.isNotEmpty) {
                newDoc.extractedText = extracted;
                newDoc.isOcrProcessed = true;
                DatabaseService.instance.updateDocumentOcrText(
                  newDocPath,
                  extracted,
                );
                debugPrint(
                  '📝 [PDF Extractor] Extracted ${extracted.length} chars from live PDF',
                );
                _setLiveProcessing(
                  'Doc OCR: Extracted text from $name',
                  autoDismiss: const Duration(seconds: 2),
                );
                _updateTimeline();
              }
            });
          }
        } catch (e) {
          debugPrint('Error handling live doc: $e');
        }
      },
      onNewVideo: (newVideoPath) async {
        if (!PreferencesService.instance.isCategoryScanningEnabled('videos')) return;
        try {
          final file = File(newVideoPath);
          if (!await file.exists()) return;
          final stat = await file.stat();
          final name = file.path.split(Platform.pathSeparator).last;
          _setLiveProcessing('Live Video Added: $name');

          final newVid = DeviceVideo(
            id: newVideoPath,
            path: newVideoPath,
            name: name,
            fileSize: stat.size,
            modifiedDate: stat.modified,
            location: file.parent.path,
          );
          if (mounted) {
            setState(() {
              _videos.insert(0, newVid);
              _applyVideoFilters();
              _updateTimeline();
            });
          }
          if (AiService.instance.isModelLoaded) {
            _setLiveProcessing('Video Text AI: Embedding $name...');
            AiService.instance
                .embedItemByText(newVid, '${newVid.name} ${newVid.location}')
                .then((_) {
                  if (mounted) {
                    setState(() {});
                    _setLiveProcessing(
                      'Video Text AI: Embedded $name',
                      autoDismiss: const Duration(seconds: 2),
                    );
                  }
                });
          }
        } catch (e) {
          debugPrint('Error handling live video: $e');
        }
      },
      onNewAudio: (newAudioPath) async {
        if (!PreferencesService.instance.isCategoryScanningEnabled('audio')) return;
        try {
          final file = File(newAudioPath);
          if (!await file.exists()) return;
          final stat = await file.stat();
          final name = file.path.split(Platform.pathSeparator).last;
          _setLiveProcessing('Live Audio Added: $name');

          final newAud = DeviceAudio(
            id: newAudioPath,
            path: newAudioPath,
            name: name,
            fileSize: stat.size,
            modifiedDate: stat.modified,
            location: file.parent.path,
          );
          if (mounted) {
            setState(() {
              _audios.insert(0, newAud);
              _applyAudioFilters();
              _updateTimeline();
            });
          }
          if (AiService.instance.isModelLoaded) {
            _setLiveProcessing('Audio Text AI: Embedding $name...');
            AiService.instance
                .embedItemByText(newAud, '${newAud.name} ${newAud.location}')
                .then((_) {
                  if (mounted) {
                    setState(() {});
                    _setLiveProcessing(
                      'Audio Text AI: Embedded $name',
                      autoDismiss: const Duration(seconds: 2),
                    );
                  }
                });
          }
        } catch (e) {
          debugPrint('Error handling live audio: $e');
        }
      },
      onFileDeleted: (deletedPath) {
        _handleLiveFileDeleted(deletedPath);
      },
    );
  }

  void _handleLiveFileDeleted(String deletedPath) {
    debugPrint('🗑️ [DeletionSync] File deleted from storage: $deletedPath');
    DatabaseService.instance.deleteRecordByPath(deletedPath);
    LiveStorageWatcherService.instance.removeKnownPath(deletedPath);

    if (!mounted) return;

    setState(() {
      _images.removeWhere((i) => i.path == deletedPath || i.id == deletedPath);
      _searchResults.removeWhere((i) => i.path == deletedPath || i.id == deletedPath);
      _videos.removeWhere((v) => v.path == deletedPath || v.id == deletedPath);
      _filteredVideos.removeWhere((v) => v.path == deletedPath || v.id == deletedPath);
      _audios.removeWhere((a) => a.path == deletedPath || a.id == deletedPath);
      _filteredAudios.removeWhere((a) => a.path == deletedPath || a.id == deletedPath);
      _documents.removeWhere((d) => d.path == deletedPath || d.id == deletedPath);
      _filteredDocuments.removeWhere((d) => d.path == deletedPath || d.id == deletedPath);
      _universalSearchResults.removeWhere(
        (item) => item.path == deletedPath || item.id == deletedPath || item.id.endsWith(deletedPath),
      );
      _filteredTimelineItems.removeWhere(
        (item) => item.path == deletedPath || item.id == deletedPath || item.id.endsWith(deletedPath),
      );
      _timelineItems.removeWhere(
        (item) => item.path == deletedPath || item.id == deletedPath || item.id.endsWith(deletedPath),
      );
      _updateTimeline();
    });
  }

  Future<void> _pruneDeletedFiles() async {
    final List<String> deletedPaths = [];

    for (final img in _images) {
      if (!File(img.path).existsSync()) {
        deletedPaths.add(img.path);
      }
    }
    for (final v in _videos) {
      if (!File(v.path).existsSync()) {
        deletedPaths.add(v.path);
      }
    }
    for (final a in _audios) {
      if (!File(a.path).existsSync()) {
        deletedPaths.add(a.path);
      }
    }
    for (final d in _documents) {
      if (!File(d.path).existsSync()) {
        deletedPaths.add(d.path);
      }
    }

    if (deletedPaths.isNotEmpty) {
      debugPrint('🧹 [DeletionSync] Pruning ${deletedPaths.length} deleted files from device cache');
      await DatabaseService.instance.deleteRecordsBatch(deletedPaths);
      for (final p in deletedPaths) {
        LiveStorageWatcherService.instance.removeKnownPath(p);
      }

      if (mounted) {
        final deletedSet = deletedPaths.toSet();
        setState(() {
          _images.removeWhere((i) => deletedSet.contains(i.path) || deletedSet.contains(i.id));
          _searchResults.removeWhere((i) => deletedSet.contains(i.path) || deletedSet.contains(i.id));
          _videos.removeWhere((v) => deletedSet.contains(v.path) || deletedSet.contains(v.id));
          _filteredVideos.removeWhere((v) => deletedSet.contains(v.path) || deletedSet.contains(v.id));
          _audios.removeWhere((a) => deletedSet.contains(a.path) || deletedSet.contains(a.id));
          _filteredAudios.removeWhere((a) => deletedSet.contains(a.path) || deletedSet.contains(a.id));
          _documents.removeWhere((d) => deletedSet.contains(d.path) || deletedSet.contains(d.id));
          _filteredDocuments.removeWhere((d) => deletedSet.contains(d.path) || deletedSet.contains(d.id));
          _universalSearchResults.removeWhere(
            (item) => item.path != null && deletedSet.contains(item.path),
          );
          _filteredTimelineItems.removeWhere(
            (item) => item.path != null && deletedSet.contains(item.path),
          );
          _timelineItems.removeWhere(
            (item) => item.path != null && deletedSet.contains(item.path),
          );
          _updateTimeline();
        });
      }
    }
  }

  void _onTabScroll(int tabIndex, ScrollNotification scrollInfo) {
    if (scrollInfo.metrics.pixels >=
        scrollInfo.metrics.maxScrollExtent - 350) {
      switch (tabIndex) {
        case 0:
          if (_timelineDisplayLimit < _filteredTimelineItems.length) {
            setState(() {
              _timelineDisplayLimit = math.min(
                _timelineDisplayLimit + 24,
                _filteredTimelineItems.length,
              );
            });
          }
          break;
        case 1:
          if (_displayLimit < _searchResults.length) {
            setState(() {
              _displayLimit = math.min(
                _displayLimit + 24,
                _searchResults.length,
              );
            });
          }
          break;
        case 2:
          if (_videoDisplayLimit < _filteredVideos.length) {
            setState(() {
              _videoDisplayLimit = math.min(
                _videoDisplayLimit + 24,
                _filteredVideos.length,
              );
            });
          }
          break;
        case 3:
          if (_audioDisplayLimit < _filteredAudios.length) {
            setState(() {
              _audioDisplayLimit = math.min(
                _audioDisplayLimit + 24,
                _filteredAudios.length,
              );
            });
          }
          break;
        case 4:
          if (_docDisplayLimit < _filteredDocuments.length) {
            setState(() {
              _docDisplayLimit = math.min(
                _docDisplayLimit + 24,
                _filteredDocuments.length,
              );
            });
          }
          break;
        case 5:
          if (_appDisplayLimit < _filteredApps.length) {
            setState(() {
              _appDisplayLimit = math.min(
                _appDisplayLimit + 40,
                _filteredApps.length,
              );
            });
          }
          break;
        case 6:
          if (_contactDisplayLimit < _filteredContacts.length) {
            setState(() {
              _contactDisplayLimit = math.min(
                _contactDisplayLimit + 24,
                _filteredContacts.length,
              );
            });
          }
          break;
        case 7:
          if (_smsDisplayLimit < _filteredSms.length) {
            setState(() {
              _smsDisplayLimit = math.min(
                _smsDisplayLimit + 24,
                _filteredSms.length,
              );
            });
          }
          break;
      }
    }
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 400) {
      if (_displayLimit < _searchResults.length) {
        setState(() {
          _displayLimit = math.min(_displayLimit + 24, _searchResults.length);
        });
      }
    }
  }

  Future<void> _initApp() async {
    await _loadGridColumnsSetting();
    await _loadSortModeSetting();
    // ─────────────────────────────────────────────────────────────────────────
    // STEP 1: INSTANT PHOTO CACHE FIRST (< 30ms)
    // ─────────────────────────────────────────────────────────────────────────
    // Load cached photos from SQLite first so the user instantly sees photos!
    await _loadInstantPhotoCache();

    // Check permissions quietly in background
    await _requestPermissions();
    await _checkPermissionStatus();

    // ─────────────────────────────────────────────────────────────────────────
    // STEP 2: FINISH IMAGE CONTENTS DISCOVERY (Image contents load first)
    // ─────────────────────────────────────────────────────────────────────────
    // Let the first UI frame render, then finish scanning storage for new images
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    await _loadAllDeviceImages();

    // ─────────────────────────────────────────────────────────────────────────
    // STEP 3: SEQUENTIALLY LOAD OTHER MEDIA (Stack: finish one, then next)
    // ─────────────────────────────────────────────────────────────────────────
    // 3a. Videos & Audios
    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    await _loadVideoAndAudioCache();
    _loadAllDeviceVideos();
    _loadAllDeviceAudios();

    // 3b. Documents
    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;
    await _loadDocumentCache();
    _loadAllDeviceDocuments();

    // 3c. Apps, Contacts, SMS
    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;
    await _loadAppsContactsSmsCache();
    _loadDeviceApps();
    _loadDeviceContacts();
    _loadDeviceSms();

    // ─────────────────────────────────────────────────────────────────────────
    // STEP 4: DELAYED AI MODEL LOADING (Only after image contents & UI are ready)
    // ─────────────────────────────────────────────────────────────────────────
    // Only load the heavy model in memory after all images and UI are idle
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    try {
      await AiService.instance.initialize();
      if (!AiService.instance.isModelLoaded) {
        await ModelStorageService.instance.autoLoadModelToRam();
      }
      if (mounted) {
        setState(() {
          _isModelReady = AiService.instance.isModelLoaded;
          _vectorDimension = AiService.instance.vectorDimension;
          _activeBackendName = AiService.instance.activeBackend;
          if (_isModelReady && AiService.instance.currentModelName != null) {
            _selectedFileName = AiService.instance.currentModelName;
            _selectedFilePath = AiService.instance.currentModelPath;
          }
        });
      }
    } catch (e) {
      debugPrint('AiService delayed load info: $e');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STEP 5: AUTO-START BACKGROUND EMBEDDING (If model ready & photos present)
    // ─────────────────────────────────────────────────────────────────────────
    if (AiService.instance.isModelLoaded && _images.isNotEmpty) {
      if (mounted &&
          !BackgroundWorkerService.instance.isImageEmbeddingActive) {
        final hasPending = _images.any((img) => img.embedding == null);
        if (hasPending) {
          _embedAllImages();
        }
      }
    }
  }

  Future<void> _loadInstantPhotoCache() async {
    try {
      final cachedImages =
          await DatabaseService.instance.getAllRecordsLightweight();
      if (!mounted) return;
      if (cachedImages.isNotEmpty && _images.isEmpty) {
        final List<DeviceImage> loaded = [];
        final List<String> missingPaths = [];
        for (final c in cachedImages.values) {
          if (!File(c.path).existsSync()) {
            missingPaths.add(c.path);
            continue;
          }
          if (!ImageCollectorService.isExcludedFile(c.path, c.name)) {
            loaded.add(
              DeviceImage(
                id: c.path,
                path: c.path,
                name: c.name,
                fileSize: c.fileSize,
                modifiedDate: DateTime.fromMillisecondsSinceEpoch(
                  c.modifiedTimestamp,
                ),
                location: c.location,
                shaKey: c.shaKey,
                isProcessed: c.isProcessed,
                embedding: c.embedding,
                extractedText: c.extractedText,
              ),
            );
          }
        }
        if (missingPaths.isNotEmpty) {
          DatabaseService.instance.deleteRecordsBatch(missingPaths);
          for (final p in missingPaths) {
            LiveStorageWatcherService.instance.removeKnownPath(p);
          }
        }
        _sortImagesList(loaded);
        setState(() {
          _images = loaded;
          _searchResults = List.from(loaded);
        });
        _updateTimeline();
        _checkAndFinishInitialLoading();
        if (AiService.instance.isModelLoaded &&
            !BackgroundWorkerService.instance.isImageEmbeddingActive) {
          final hasPending = _images.any((img) => img.embedding == null);
          if (hasPending) {
            _embedAllImages();
          }
        }
      }
    } catch (e) {
      debugPrint('Error loading instant photo cache: $e');
    }
  }

  Future<void> _loadVideoAndAudioCache() async {
    try {
      final vidRecords = await DatabaseService.instance.getAllVideoRecords();
      final audRecords = await DatabaseService.instance.getAllAudioRecords();
      if (!mounted) return;
      final List<String> missingPaths = [];
      setState(() {
        if (vidRecords.isNotEmpty && _videos.isEmpty) {
          final List<DeviceVideo> loadedVids = [];
          for (final v in vidRecords.values) {
            if (!File(v.path).existsSync()) {
              missingPaths.add(v.path);
              continue;
            }
            loadedVids.add(
              DeviceVideo(
                id: v.path,
                path: v.path,
                name: v.name,
                fileSize: v.fileSize,
                modifiedDate: DateTime.fromMillisecondsSinceEpoch(
                  v.modifiedTimestamp,
                ),
                location: v.location,
                isProcessed: v.isProcessed,
                embedding: v.embedding,
              ),
            );
          }
          _sortVideosList(loadedVids);
          _videos = loadedVids;
          _filteredVideos = List.from(_videos);
        }
        if (audRecords.isNotEmpty && _audios.isEmpty) {
          final List<DeviceAudio> loadedAuds = [];
          for (final a in audRecords.values) {
            if (!File(a.path).existsSync()) {
              missingPaths.add(a.path);
              continue;
            }
            loadedAuds.add(
              DeviceAudio(
                id: a.path,
                path: a.path,
                name: a.name,
                fileSize: a.fileSize,
                modifiedDate: DateTime.fromMillisecondsSinceEpoch(
                  a.modifiedTimestamp,
                ),
                location: a.location,
                isProcessed: a.isProcessed,
                embedding: a.embedding,
              ),
            );
          }
          _sortAudiosList(loadedAuds);
          _audios = loadedAuds;
          _filteredAudios = List.from(_audios);
        }
        _updateTimeline();
      });
      if (missingPaths.isNotEmpty) {
        await DatabaseService.instance.deleteRecordsBatch(missingPaths);
        for (final p in missingPaths) {
          LiveStorageWatcherService.instance.removeKnownPath(p);
        }
      }
    } catch (e) {
      debugPrint('Error loading video/audio cache: $e');
    }
  }

  Future<void> _loadDocumentCache() async {
    try {
      final docRecords =
          await DatabaseService.instance.getAllDocumentRecords();
      if (!mounted) return;
      if (docRecords.isNotEmpty && _documents.isEmpty) {
        final List<DeviceDocument> loadedDocs = [];
        final List<String> missingPaths = [];
        for (final d in docRecords.values) {
          if (!File(d.path).existsSync()) {
            missingPaths.add(d.path);
            continue;
          }
          loadedDocs.add(
            DeviceDocument(
              id: d.path,
              path: d.path,
              name: d.name,
              extension: d.extension,
              category: DocumentCategory.values.firstWhere(
                (c) => c.name == d.category,
                orElse: () => DocumentCategory.other,
              ),
              fileSize: d.fileSize,
              modifiedDate: DateTime.fromMillisecondsSinceEpoch(
                d.modifiedTimestamp,
              ),
              location: d.location ?? '',
              extractedText: d.extractedText,
              isOcrProcessed: d.isOcrProcessed,
              embedding: d.embedding,
              isProcessed: d.isProcessed,
            ),
          );
        }
        if (missingPaths.isNotEmpty) {
          await DatabaseService.instance.deleteRecordsBatch(missingPaths);
          for (final p in missingPaths) {
            LiveStorageWatcherService.instance.removeKnownPath(p);
          }
        }
        _sortDocumentsList(loadedDocs);
        setState(() {
          _documents = loadedDocs;
          _filteredDocuments = List.from(_documents);
          _updateTimeline();
        });
        _triggerPendingTextExtraction();
      }
    } catch (e) {
      debugPrint('Error loading document cache: $e');
    }
  }

  Future<void> _loadAppsContactsSmsCache() async {
    try {
      final appRecords = await DatabaseService.instance.getAllAppRecords();
      final contactRecords =
          await DatabaseService.instance.getAllContactRecords();
      final smsRecords = await DatabaseService.instance.getAllSmsRecords();
      if (!mounted) return;
      setState(() {
        if (appRecords.isNotEmpty && _apps.isEmpty) {
          _apps = appRecords
              .map(
                (a) => DeviceApp(
                  name: a.name,
                  packageName: a.packageName,
                  version: a.version,
                  isSystemApp: a.isSystemApp,
                  category: _inferAppCategory(a.packageName, a.isSystemApp),
                ),
              )
              .where((a) => _isUserFacingApp(a))
              .toList();
          _sortAppsList(_apps);
          _filteredApps = List.from(_apps);
        }
        if (contactRecords.isNotEmpty && _contacts.isEmpty) {
          _contacts = contactRecords
              .map(
                (c) => DeviceContact(
                  id: c.id,
                  name: c.name,
                  number: c.number,
                ),
              )
              .toList();
          _sortContactsList(_contacts);
          _filteredContacts = List.from(_contacts);
        }
        if (smsRecords.isNotEmpty && _smsList.isEmpty) {
          _smsList = smsRecords
              .map(
                (s) => DeviceSms(
                  id: s.id,
                  address: s.address,
                  body: s.body,
                  date: DateTime.fromMillisecondsSinceEpoch(s.dateTimestamp),
                  type: s.type,
                  isProcessed: s.isProcessed,
                ),
              )
              .toList();
          _sortSmsList(_smsList);
          _filteredSms = List.from(_smsList);
        }
        _updateTimeline();
      });
    } catch (e) {
      debugPrint('Error loading apps/contacts/sms cache: $e');
    }
  }

  @override
  void dispose() {
    _initialLoadTimer?.cancel();
    _maxInitialLoadTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _searchFocusNode.dispose();
    _liveStatusTimer?.cancel();
    try {
      _tabController.removeListener(_onTabControllerTick);
      _tabController.dispose();
    } catch (_) {}
    if (!widget.isSplashPreview) {
      WidgetsBinding.instance.removeObserver(this);
      BackgroundWorkerService.instance.removeListener(_onBackgroundWorkerUpdate);
      AiService.instance.removeListener(_onAiServiceUpdate);
      ModelStorageService.instance.removeListener(_onModelServiceUpdate);
      ModelDownloaderService.instance.removeListener(_onModelServiceUpdate);
      LiveStorageWatcherService.instance.stopWatching();
      _scrollController.removeListener(_onScroll);
      BackgroundWorkerService.instance.stopWorker();
    }
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      debugPrint(
        '📱 [HomeScreen] App in background. Background worker active: ${BackgroundWorkerService.instance.isBackgroundWorkerActive}',
      );
    } else if (state == AppLifecycleState.resumed) {
      debugPrint(
        '📱 [HomeScreen] App resumed. Checking permissions, pruning deleted files, and syncing database...',
      );
      _pruneDeletedFiles();
      _syncFromDatabaseOnResume();
      ModelStorageService.instance.scanAvailableModels();
      if (!AiService.instance.isModelLoaded) {
        ModelStorageService.instance.autoLoadModelToRam();
      }
      _checkPermissionStatus().then((_) {
        // Only trigger full data reload if permissions were previously missing and now granted in Settings!
        if (_wasMissingPermissions && !_hasDeniedPermissions) {
          _wasMissingPermissions = false;
          _reloadPermittedData();
        }
      });
    }
  }

  /// Sync processed state on resume using a lightweight path→status query (no BLOBs).
  Future<void> _syncFromDatabaseOnResume() async {
    final pathStatus = await DatabaseService.instance.getAllKnownPathsAndStatus();
    bool hasUpdates = false;
    for (final img in _images) {
      final processed = pathStatus[img.path];
      if (processed == true && !img.isProcessed) {
        img.isProcessed = true;
        hasUpdates = true;
      }
    }
    if (hasUpdates && mounted) {
      setState(() {});
    }
  }

  void _onBackgroundWorkerUpdate() {
    if (mounted) {
      setState(() {
        _isModelReady = AiService.instance.isModelLoaded;
        _isIndexing = BackgroundWorkerService.instance.isBackgroundWorkerActive;
        _lastBatchLatencyMs =
            BackgroundWorkerService.instance.lastBatchLatencyMs;
      });
    }
  }

  void _onModelServiceUpdate() {
    if (!mounted) return;
    setState(() {
      _isModelReady = AiService.instance.isModelLoaded;
      if (_isModelReady && AiService.instance.currentModelName != null) {
        _selectedFileName = AiService.instance.currentModelName;
        _selectedFilePath = AiService.instance.currentModelPath;
        _activeBackendName = AiService.instance.activeBackend;
        _vectorDimension = AiService.instance.vectorDimension;
      }
    });
  }

  void _onAiServiceUpdate() {
    if (!mounted) return;
    setState(() {
      _isModelReady = AiService.instance.isModelLoaded;
      _vectorDimension = AiService.instance.vectorDimension;
      _activeBackendName = AiService.instance.activeBackend;
      if (_isModelReady && AiService.instance.currentModelName != null) {
        _selectedFileName = AiService.instance.currentModelName;
        _selectedFilePath = AiService.instance.currentModelPath;
      }
    });

    // Auto-start background embedding worker immediately once model finishes loading
    if (AiService.instance.isModelLoaded &&
        !BackgroundWorkerService.instance.isImageEmbeddingActive &&
        _images.isNotEmpty) {
      final hasPending = _images.any((img) => img.embedding == null);
      if (hasPending) {
        debugPrint('🚀 [HomeScreen] AI model loaded. Auto-starting background embedding worker...');
        _embedAllImages();
      }
      _triggerPendingTextExtraction();
    }
  }

  Future<bool> _requestPermissions() async {
    try {
      await [
        Permission.storage,
        Permission.photos,
        Permission.videos,
        Permission.audio,
        Permission.manageExternalStorage,
        Permission.contacts,
        Permission.sms,
      ].request();
    } catch (_) {}
    return true;
  }

  Future<void> _checkPermissionStatus() async {
    final List<String> missing = [];
    bool permanentlyDenied = false;

    // 1. Storage & Media
    final hasStorage =
        await Permission.manageExternalStorage.isGranted ||
        await Permission.storage.isGranted ||
        (await Permission.photos.isGranted &&
            await Permission.videos.isGranted);

    if (!hasStorage) {
      missing.add('Storage & Media');
      if (await Permission.manageExternalStorage.isPermanentlyDenied ||
          await Permission.storage.isPermanentlyDenied ||
          (await Permission.photos.isPermanentlyDenied &&
              await Permission.videos.isPermanentlyDenied)) {
        permanentlyDenied = true;
      }
    }

    // 2. Contacts
    if (!await Permission.contacts.isGranted) {
      missing.add('Contacts');
      if (await Permission.contacts.isPermanentlyDenied) {
        permanentlyDenied = true;
      }
    }

    // 3. SMS
    if (!await Permission.sms.isGranted) {
      missing.add('SMS');
      if (await Permission.sms.isPermanentlyDenied) {
        permanentlyDenied = true;
      }
    }

    if (mounted) {
      setState(() {
        _missingPermissions = missing;
        _hasDeniedPermissions = missing.isNotEmpty;
        if (_hasDeniedPermissions) {
          _wasMissingPermissions = true;
        }
        _isPermanentlyDenied = permanentlyDenied;
        if (missing.isEmpty) {
          _bannerDismissed = false;
        }
      });
    }
  }

  Future<void> _requestMissingPermissions() async {
    if (_isPermanentlyDenied) {
      await openAppSettings();
      return;
    }

    final toRequest = <Permission>[];
    if (_missingPermissions.contains('Storage & Media')) {
      toRequest.addAll([
        Permission.storage,
        Permission.photos,
        Permission.videos,
        Permission.audio,
        Permission.manageExternalStorage,
      ]);
    }
    if (_missingPermissions.contains('Contacts')) {
      toRequest.add(Permission.contacts);
    }
    if (_missingPermissions.contains('SMS')) {
      toRequest.add(Permission.sms);
    }

    if (toRequest.isNotEmpty) {
      try {
        await toRequest.request();
      } catch (e) {
        debugPrint('Error requesting permissions: $e');
      }
    }

    await _checkPermissionStatus();
    _reloadPermittedData();
  }

  void _reloadPermittedData() {
    _loadAllDeviceImages();
    _loadAllDeviceVideos(forceRescan: true);
    _loadAllDeviceAudios(forceRescan: true);
    _loadAllDeviceDocuments(forceRescan: true);
    _loadDeviceApps();
    _loadDeviceContacts(forceRescan: true);
    _loadDeviceSms(forceRescan: true);
    _updateTimeline();
  }

  /// Incremental Pipeline:
  /// 1. Load existing photos from app SQLite DB (zero disk re-reading of old images)
  /// 2. Scan storage for ONLY NEW photos (skipping known paths)
  /// 3. Compute Crypto SHA-256 for new photos & avoid duplicates
  /// 4. Save new records to DB with is_processed = 0
  /// 5. Embed only unprocessed photos (is_processed = 0) and mark is_processed = 1
  Future<void> _loadAllDeviceImages() async {
    setState(() {
      _isLoadingImages = true;
      _imageStatus = 'Checking database...';
      _duplicatesCount = 0;
      _displayLimit = 24;
    });

    final stopwatch = Stopwatch()..start();

    try {
      // Purge any previously stored WhatsApp media, stickers, or statuses from database
      await DatabaseService.instance.removeExcludedMedia();

      // --- STEP 1: LOAD CACHED PHOTOS DIRECTLY FROM DATABASE (no BLOBs) ---
      final cachedDbRecords = await DatabaseService.instance.getAllRecordsLightweight();
      final List<DeviceImage> loadedList = [];
      final List<String> missingPaths = [];
      for (final cached in cachedDbRecords.values) {
        if (!File(cached.path).existsSync()) {
          missingPaths.add(cached.path);
          continue;
        }
        if (!ImageCollectorService.isExcludedFile(cached.path, cached.name)) {
          loadedList.add(
            DeviceImage(
              id: cached.path,
              path: cached.path,
              name: cached.name,
              fileSize: cached.fileSize,
              modifiedDate: DateTime.fromMillisecondsSinceEpoch(
                cached.modifiedTimestamp,
              ),
              location: cached.location,
              shaKey: cached.shaKey,
              isProcessed: cached.isProcessed,
              embedding: cached.embedding,
              extractedText: cached.extractedText,
            ),
          );
        }
      }

      if (missingPaths.isNotEmpty) {
        await DatabaseService.instance.deleteRecordsBatch(missingPaths);
        for (final p in missingPaths) {
          cachedDbRecords.remove(p);
          LiveStorageWatcherService.instance.removeKnownPath(p);
        }
      }

      // If scanning is disabled for photos in Settings, use cached photos and skip disk scanning
      final scanPhotosEnabled = PreferencesService.instance.isCategoryScanningEnabled('photos');
      if (!scanPhotosEnabled) {
        if (loadedList.isNotEmpty && mounted) {
          _sortImagesList(loadedList);
          setState(() {
            _images = List.from(loadedList);
            _searchResults = List.from(loadedList);
            _isLoadingImages = false;
            _imageStatus = '${_images.length} photos (Scanning paused in Settings)';
            _updateTimeline();
          });
        } else if (mounted) {
          setState(() {
            _isLoadingImages = false;
            _imageStatus = 'Photo scanning paused in Settings';
          });
        }
        _checkAndFinishInitialLoading();
        return;
      }

      // If database has photos, show them immediately; otherwise inform that storage scan is active
      if (loadedList.isNotEmpty && mounted) {
        _sortImagesList(loadedList);
        setState(() {
          _images = List.from(loadedList);
          _searchResults = List.from(loadedList);
          _imageStatus =
              'Loaded ${_images.length} cached photos. Checking for new photos...';
        });
      } else if (mounted) {
        setState(() {
          _imageStatus =
              'Database empty. Scanning device storage for photos...';
        });
      }

      // --- STEP 2: SCAN STORAGE FOR ONLY NEW PHOTOS (Skip known paths) ---
      final knownPaths = cachedDbRecords.keys.toSet();
      final knownShaKeys = cachedDbRecords.values
          .where((r) => r.shaKey != null && r.shaKey!.isNotEmpty)
          .map((r) => r.shaKey!)
          .toSet();

      final newRawImages = await ImageCollectorService.instance
          .collectNewImagesOnly(
            existingPaths: knownPaths,
            onProgress: (count, elapsedMs) {
              if (mounted) {
                setState(() {
                  final secs = (elapsedMs / 1000).toStringAsFixed(1);
                  _imageStatus =
                      '⚡ Discovered $count photos from storage (${secs}s)';
                });
              }
            },
          );

      if (!mounted) return;

      // --- STEP 3: DEDUPLICATE NEW PHOTOS VIA CRYPTO SHA-256 ---
      final dedupResult = DuplicateRemoverService.instance.removeDuplicates(
        newRawImages,
        existingShaKeys: knownShaKeys,
      );

      if (dedupResult.uniqueItems.isNotEmpty) {
        final List<CachedImageRecord> newDbRecords = dedupResult.uniqueItems
            .map((raw) {
              return CachedImageRecord(
                path: raw.path,
                name: raw.name,
                fileSize: raw.fileSize,
                modifiedTimestamp: raw.modifiedDate.millisecondsSinceEpoch,
                location: raw.location,
                shaKey: raw.shaKey,
                isProcessed: false,
                embedding: null,
              );
            })
            .toList();

        // Persist newly discovered photos to database
        await DatabaseService.instance.saveBatch(newDbRecords);

        final newDeviceImages = dedupResult.uniqueItems.map((raw) {
          return DeviceImage(
            id: raw.path,
            path: raw.path,
            name: raw.name,
            fileSize: raw.fileSize,
            modifiedDate: raw.modifiedDate,
            location: raw.location,
            shaKey: raw.shaKey,
            isProcessed: false,
            embedding: null,
          );
        }).toList();

        loadedList.addAll(newDeviceImages);
      }

      // Run unified duplicate cleaner on all loaded images
      final cleanImages = DuplicateRemoverService.instance
          .deduplicateFiles<DeviceImage>(
            items: loadedList,
            path: (img) => img.path,
            name: (img) => img.name,
            fileSize: (img) => img.fileSize,
            shaKey: (img) => img.shaKey,
          );
      _sortImagesList(cleanImages);
      stopwatch.stop();

      setState(() {
        _images = cleanImages;
        _searchResults = cleanImages;
        _isLoadingImages = false;
        _duplicatesCount +=
            (loadedList.length - cleanImages.length) +
            dedupResult.duplicatesCount;
        _displayLimit = 24;
        _imageStatus = '${_images.length} photos';
        _updateTimeline();
      });
      _checkAndFinishInitialLoading();

      // --- STEP 4: EMBED UNPROCESSED PHOTOS ONLY ---
      if (AiService.instance.isModelLoaded &&
          _images.isNotEmpty &&
          !BackgroundWorkerService.instance.isImageEmbeddingActive) {
        final hasPending = _images.any((img) => img.embedding == null);
        if (hasPending) {
          _embedAllImages();
        }
      }
    } catch (e) {
      debugPrint('Error loading device images: $e');
      if (mounted) {
        setState(() {
          _isLoadingImages = false;
          _imageStatus = 'Loaded ${_images.length} photos';
        });
        _checkAndFinishInitialLoading();
      }
    } finally {
      if (mounted && _isLoadingImages) {
        setState(() {
          _isLoadingImages = false;
        });
        _checkAndFinishInitialLoading();
      }
    }
  }

  Future<void> _pickImagesManually() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) return;

      final selectedFiles = result.files.where((f) => f.path != null).toList();
      if (selectedFiles.isEmpty) return;

      final Set<String> seenNameSize = _images
          .map((img) => '${img.name.toLowerCase()}_${img.fileSize}')
          .toSet();

      int addedCount = 0;
      for (final file in selectedFiles) {
        final path = file.path!;
        final name = file.name;
        final fileSize = file.size;
        final modifiedDate = File(path).existsSync()
            ? File(path).statSync().modified
            : DateTime.now();

        final nameSizeKey = '${name.toLowerCase()}_$fileSize';
        if (!seenNameSize.contains(nameSizeKey)) {
          seenNameSize.add(nameSizeKey);
          _images.add(
            DeviceImage(
              id: path,
              path: path,
              name: name,
              fileSize: fileSize,
              modifiedDate: modifiedDate,
            ),
          );
          addedCount++;
        }
      }

      // Sort using universal sort mode
      _sortImagesList(_images);

      setState(() {
        _searchResults = List.from(_images);
        _displayLimit = 24;
        _imageStatus =
            'Loaded ${_images.length} unique photos (added $addedCount)';
        _updateTimeline();
      });

      if (AiService.instance.isModelLoaded) {
        _embedAllImages();
      }
    } catch (e) {
      debugPrint('Error picking images: $e');
    }
  }

  Future<void> _embedAllImages() async {
    if (!AiService.instance.isModelLoaded || _images.isEmpty) return;
    if (BackgroundWorkerService.instance.isImageEmbeddingActive) return;

    final pending = _images.where((i) => i.embedding == null).toList();
    if (pending.isEmpty) {
      debugPrint('[HomeScreen] All ${_images.length} photos already embedded.');
      return;
    }

    setState(() {
      _isIndexing = true;
    });

    AiService.instance.setParallelThreads(_parallelWorkers);

    // Launch background worker for unprocessed photos with auto-stop upon completion
    await BackgroundWorkerService.instance.startWorker<DeviceImage>(
      _images,
      onBatchProgress: () {
        if (mounted) {
          setState(() {
            _isIndexing =
                BackgroundWorkerService.instance.isBackgroundWorkerActive;
            _lastBatchLatencyMs =
                BackgroundWorkerService.instance.lastBatchLatencyMs;
          });
        }
      },
      onFinished: () {
        if (mounted) {
          final remaining = _images.where((i) => i.embedding == null).length;
          if (remaining > 0 && AiService.instance.isModelLoaded) {
            _embedAllImages();
            return;
          }
          setState(() {
            _isIndexing = false;
          });
          // Secondary priority: Run text/document OCR only after all image embeddings are complete
          _triggerPendingTextExtraction();
        }
      },
    );
  }

  void _triggerPendingTextExtraction() {
    if (!mounted) return;
    if (BackgroundWorkerService.instance.isDocumentExtractionActive) return;

    final pending = _documents
        .where(
          (d) =>
              !d.isProcessed &&
              (!d.isOcrProcessed || (d.embedding == null && AiService.instance.isModelLoaded)) &&
              (d.category == DocumentCategory.pdf ||
                  d.category == DocumentCategory.text),
        )
        .toList();
    if (pending.isNotEmpty) {
      _setLiveProcessing(
        'Document AI: Processing ${pending.length} documents...',
      );
      BackgroundWorkerService.instance.runExtractionOnDocuments(
        pending,
        onDocExtracted: (doc, text) {
          if (mounted) {
            setState(() {});
            _setLiveProcessing(
              'Document AI: Extracted & Embedded ${doc.name}',
              autoDismiss: const Duration(seconds: 2),
            );
            _updateTimeline();
          }
        },
      );
    }
  }

  void _togglePauseResume() {
    final worker = BackgroundWorkerService.instance;
    if (worker.isBackgroundWorkerActive) {
      if (worker.isPaused) {
        worker.resumeWorker();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('▶️ Resumed background worker'),
            duration: Duration(milliseconds: 1200),
          ),
        );
      } else {
        worker.pauseWorker();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⏸️ Paused background worker'),
            duration: Duration(milliseconds: 1200),
          ),
        );
      }
      setState(() {
        _isIndexing = worker.isBackgroundWorkerActive;
      });
    } else {
      final pendingCount = _images
          .where((img) => !img.isProcessed && img.embedding == null)
          .length;
      if (pendingCount == 0 && _images.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '✅ All photos already processed! Background worker auto-stopped.',
            ),
            duration: Duration(milliseconds: 2000),
          ),
        );
      } else if (AiService.instance.isModelLoaded && _images.isNotEmpty) {
        _embedAllImages();
      }
    }
  }

  List<DeviceImage> _filterAndRankPhotos(
    List<DeviceImage> rankedPhotos,
    String query,
  ) {
    final lowerQuery = query.toLowerCase();
    final isQueryLongEnough = lowerQuery.length >= 2;
    final List<DeviceImage> matchedList = [];

    // Find highest visual AI score
    double maxAiScore = 0.0;
    for (final img in rankedPhotos) {
      if ((img.score ?? 0.0) > maxAiScore) {
        maxAiScore = img.score!;
      }
    }

    // Dynamic cutoff:
    // If maxAiScore >= 0.70 (meaning at least one photo matched rawSim >= 0.18):
    // Require at least 0.70 absolute AND within 0.14 of top match
    // to strictly filter out background non-matches (e.g. headlights/political images for "bird")!
    final visualCutoff = maxAiScore >= 0.70
        ? math.max(0.70, maxAiScore - 0.14)
        : 0.70;

    debugPrint('🔎 [_filterAndRankPhotos] query="$query" | total=${rankedPhotos.length} | maxScore=${maxAiScore.toStringAsFixed(3)} | cutoff=${visualCutoff.toStringAsFixed(3)}');

    for (final img in rankedPhotos) {
      final aiScore = img.score ?? 0.0;
      final hasVisualAiMatch = maxAiScore >= 0.70 && aiScore >= visualCutoff;

      final nameMatch = lowerQuery.isNotEmpty &&
          img.name.toLowerCase().contains(lowerQuery);
      final ocrMatch = isQueryLongEnough &&
          img.extractedText != null &&
          img.extractedText!.toLowerCase().contains(lowerQuery);

      if (hasVisualAiMatch) {
        double currentScore = aiScore;
        if (ocrMatch) {
          currentScore = math.min(0.99, currentScore + 0.06);
        } else if (nameMatch) {
          currentScore = math.min(0.98, currentScore + 0.04);
        }
        img.score = currentScore;
        matchedList.add(img);
      } else if (ocrMatch) {
        img.score = nameMatch ? 0.90 : 0.84;
        matchedList.add(img);
      } else if (nameMatch) {
        img.score = 0.82;
        matchedList.add(img);
      } else {
        img.score = 0.0;
      }
    }

    _sortImagesList(matchedList);
    debugPrint('🔎 [_filterAndRankPhotos] Matched ${matchedList.length} photos (${rankedPhotos.length - matchedList.length} non-matches filtered out)');
    return matchedList;
  }

  Future<void> _performSearch([String? overrideQuery]) async {
    final query = (overrideQuery ?? _searchController.text).trim();
    if (query.isEmpty) {
      setState(() {
        _searchResults = List.from(_images);
        for (var img in _searchResults) {
          img.score = null;
        }
        _sortImagesList(_searchResults);
        _lastSearchLatencyMs = null;
        _displayLimit = 24;
      });
      return;
    }

    if (!AiService.instance.isModelLoaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please select your embedding model file (.litertlm) first.',
          ),
        ),
      );
      return;
    }

    final currentRequestId = ++_searchRequestId;
    setState(() {
      _isSearching = true;
    });

    try {
      AiService.instance.setParallelThreads(_parallelWorkers);

      final ranked = await AiService.instance.search<DeviceImage>(
        query,
        _images,
        onProgress: () {
          if (mounted && currentRequestId == _searchRequestId) setState(() {});
        },
      );

      final matchedList = _filterAndRankPhotos(ranked, query);

      if (mounted) {
        if (currentRequestId != _searchRequestId) return;
        setState(() {
          _searchResults = matchedList;
          _isSearching = false;
          _hasSubmittedSearch = query.isNotEmpty;
          if (query.isNotEmpty) _searchEpoch++;
          _displayLimit = 24;
          _lastSearchLatencyMs = AiService.instance.lastSearchLatencyMs;
        });
        debugPrint('📸 [Photos Search] Query: "$query" -> ${matchedList.length} photos matched in ${_lastSearchLatencyMs ?? 0}ms');
      }
    } catch (e) {
      if (mounted) {
        if (currentRequestId != _searchRequestId) return;
        setState(() {
          _isSearching = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Search error: $e')));
      }
    }
  }

  String _extractSnippet(String text, String query) {
    final lower = text.toLowerCase();
    final idx = lower.indexOf(query.toLowerCase());
    if (idx == -1) {
      return text.length > 60 ? '${text.substring(0, 60)}...' : text;
    }
    final start = math.max(0, idx - 20);
    final end = math.min(text.length, idx + query.length + 30);
    final prefix = start > 0 ? '...' : '';
    final suffix = end < text.length ? '...' : '';
    return '$prefix${text.substring(start, end).replaceAll('\n', ' ')}$suffix';
  }

  Future<void> _performUniversalSearch([String? overrideQuery]) async {
    final query = (overrideQuery ?? _searchController.text).trim();
    if (query.isEmpty) {
      setState(() {
        _hasSubmittedSearch = false;
        _searchEpoch = 0;
        _searchResults = List.from(_images);
        for (var img in _searchResults) {
          img.score = null;
        }
        _sortImagesList(_searchResults);
        _filteredVideos = List.from(_videos);
        for (var vid in _filteredVideos) {
          vid.score = null;
        }
        _sortVideosList(_filteredVideos);
        _filteredAudios = List.from(_audios);
        for (var aud in _filteredAudios) {
          aud.score = null;
        }
        _sortAudiosList(_filteredAudios);
        _filteredDocuments = List.from(_documents);
        for (var doc in _filteredDocuments) {
          doc.score = null;
        }
        _sortDocumentsList(_filteredDocuments);
        _universalSearchResults = [];
        _lastSearchLatencyMs = null;
        _displayLimit = 24;
        _timelineDisplayLimit = 24;
        _videoDisplayLimit = 24;
        _audioDisplayLimit = 24;
        _docDisplayLimit = 24;
        _appDisplayLimit = 60;
        _contactDisplayLimit = 24;
        _smsDisplayLimit = 24;
      });
      _applyDocumentFilters();
      _applyAppFilters();
      _applyContactFilters();
      _applySmsFilters();
      _updateTimeline();
      return;
    }

    if (!AiService.instance.isModelLoaded) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'AI Model is not loaded. Please select your .litertlm model file in Settings.',
              ),
              duration: Duration(seconds: 3),
              backgroundColor: Color(0xFFE65100),
            ),
          );
        }
      }

      final currentRequestId = ++_searchRequestId;
      setState(() {
        _isSearching = true;
      });

      final stopwatch = Stopwatch()..start();
      final lowerQuery = query.toLowerCase();

      try {
        final prefs = PreferencesService.instance;
        final scanPhotos = prefs.isCategoryScanningEnabled('photos');
        final scanVideos = prefs.isCategoryScanningEnabled('videos');
        final scanAudio = prefs.isCategoryScanningEnabled('audio');
        final scanDocuments = prefs.isCategoryScanningEnabled('documents');
        final scanApps = prefs.isCategoryScanningEnabled('apps');
        final scanContacts = prefs.isCategoryScanningEnabled('contacts');
        final scanSms = prefs.isCategoryScanningEnabled('sms');

        // 1. Photos Search (Embedding AI search if loaded, plus OCR text boost & filename match)
        List<DeviceImage> relevantPhotos = [];
        if (scanPhotos) {
          List<DeviceImage> matchedPhotos = [];
          if (AiService.instance.isModelLoaded) {
            AiService.instance.setParallelThreads(_parallelWorkers);
            try {
              final ranked = await AiService.instance.search<DeviceImage>(
                query,
                _images,
                onProgress: () {
                  if (mounted) setState(() {});
                },
              );
              matchedPhotos = ranked;
            } catch (e) {
              debugPrint('AI photo search error: $e');
              matchedPhotos = List.from(_images);
            }
          } else {
            matchedPhotos = List.from(_images);
          }
          relevantPhotos = _filterAndRankPhotos(matchedPhotos, query);
        }

        // 2. Videos Search (Genuine AI embedding match or title keyword match)
        final List<DeviceVideo> realMatchedVideos = [];
        if (scanVideos) {
          List<DeviceVideo> matchedVideos = [];
          if (AiService.instance.isModelLoaded) {
            try {
              matchedVideos = await AiService.instance.search<DeviceVideo>(
                query,
                _videos,
              );
            } catch (e) {
              debugPrint('AI video search error: $e');
              matchedVideos = List.from(_videos);
            }
          } else {
            matchedVideos = List.from(_videos);
          }
          for (final vid in matchedVideos) {
            final nameMatch = lowerQuery.isNotEmpty && vid.name.toLowerCase().contains(lowerQuery);
            final hasAiScore = (vid.score ?? 0.0) >= 0.72;
            if (nameMatch) {
              vid.score = 0.90;
              realMatchedVideos.add(vid);
            } else if (hasAiScore) {
              realMatchedVideos.add(vid);
            } else {
              vid.score = 0.0;
            }
          }
          realMatchedVideos.sort(
            (a, b) => (b.score ?? 0.0).compareTo(a.score ?? 0.0),
          );
        }

        // 3. Audio Search (Genuine AI embedding match or title keyword match)
        final List<DeviceAudio> realMatchedAudios = [];
        if (scanAudio) {
          List<DeviceAudio> matchedAudios = [];
          if (AiService.instance.isModelLoaded) {
            try {
              matchedAudios = await AiService.instance.search<DeviceAudio>(
                query,
                _audios,
              );
            } catch (e) {
              debugPrint('AI audio search error: $e');
              matchedAudios = List.from(_audios);
            }
          } else {
            matchedAudios = List.from(_audios);
          }
          for (final aud in matchedAudios) {
            final nameMatch = lowerQuery.isNotEmpty && aud.name.toLowerCase().contains(lowerQuery);
            final hasAiScore = (aud.score ?? 0.0) >= 0.72;
            if (nameMatch) {
              aud.score = 0.88;
              realMatchedAudios.add(aud);
            } else if (hasAiScore) {
              realMatchedAudios.add(aud);
            } else {
              aud.score = 0.0;
            }
          }
          realMatchedAudios.sort(
            (a, b) => (b.score ?? 0.0).compareTo(a.score ?? 0.0),
          );
        }

        // 4. Documents Search (AI Model Embeddings + Digital/OCR Extracted Text + Filename)
        final List<DeviceDocument> realMatchedDocs = [];
        if (scanDocuments) {
          // Step 4a: On-demand text extraction & AI embedding generation for unindexed documents
          if (lowerQuery.isNotEmpty) {
            for (final doc in _documents) {
              if (doc.extractedText == null &&
                  !doc.isOcrProcessed &&
                  (doc.category == DocumentCategory.pdf || doc.category == DocumentCategory.text)) {
                try {
                  if (doc.category == DocumentCategory.pdf) {
                    final txt = await TextExtractionService.instance.extractTextFromPdf(doc.path, maxPagesForOcr: 5);
                    doc.isOcrProcessed = true;
                    if (txt.isNotEmpty) {
                      doc.extractedText = txt;
                      if (AiService.instance.isModelLoaded) {
                        await AiService.instance.embedDocument(doc);
                      }
                      DatabaseService.instance.updateDocumentOcrAndEmbedding(
                        doc.path,
                        txt,
                        embedding: doc.embedding,
                      );
                    } else {
                      DatabaseService.instance.updateDocumentOcrText(doc.path, '');
                    }
                  } else if (doc.category == DocumentCategory.text) {
                    final f = File(doc.path);
                    doc.isOcrProcessed = true;
                    if (f.existsSync()) {
                      final txt = await f.readAsString();
                      doc.extractedText = txt;
                      if (AiService.instance.isModelLoaded) {
                        await AiService.instance.embedDocument(doc);
                      }
                      DatabaseService.instance.updateDocumentOcrAndEmbedding(
                        doc.path,
                        txt,
                        embedding: doc.embedding,
                      );
                    }
                  }
                } catch (_) {
                  doc.isOcrProcessed = true;
                }
              }
            }
          }

          // Step 4b: AI Model Semantic Search over all documents using vector embeddings
          List<DeviceDocument> aiRankedDocs = [];
          if (AiService.instance.isModelLoaded && _documents.isNotEmpty && lowerQuery.isNotEmpty) {
            try {
              aiRankedDocs = await AiService.instance.search<DeviceDocument>(
                query,
                _documents,
              );
            } catch (e) {
              debugPrint('AI document search error: $e');
              aiRankedDocs = List.from(_documents);
            }
          } else {
            aiRankedDocs = List.from(_documents);
          }

          // Step 4c: Combine vector similarity scores with direct text and filename matching
          if (lowerQuery.isNotEmpty) {
            for (final doc in aiRankedDocs) {
              final nameMatch = doc.name.toLowerCase().contains(lowerQuery);
              final ocrMatch = doc.extractedText != null &&
                  doc.extractedText!.toLowerCase().contains(lowerQuery);
              final hasAiSemanticMatch = (doc.score ?? 0.0) >= 0.72;

              if (ocrMatch) {
                doc.score = math.max(doc.score ?? 0.0, 0.94);
                realMatchedDocs.add(doc);
              } else if (nameMatch) {
                doc.score = math.max(doc.score ?? 0.0, 0.90);
                realMatchedDocs.add(doc);
              } else if (hasAiSemanticMatch) {
                realMatchedDocs.add(doc);
              } else {
                doc.score = 0.0;
              }
            }
            realMatchedDocs.sort((a, b) => (b.score ?? 0.0).compareTo(a.score ?? 0.0));
          }
        }

        // 5. Apps Search (App name, Package name, Subsequence, Typo & Anagram match)
        final List<DeviceApp> realMatchedApps = [];
        if (scanApps && lowerQuery.isNotEmpty) {
          for (final a in _apps) {
            if (_isUserFacingApp(a) && _isAppMatch(a, lowerQuery)) {
              final score = _scoreAppMatch(a, lowerQuery);
              if (score >= 0.55) {
                realMatchedApps.add(a);
              }
            }
          }
          realMatchedApps.sort((a, b) => _scoreAppMatch(b, lowerQuery)
              .compareTo(_scoreAppMatch(a, lowerQuery)));
        }

        // 6. Contacts Search (Contact name, Phone number - deduplicated)
        final seenContactKeys = <String>{};
        final List<DeviceContact> realMatchedContacts = [];
        if (scanContacts && lowerQuery.isNotEmpty) {
          final cleanQuery = lowerQuery.replaceAll(RegExp(r'\s+'), '');
          for (final c in _contacts) {
            final nameMatch = c.name.toLowerCase().contains(lowerQuery);
            final cleanNum = c.number.replaceAll(RegExp(r'\s+'), '');
            final numMatch = cleanNum.isNotEmpty && cleanNum.contains(cleanQuery);
            if (nameMatch || numMatch) {
              final norm = _normalizePhoneNumber(c.number, fallback: c.name);
              final key = '${c.name.trim().toLowerCase()}_$norm';
              if (seenContactKeys.add(key)) {
                realMatchedContacts.add(c);
              }
            }
          }
        }

        // 7. SMS Messages Search (Sender address, Body text - deduplicated by sender)
        final seenSmsKeys = <String>{};
        final List<DeviceSms> realMatchedSms = [];
        if (scanSms && lowerQuery.isNotEmpty) {
          for (final sms in _smsList) {
            final bodyMatch = sms.body.toLowerCase().contains(lowerQuery);
            final addrMatch = sms.address.toLowerCase().contains(lowerQuery);
            if (bodyMatch || addrMatch) {
              final key = _normalizePhoneNumber(
                sms.address,
                fallback: sms.address,
              );
              if (seenSmsKeys.add(key)) {
                realMatchedSms.add(sms);
              }
            }
          }
        }

        // Sort and Update Individual Tab Filtered Lists
        _sortImagesList(relevantPhotos);
        _sortVideosList(realMatchedVideos);
        _sortAudiosList(realMatchedAudios);
        _sortDocumentsList(realMatchedDocs);
        _sortAppsList(realMatchedApps);
        _sortContactsList(realMatchedContacts);
        _sortSmsList(realMatchedSms);

        _searchResults = relevantPhotos;
        _filteredVideos = realMatchedVideos;
        _filteredAudios = realMatchedAudios;
        _filteredDocuments = realMatchedDocs;
        _filteredApps = realMatchedApps;
        _filteredContacts = realMatchedContacts;
        _filteredSms = realMatchedSms;

        // 9. Build Aggregated Universal Timeline Items
        final List<TimelineItem> universalItems = [];

        // 1. Photos (Top matches with visual priority)
        if (scanPhotos) {
          final topMatchedPhotos = relevantPhotos.take(50);
          for (final img in topMatchedPhotos) {
            final isOcr =
                img.extractedText != null &&
                img.extractedText!.toLowerCase().contains(lowerQuery);
            String subtitle = _formatDate(img.modifiedDate).split(' ').first;
            if (isOcr) {
              subtitle =
                  'OCR Match: "${_extractSnippet(img.extractedText!, lowerQuery)}"';
            }
            universalItems.add(
              TimelineItem(
                type: TimelineItemType.photo,
                id: img.path,
                title: img.name,
                subtitle: subtitle,
                timestamp: img.modifiedDate,
                path: img.path,
                fileSize: img.fileSize,
                originalObject: img,
                score: img.score ?? 0.70,
              ),
            );
          }
        }

        // 2. Videos (Top matches)
        if (scanVideos) {
          final topMatchedVideos = realMatchedVideos.take(30);
          for (final vid in topMatchedVideos) {
            universalItems.add(
              TimelineItem(
                type: TimelineItemType.video,
                id: vid.path,
                title: vid.name,
                subtitle: _formatDate(vid.modifiedDate).split(' ').first,
                timestamp: vid.modifiedDate,
                path: vid.path,
                fileSize: vid.fileSize,
                originalObject: vid,
                score: vid.score ?? 0.72,
              ),
            );
          }
        }

        // 3. Audios (Top matches)
        if (scanAudio) {
          final topMatchedAudios = realMatchedAudios.take(30);
          for (final aud in topMatchedAudios) {
            universalItems.add(
              TimelineItem(
                type: TimelineItemType.audio,
                id: aud.path,
                title: aud.name,
                subtitle: _formatDate(aud.modifiedDate).split(' ').first,
                timestamp: aud.modifiedDate,
                path: aud.path,
                fileSize: aud.fileSize,
                originalObject: aud,
                score: aud.score ?? 0.72,
              ),
            );
          }
        }

        // 4. Documents (Top matches)
        if (scanDocuments) {
          for (final doc in realMatchedDocs.take(40)) {
            final isOcr =
                doc.extractedText != null &&
                doc.extractedText!.toLowerCase().contains(lowerQuery);
            final isAi = (doc.score ?? 0.0) >= 0.72 && !isOcr;
            String subtitle = doc.categoryLabel;
            if (isOcr) {
              subtitle =
                  'Text Match: "${_extractSnippet(doc.extractedText!, lowerQuery)}"';
            } else if (isAi && doc.extractedText != null && doc.extractedText!.trim().isNotEmpty) {
              subtitle =
                  'AI Match (${((doc.score ?? 0.72) * 100).toInt()}%): "${_extractSnippet(doc.extractedText!, '')}"';
            } else if (isAi) {
              subtitle =
                  'AI Semantic Match (${((doc.score ?? 0.72) * 100).toInt()}%)';
            }
            universalItems.add(
              TimelineItem(
                type: TimelineItemType.document,
                id: doc.path,
                title: doc.name,
                subtitle: subtitle,
                timestamp: doc.modifiedDate,
                path: doc.path,
                fileSize: doc.fileSize,
                originalObject: doc,
                score: doc.score ?? (isOcr ? 0.94 : 0.88),
              ),
            );
          }
        }

        // 5. Apps (Direct app matches boosted to surface on top of search results)
        if (scanApps) {
          for (final app in realMatchedApps.take(6)) {
            final baseScore = _scoreAppMatch(app, lowerQuery);
            final boostedScore = baseScore >= 0.85 ? baseScore + 0.25 : baseScore;
            universalItems.add(
              TimelineItem(
                type: TimelineItemType.app,
                id: 'app_${app.packageName}',
                title: app.name,
                subtitle: '${app.category} • Installed',
                timestamp: DateTime.fromMillisecondsSinceEpoch(0),
                originalObject: app,
                score: boostedScore,
              ),
            );
          }
        }

        // 6. Contacts (Top matches - deduplicated)
        if (scanContacts) {
          for (final contact in realMatchedContacts.take(15)) {
            final norm = _normalizePhoneNumber(
              contact.number,
              fallback: contact.name,
            );
            universalItems.add(
              TimelineItem(
                type: TimelineItemType.contact,
                id: 'contact_${contact.id}_$norm',
                title: contact.name,
                subtitle: contact.number,
                timestamp: DateTime.fromMillisecondsSinceEpoch(0),
                originalObject: contact,
                score: 0.74,
              ),
            );
          }
        }

        // 7. SMS (Top matches - latest per sender)
        if (scanSms) {
          for (final sms in realMatchedSms.take(15)) {
            final isBody = sms.body.toLowerCase().contains(lowerQuery);
            String subtitle = sms.body;
            if (isBody) {
              subtitle = 'Message: "${_extractSnippet(sms.body, lowerQuery)}"';
            }
            final key = _normalizePhoneNumber(sms.address, fallback: sms.address);
            universalItems.add(
              TimelineItem(
                type: TimelineItemType.sms,
                id: 'sms_${sms.date.millisecondsSinceEpoch}_$key',
                title: sms.address,
                subtitle: subtitle,
                timestamp: sms.date,
                originalObject: sms,
                score: isBody ? 0.76 : 0.70,
              ),
            );
          }
        }

        // Final deduplication pass to ensure absolute uniqueness across results
        final seenUniversalSignatures = <String>{};
        final List<TimelineItem> deduplicatedUniversal = [];
        for (final item in universalItems) {
          final String sig;
          if (item.type == TimelineItemType.contact ||
              item.type == TimelineItemType.sms) {
            final norm = _normalizePhoneNumber(
              item.subtitle,
              fallback: item.title,
            );
            sig = '${item.type.name}_$norm';
          } else if (item.path != null && item.path!.isNotEmpty) {
            sig = '${item.type.name}_${item.path}';
          } else {
            sig = '${item.type.name}_${item.id}';
          }
          if (seenUniversalSignatures.add(sig)) {
            deduplicatedUniversal.add(item);
          }
        }

        // Sort Universal Results: Top app matches rank on top, followed by highest score and recency.
        deduplicatedUniversal.sort((a, b) {
          final sA = a.score ?? 0.0;
          final sB = b.score ?? 0.0;
          final scoreCompare = sB.compareTo(sA);
          if (scoreCompare != 0) return scoreCompare;

          // If scores are equal, prioritize matched apps on top
          final aIsApp = a.type == TimelineItemType.app;
          final bIsApp = b.type == TimelineItemType.app;
          if (aIsApp && !bIsApp) return -1;
          if (!aIsApp && bIsApp) return 1;

          switch (_sortMode) {
            case 'date_asc':
              return a.timestamp.compareTo(b.timestamp);
            case 'name_asc':
              return a.title.toLowerCase().compareTo(b.title.toLowerCase());
            case 'name_desc':
              return b.title.toLowerCase().compareTo(a.title.toLowerCase());
            case 'size_desc':
              final sizeDiff = (b.fileSize ?? 0).compareTo(a.fileSize ?? 0);
              return sizeDiff != 0 ? sizeDiff : b.timestamp.compareTo(a.timestamp);
            case 'size_asc':
              final sizeDiff = (a.fileSize ?? 0).compareTo(b.fileSize ?? 0);
              return sizeDiff != 0 ? sizeDiff : b.timestamp.compareTo(a.timestamp);
            case 'date_desc':
            default:
              return b.timestamp.compareTo(a.timestamp);
          }
        });

        stopwatch.stop();
        debugPrint('🌐 [Universal Search] Query: "$query" completed in ${stopwatch.elapsedMilliseconds}ms: ${relevantPhotos.length} photos, ${realMatchedVideos.length} videos, ${realMatchedAudios.length} audios, ${realMatchedDocs.length} docs, ${realMatchedApps.length} apps, ${realMatchedContacts.length} contacts, ${realMatchedSms.length} sms');

        if (mounted) {
          if (currentRequestId != _searchRequestId) return;
          setState(() {
            _isSearching = false;
            _hasSubmittedSearch = query.isNotEmpty;
            if (query.isNotEmpty) _searchEpoch++;
            _lastSearchLatencyMs = stopwatch.elapsedMilliseconds;
            _universalSearchResults = deduplicatedUniversal;
            _timelineDisplayLimit = 36;
            _applyTimelineFilters();
          });
        }
      } catch (e) {
        debugPrint('Universal search error: $e');
        if (mounted) {
          if (currentRequestId != _searchRequestId) return;
          setState(() => _isSearching = false);
          _applyTimelineFilters();
        }
      }
  }

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    int i = (math.log(bytes) / math.log(1024)).floor();
    if (i < 0) i = 0;
    if (i >= suffixes.length) i = suffixes.length - 1;
    return '${(bytes / math.pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _openFullScreenViewer(DeviceImage img) {
    if (!File(img.path).existsSync()) {
      _handleLiveFileDeleted(img.path);
      return;
    }
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (ctx, anim, secondaryAnim) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            elevation: 0,
            title: Text(
              img.name,
              style: const TextStyle(fontSize: 14, color: Colors.white),
            ),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 8.0,
              clipBehavior: Clip.none,
              child: Image.file(
                File(img.path),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Icon(
                    Icons.broken_image,
                    color: Colors.white54,
                    size: 48,
                  ),
                ),
              ),
            ),
          ),
        ),
        transitionsBuilder: (ctx, anim, secondaryAnim, child) {
          final curve = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
          return ScaleTransition(
            scale: Tween<double>(begin: 0.88, end: 1.0).animate(curve),
            child: FadeTransition(opacity: anim, child: child),
          );
        },
      ),
    );
  }

  void _showImageDetails(DeviceImage img, int? rank) {
    if (!File(img.path).existsSync()) {
      _handleLiveFileDeleted(img.path);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Photo was deleted from device storage and removed.'),
          duration: Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 320),
      transitionBuilder: (context, anim, secondaryAnim, child) {
        final curve = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return ScaleTransition(
          scale: Tween<double>(begin: 0.8, end: 1.0).animate(curve),
          child: FadeTransition(opacity: anim, child: child),
        );
      },
      pageBuilder: (ctx, anim, secondaryAnim) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(23)),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  Container(
                    color: Colors.black,
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.45,
                      minHeight: 200,
                    ),
                    width: double.infinity,
                    child: Center(
                      child: InteractiveViewer(
                        minScale: 1.0,
                        maxScale: 5.0,
                        child: Image.file(
                          File(img.path),
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.fullscreen, size: 20),
                      tooltip: 'View Fullscreen (100% Quality)',
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openFullScreenViewer(img);
                      },
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      img.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.calendar_today,
                          size: 13,
                          color: Colors.grey.shade600,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatDate(img.modifiedDate),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          Icons.sd_storage_outlined,
                          size: 14,
                          color: Colors.grey.shade600,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatFileSize(img.fileSize),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (img.score != null)
                      const SizedBox.shrink(),
                    const SizedBox(height: 8),
                    Text(
                      img.path,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (img.location != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.folder_outlined,
                            size: 13,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              img.location!,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (img.shaKey != null && img.shaKey!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.fingerprint,
                            size: 13,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'SHA: ${img.shaKey!}',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade600,
                                fontFamily: 'monospace',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          (img.isProcessed || img.embedding != null)
                              ? Icons.check_circle
                              : Icons.schedule,
                          size: 13,
                          color: (img.isProcessed || img.embedding != null)
                              ? Colors.green.shade700
                              : Colors.orange.shade800,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          (img.isProcessed || img.embedding != null)
                              ? 'Processed & Indexed (SQLite)'
                              : 'Pending Embedding',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: (img.isProcessed || img.embedding != null)
                                ? Colors.green.shade800
                                : Colors.orange.shade800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.fullscreen, size: 18),
                      label: const Text('Full Quality View'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openFullScreenViewer(img);
                      },
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getScoreColor(double score) {
    if (score >= 0.70) return Colors.green.shade700;
    if (score >= 0.50) return Colors.teal.shade700;
    if (score >= 0.35) return Colors.orange.shade800;
    return Colors.grey.shade600;
  }

  /// Safely adjusts TabController length and sequence, deferring disposal of
  /// the old controller to post-frame so TabBar/TabBarView can detach cleanly.
  void _updateTabControllerIfNeeded(List<_CategoryTabDef> activeTabs) {
    final signature = activeTabs.map((t) => t.key).join(',');
    if (_tabController.length != activeTabs.length ||
        _lastActiveTabKeysSignature != signature) {
      final oldIndex = _tabController.index;
      String? currentTabKey;
      if (_lastActiveTabKeysSignature.isNotEmpty) {
        final oldKeys = _lastActiveTabKeysSignature.split(',');
        if (oldIndex < oldKeys.length) {
          currentTabKey = oldKeys[oldIndex];
        }
      }
      int newIndex = currentTabKey != null
          ? activeTabs.indexWhere((t) => t.key == currentTabKey)
          : oldIndex;
      if (newIndex < 0) newIndex = 0;

      final oldController = _tabController;
      try {
        oldController.removeListener(_onTabControllerTick);
      } catch (_) {}

      _tabController = TabController(
        length: activeTabs.length,
        vsync: this,
        initialIndex: newIndex.clamp(0, activeTabs.length - 1),
      );
      _tabController.addListener(_onTabControllerTick);
      _lastActiveTabKeysSignature = signature;

      // Safely dispose old controller AFTER the frame finishes so that TabBar,
      // TabBarView, and AnimatedBuilder can cleanly detach their listeners
      // in didUpdateWidget without triggering 'used after being disposed'.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          oldController.dispose();
        } catch (_) {}
      });
    }
  }

  void _syncSettings() {
    _loadGridColumnsSetting();
    _loadSortModeSetting();

    final prefs = PreferencesService.instance;

    // If any category is disabled, purge database records and clear in-memory lists
    if (!prefs.isCategoryScanningEnabled('sms')) {
      if (_smsList.isNotEmpty || _filteredSms.isNotEmpty) {
        _smsList.clear();
        _filteredSms.clear();
      }
      DatabaseService.instance.purgeCategoryData('sms');
    }
    if (!prefs.isCategoryScanningEnabled('photos')) {
      if (_images.isNotEmpty || _searchResults.isNotEmpty) {
        _images.clear();
        _searchResults.clear();
      }
      DatabaseService.instance.purgeCategoryData('photos');
    }
    if (!prefs.isCategoryScanningEnabled('videos')) {
      if (_videos.isNotEmpty || _filteredVideos.isNotEmpty) {
        _videos.clear();
        _filteredVideos.clear();
      }
      DatabaseService.instance.purgeCategoryData('videos');
    }
    if (!prefs.isCategoryScanningEnabled('audio')) {
      if (_audios.isNotEmpty || _filteredAudios.isNotEmpty) {
        _audios.clear();
        _filteredAudios.clear();
      }
      DatabaseService.instance.purgeCategoryData('audio');
    }
    if (!prefs.isCategoryScanningEnabled('documents')) {
      if (_documents.isNotEmpty || _filteredDocuments.isNotEmpty) {
        _documents.clear();
        _filteredDocuments.clear();
      }
      DatabaseService.instance.purgeCategoryData('documents');
    }
    if (!prefs.isCategoryScanningEnabled('apps')) {
      if (_apps.isNotEmpty || _filteredApps.isNotEmpty) {
        _apps.clear();
        _filteredApps.clear();
      }
      DatabaseService.instance.purgeCategoryData('apps');
    }
    if (!prefs.isCategoryScanningEnabled('contacts')) {
      if (_contacts.isNotEmpty || _filteredContacts.isNotEmpty) {
        _contacts.clear();
        _filteredContacts.clear();
      }
      DatabaseService.instance.purgeCategoryData('contacts');
    }

    // Refresh timeline so disabled category items are removed from 'All'
    _updateTimeline();

    // Dynamically adjust TabController length and sequence safely
    final activeTabs = _getActiveTabDefs();
    _updateTabControllerIfNeeded(activeTabs);

    setState(() {
      _parallelWorkers = AiService.instance.parallelThreads;
      _isModelReady = AiService.instance.isModelLoaded;
      _activeBackendName = AiService.instance.activeBackend;
      _vectorDimension = AiService.instance.vectorDimension;
      if (AiService.instance.currentModelName != null) {
        _selectedFileName = AiService.instance.currentModelName;
        _selectedFilePath = AiService.instance.currentModelPath;
        _statusMessage =
            'Model Ready: $_selectedFileName ($_vectorDimension-d, $_activeBackendName accelerated)';
      }
    });
    if (AiService.instance.isModelLoaded &&
        !BackgroundWorkerService.instance.isImageEmbeddingActive &&
        _images.isNotEmpty) {
      final hasPending = _images.any((img) => img.embedding == null);
      if (hasPending) {
        _embedAllImages();
      }
    }

    // If scanning was enabled for any empty category, trigger scan
    if (prefs.isCategoryScanningEnabled('photos') && _images.isEmpty) {
      _loadAllDeviceImages();
    }
    if (prefs.isCategoryScanningEnabled('videos') && _videos.isEmpty) {
      _loadAllDeviceVideos();
    }
    if (prefs.isCategoryScanningEnabled('audio') && _audios.isEmpty) {
      _loadAllDeviceAudios();
    }
    if (prefs.isCategoryScanningEnabled('documents') && _documents.isEmpty) {
      _loadAllDeviceDocuments();
    }
    if (prefs.isCategoryScanningEnabled('apps') && _apps.isEmpty) {
      _loadDeviceApps();
    }
    if (prefs.isCategoryScanningEnabled('contacts') && _contacts.isEmpty) {
      _loadDeviceContacts();
    }
    if (prefs.isCategoryScanningEnabled('sms') && _smsList.isEmpty) {
      _loadDeviceSms();
    }
  }

  void _handleRescanCommand(String command) {
    switch (command) {
      case 'rescan_all':
        _reloadPermittedData();
        break;
      case 'rescan_photos':
        _loadAllDeviceImages();
        break;
      case 'rescan_videos':
        _loadAllDeviceVideos(forceRescan: true);
        break;
      case 'rescan_audios':
        _loadAllDeviceAudios(forceRescan: true);
        break;
      case 'rescan_docs':
        _loadAllDeviceDocuments(forceRescan: true);
        break;
      case 'rescan_apps':
        _loadDeviceApps();
        break;
      case 'rescan_contacts':
        _loadDeviceContacts(forceRescan: true);
        break;
      case 'rescan_sms':
        _loadDeviceSms(forceRescan: true);
        break;
    }
  }

  String _getSearchHint() {
    final activeTabs = _getActiveTabDefs();
    if (_tabController.index >= activeTabs.length) return 'Search...';
    final key = activeTabs[_tabController.index].key;
    switch (key) {
      case 'all':
        return 'Search all items by title, name, or content...';
      case 'photos':
        return _isModelReady
            ? 'Search photos by concept (e.g. "dog", "car", "sunset")...'
            : 'Load embedding model to search photos...';
      case 'videos':
        return _isModelReady
            ? 'Search videos by title or concept (e.g. "beach", "trip")...'
            : 'Search videos by title or location...';
      case 'audio':
        return _isModelReady
            ? 'Search audios by title or concept (e.g. "song", "recording")...'
            : 'Search audios by title or location...';
      case 'documents':
        return 'Search documents (e.g. "invoice", "resume", "pdf")...';
      case 'apps':
        return 'Search apps by name or package...';
      case 'contacts':
        return 'Search contacts by name or phone...';
      case 'sms':
        return 'Search SMS messages by sender or body...';
      default:
        return 'Search...';
    }
  }

  void _onSearchAction() {
    _searchDebounceTimer?.cancel();
    _searchFocusNode.unfocus();
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    final query = _searchController.text.trim();
    if (query.isNotEmpty) {
      setState(() {
        _hasSubmittedSearch = true;
        _searchEpoch++;
      });
      // Switch to the 'All' tab (index 0) so all category responses (image, video, docs, contacts, apps, sms)
      // gathered together by the model are immediately visible!
      if (_tabController.index != 0) {
        _tabController.animateTo(0);
      }
      _performUniversalSearch(query);
    } else {
      setState(() {
        _hasSubmittedSearch = false;
        _searchEpoch = 0;
      });
      _performUniversalSearch('');
    }
  }

  void _cancelSearch() {
    _searchRequestId++;
    _searchDebounceTimer?.cancel();
    _searchController.clear();
    _searchFocusNode.unfocus();
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    setState(() {
      _isSearching = false;
      _hasSubmittedSearch = false;
      _searchEpoch = 0;
      _lastSearchLatencyMs = null;
      _searchResults = List.from(_images);
      for (var img in _searchResults) {
        img.score = null;
      }
      _sortImagesList(_searchResults);
      _displayLimit = 24;
    });
    _applyVideoFilters();
    _applyAudioFilters();
    _performUniversalSearch('');
  }

  void _applyActiveTabFilters() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      _performUniversalSearch('');
      return;
    }
    _performUniversalSearch(query);
  }

  Widget _buildAdaptiveStatsRow(
    int indexedCount,
    bool isWorkerRunning,
    bool isPaused,
  ) {
    final activeTabs = _getActiveTabDefs(
      indexedCount: indexedCount,
      isWorkerRunning: isWorkerRunning,
      isPaused: isPaused,
    );
    if (_tabController.index >= activeTabs.length) return const SizedBox.shrink();
    final tabKey = activeTabs[_tabController.index].key;
    switch (tabKey) {
      case 'all':
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _hasSubmittedSearch && _searchController.text.isNotEmpty
                  ? 'Found: ${_filteredTimelineItems.length} items${_lastSearchLatencyMs != null ? " (${(_lastSearchLatencyMs! / 1000).toStringAsFixed(2)}s)" : ""}'
                  : 'All Items: ${_filteredTimelineItems.length}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _hasSubmittedSearch && _searchController.text.isNotEmpty
                      ? Icons.auto_awesome
                      : Icons.schedule,
                  size: 13,
                  color: _hasSubmittedSearch && _searchController.text.isNotEmpty
                      ? const Color(0xFF15786C)
                      : Colors.grey.shade600,
                ),
                const SizedBox(width: 4),
                Text(
                  _hasSubmittedSearch && _searchController.text.isNotEmpty
                      ? 'Cross-Category Search'
                      : _getSortModeLabel(),
                  style: TextStyle(
                    fontSize: 11,
                    color: _hasSubmittedSearch && _searchController.text.isNotEmpty
                        ? const Color(0xFF15786C)
                        : Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        );
      case 'photos':
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _lastSearchLatencyMs != null && _hasSubmittedSearch && _searchController.text.isNotEmpty
                  ? 'Results: ${_searchResults.length} (${(_lastSearchLatencyMs! / 1000).toStringAsFixed(2)}s)'
                  : 'Total Photos: ${_images.length}${_duplicatesCount > 0 ? " • $_duplicatesCount filtered" : ""}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isWorkerRunning) ...[
                  if (isPaused) ...[
                    Icon(
                      Icons.pause_circle,
                      size: 14,
                      color: Colors.amber.shade800,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Worker Paused: $indexedCount/${_images.length}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.amber.shade900,
                      ),
                    ),
                  ] else ...[
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF15786C),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _lastBatchLatencyMs != null
                          ? 'Background Worker: $indexedCount/${_images.length} (${(_lastBatchLatencyMs! / 1000).toStringAsFixed(1)}s)'
                          : 'Background Worker: $indexedCount/${_images.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF15786C),
                      ),
                    ),
                  ],
                ] else ...[
                  if (indexedCount == _images.length && _images.isNotEmpty) ...[
                    Icon(
                      Icons.check_circle,
                      size: 14,
                      color: Colors.green.shade700,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Processed: $indexedCount • Auto-stopped',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.green.shade800,
                      ),
                    ),
                  ] else ...[
                    Text(
                      'Processed: $indexedCount/${_images.length} • Auto-stopped',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ],
        );
      case 'videos':
        final vidIndexed = _videos
            .where((v) => v.isProcessed || v.embedding != null)
            .length;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Videos: ${_filteredVideos.length}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _isLoadingVideos
                      ? 'Scanning storage for videos...'
                      : 'AI Text Embeddings: $vidIndexed/${_videos.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: vidIndexed == _videos.length && _videos.isNotEmpty
                        ? Colors.green.shade700
                        : Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (_isLoadingVideos) ...[
                  const SizedBox(width: 4),
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: Color(0xFF15786C),
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      case 'audio':
        final audIndexed = _audios
            .where((a) => a.isProcessed || a.embedding != null)
            .length;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Audio: ${_filteredAudios.length}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _isLoadingAudios
                      ? 'Scanning storage for audio...'
                      : 'AI Text Embeddings: $audIndexed/${_audios.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: audIndexed == _audios.length && _audios.isNotEmpty
                        ? Colors.green.shade700
                        : Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (_isLoadingAudios) ...[
                  const SizedBox(width: 4),
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: Color(0xFF15786C),
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      case 'documents':
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Documents: ${_filteredDocuments.length}${_selectedDocCategory != null ? " (${_selectedDocCategory!.name.toUpperCase()})" : ""}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _isLoadingDocuments
                      ? 'Scanning storage...'
                      : '${_documents.length} Total',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
                const SizedBox(width: 4),
                Icon(
                  _isLoadingDocuments ? Icons.sync : Icons.check_circle,
                  size: 13,
                  color: _isLoadingDocuments
                      ? const Color(0xFF15786C)
                      : Colors.green.shade700,
                ),
              ],
            ),
          ],
        );
      case 'apps':
        final installed = _apps.where((a) => _isUserFacingApp(a)).length;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Apps: ${_filteredApps.length} shown',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            Text(
              '$installed Installed',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        );
      case 'contacts':
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Contacts: ${_filteredContacts.length}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            Text(
              '${_contacts.length} Total',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        );
      case 'sms':
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'SMS Messages: ${_filteredSms.length}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            Text(
              '${_smsList.length} Total',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildModelStatusBanner() {
    final downloader = ModelDownloaderService.instance;
    final storage = ModelStorageService.instance;
    final isDownloading = downloader.isDownloading || downloader.isBusy;
    final isModelLoaded = AiService.instance.isModelLoaded;

    // If model is already loaded in RAM, banner is not needed
    if (isModelLoaded && !isDownloading) {
      return const SizedBox.shrink();
    }

    // CASE A: Download in progress
    if (isDownloading) {
      return Container(
        margin: const EdgeInsets.fromLTRB(14.0, 8.0, 14.0, 4.0),
        padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 11.0),
        decoration: BoxDecoration(
          color: const Color(0xFFF0FDF4),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF86EFAC), width: 1.4),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF15786C).withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: InkWell(
          onTap: () => context.push('/model-downloader'),
          borderRadius: BorderRadius.circular(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF15786C)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Downloading Model • ${(downloader.progress * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Color(0xFF166534),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    downloader.formattedSpeed,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF15786C),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: downloader.progress,
                  minHeight: 5,
                  backgroundColor: const Color(0xFFDCFCE7),
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF15786C)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // If model exists on disk, no banner is needed (model auto-loads in background)
    final hasModelOnDisk = storage.hasModelOnDevice && storage.availableModels.isNotEmpty;
    if (hasModelOnDisk) {
      return const SizedBox.shrink();
    }

    // CASE C: No model on device at all -> Show Hero Missing Model Setup Banner
    if (_modelBannerDismissed) {
      // Collapsed pill when dismissed so the user still has an indicator without blocking screen
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
        child: InkWell(
          onTap: () => context.push('/model-downloader'),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFCD34D)),
            ),
            child: const Row(
              children: [
                Icon(Icons.auto_awesome, size: 14, color: Color(0xFFB45309)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AI Search Model Offline • Tap to download 440M engine',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF92400E)),
                  ),
                ),
                Icon(Icons.arrow_forward_ios_rounded, size: 11, color: Color(0xFFB45309)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(14.0, 8.0, 14.0, 4.0),
      padding: const EdgeInsets.all(14.0),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFFCD34D), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFB45309).withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFD97706).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Color(0xFFB45309),
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'AI Vision Search Model Missing',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF92400E),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFFF59E0B)),
                          ),
                          child: const Text(
                            'Offline',
                            style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFFB45309)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Download the on-device LiteRT multimodal model (440 MB) for instant visual photo search, semantic query understanding, and OCR text extraction.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.brown.shade800,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF92400E)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  setState(() {
                    _modelBannerDismissed = true;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _modelBannerDismissed = true;
                  });
                },
                child: Text(
                  'Dismiss',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF15786C),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => context.push('/model-downloader'),
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text(
                  'Download Model (440 MB)',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionBanner() {
    if (!_hasDeniedPermissions || _bannerDismissed) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12.0, 10.0, 12.0, 4.0),
      padding: const EdgeInsets.all(14.0),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFCA28), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF57F17).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.security_outlined,
                  color: Color(0xFFE65100),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Permissions Required',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFE65100),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _isPermanentlyDenied
                          ? 'Some permissions were permanently denied. Please enable them in app settings so Pipit can access device storage, contacts, calls, and SMS.'
                          : 'Pipit needs permission to read and search items on your device. Please grant the missing permissions below.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.brown.shade800,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                tooltip: 'Dismiss Banner',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  setState(() {
                    _bannerDismissed = true;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _missingPermissions.map((perm) {
              IconData icon;
              if (perm.contains('Storage') || perm.contains('Media')) {
                icon = Icons.folder_open;
              } else if (perm.contains('Contacts')) {
                icon = Icons.contacts_outlined;
              } else if (perm.contains('SMS')) {
                icon = Icons.sms_outlined;
              } else {
                icon = Icons.lock_outline;
              }

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFFB300)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 13, color: const Color(0xFFE65100)),
                    const SizedBox(width: 4),
                    Text(
                      perm,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE65100),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () async {
                  setState(() => _isCheckingPermissions = true);
                  await _checkPermissionStatus();
                  setState(() => _isCheckingPermissions = false);
                },
                child: _isCheckingPermissions
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFFE65100),
                        ),
                      )
                    : const Text(
                        'Check Again',
                        style: TextStyle(
                          color: Color(0xFFE65100),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE65100),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                icon: Icon(
                  _isPermanentlyDenied
                      ? Icons.settings
                      : Icons.check_circle_outline,
                  size: 16,
                ),
                label: Text(
                  _isPermanentlyDenied ? 'Open Settings' : 'Allow Access',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: () async {
                  await context.push('/permissions');
                  await _checkPermissionStatus();
                  _reloadPermittedData();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showRearrangeTabsBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _HomeTabRearrangeSheet(
        onReorderCompleted: () {
          _syncSettings();
          if (mounted) {
            setState(() {});
          }
        },
      ),
    );
  }

  Tab _buildTab({
    required int tabIndex,
    required String label,
    required int count,
    String? assetPath,
    IconData? icon,
  }) {
    String formattedCount;
    if (count >= 1000) {
      final kVal = count / 1000.0;
      formattedCount = count % 1000 == 0
          ? '${kVal.toInt()}k'
          : '${kVal.toStringAsFixed(1)}k';
    } else {
      formattedCount = '$count';
    }

    return Tab(
      iconMargin: const EdgeInsets.only(bottom: 2.0),
      icon: Tooltip(
        message: 'Tap to view • Long press to rearrange tabs',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: () {
            HapticFeedback.mediumImpact();
            _showRearrangeTabsBottomSheet();
          },
          child: AnimatedBuilder(
            animation: _tabController,
            builder: (context, child) {
              final isSelected = _tabController.index == tabIndex;
              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: isSelected ? 1.0 : 0.72,
                    child: assetPath != null
                        ? Image.asset(
                            assetPath,
                            width: 40,
                            height: 40,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                            errorBuilder: (context, error, stackTrace) =>
                                Icon(icon ?? Icons.category, size: 34, color: const Color(0xFF15786C)),
                          )
                        : Icon(icon ?? Icons.category, size: 34, color: const Color(0xFF15786C)),
                  ),
                  Positioned(
                    top: -3,
                    right: -9,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4.5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF15786C),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 2,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 15,
                        minHeight: 13,
                      ),
                      child: Text(
                        formattedCount,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                          height: 1.1,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
      text: label,
    );
  }

  Widget? _buildAppBarProgressPill() {
    final status = _currentProcessingStatus;
    if (status == null) return null;

    final s = status.toLowerCase();
    if (s.contains('stopped') ||
        s.contains('finished') ||
        s.contains('idle') ||
        s.contains('auto-stopped') ||
        s.contains('no ai model')) {
      return null;
    }

    IconData typeIcon = Icons.photo_library_outlined;
    String? typeAsset;

    if (s.contains('image') ||
        s.contains('photo') ||
        s.contains('vision') ||
        s.contains('embedding')) {
      typeAsset = 'assets/iamges/images.png';
      typeIcon = Icons.photo_library_outlined;
    } else if (s.contains('video')) {
      typeAsset = 'assets/iamges/video.png';
      typeIcon = Icons.videocam_outlined;
    } else if (s.contains('audio') || s.contains('music')) {
      typeAsset = 'assets/iamges/music.png';
      typeIcon = Icons.audiotrack_outlined;
    } else if (s.contains('document') || s.contains('doc') || s.contains('pdf') || s.contains('ocr')) {
      typeAsset = 'assets/iamges/documents.png';
      typeIcon = Icons.description_outlined;
    } else if (s.contains('contact')) {
      typeAsset = 'assets/iamges/contacts.png';
      typeIcon = Icons.person_outline;
    } else if (s.contains('sms') || s.contains('message')) {
      typeAsset = 'assets/iamges/message.png';
      typeIcon = Icons.sms_outlined;
    } else if (s.contains('app')) {
      typeAsset = 'assets/iamges/apps.png';
      typeIcon = Icons.apps_outlined;
    } else {
      typeAsset = 'assets/iamges/all.png';
      typeIcon = Icons.auto_awesome_motion_outlined;
    }

    // Determine how many items are remaining
    int? remainingCount;
    if (BackgroundWorkerService.instance.isBackgroundWorkerActive &&
        BackgroundWorkerService.instance.pendingCount > 0) {
      remainingCount = BackgroundWorkerService.instance.pendingCount;
    } else if (BackgroundWorkerService.instance.isBackgroundWorkerActive &&
        BackgroundWorkerService.instance.totalCount >
            BackgroundWorkerService.instance.completedCount) {
      remainingCount = BackgroundWorkerService.instance.totalCount -
          BackgroundWorkerService.instance.completedCount;
    }

    if (remainingCount == null || remainingCount <= 0) {
      if (s.contains('document') || s.contains('doc') || s.contains('pdf') || s.contains('ocr')) {
        final pending = _documents
            .where(
              (d) =>
                  (!d.isOcrProcessed ||
                      (d.embedding == null && AiService.instance.isModelLoaded)) &&
                  (d.category == DocumentCategory.pdf ||
                      d.category == DocumentCategory.text),
            )
            .length;
        if (pending > 0) remainingCount = pending;
      } else if (s.contains('image') ||
          s.contains('photo') ||
          s.contains('vision') ||
          s.contains('embedding')) {
        final pending = _images.where((i) => i.embedding == null).length;
        if (pending > 0) remainingCount = pending;
      }
    }

    if (remainingCount == null || remainingCount <= 0) {
      final pendingMatch =
          RegExp(r'(\d+)\s*(?:pending|remaining)', caseSensitive: false)
              .firstMatch(status);
      if (pendingMatch != null) {
        remainingCount = int.tryParse(pendingMatch.group(1)!);
      } else {
        final fractionMatch = RegExp(r'(\d+)\s*/\s*(\d+)').firstMatch(status);
        if (fractionMatch != null) {
          final current = int.tryParse(fractionMatch.group(1)!);
          final total = int.tryParse(fractionMatch.group(2)!);
          if (current != null && total != null && total >= current) {
            remainingCount = total - current;
          }
        } else {
          final countMatch = RegExp(
            r'(?:extracting|processing|scanning|embedding)\s+(\d+)',
            caseSensitive: false,
          ).firstMatch(status);
          if (countMatch != null) {
            remainingCount = int.tryParse(countMatch.group(1)!);
          }
        }
      }
    }

    // If still 0 or null, check if any pending items exist across images and documents
    if (remainingCount == null || remainingCount <= 0) {
      final totalPending = _images.where((i) => i.embedding == null).length +
          _documents
              .where(
                (d) =>
                    (!d.isOcrProcessed ||
                        (d.embedding == null && AiService.instance.isModelLoaded)) &&
                    (d.category == DocumentCategory.pdf ||
                        d.category == DocumentCategory.text),
              )
              .length;
      if (totalPending > 0) {
        remainingCount = totalPending;
      }
    }

    final bool isActivelySearching = _isSearching || s.contains('searching');

    // If no search is running and there are 0 files left to process, do NOT show any empty pill!
    if (!isActivelySearching && (remainingCount == null || remainingCount <= 0)) {
      return null;
    }

    final formattedCount = remainingCount != null && remainingCount > 0
        ? (remainingCount > 999
            ? '${(remainingCount / 1000).toStringAsFixed(1)}k'
            : '$remainingCount')
        : '';

    return Tooltip(
      message: status,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9.0, vertical: 5.0),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.55),
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Image.asset(
                  typeAsset,
                  width: 18,
                  height: 18,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => Icon(
                    typeIcon,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
                if (remainingCount != null && remainingCount > 0)
                  Positioned(
                    top: -5,
                    right: -8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4.0,
                        vertical: 1.0,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF15786C),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.white,
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 2,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 15,
                        minHeight: 13,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        formattedCount,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                          height: 1.1,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 8),
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _inferAppCategory(String packageName, bool isSystemApp) {
    final lower = packageName.toLowerCase();
    if (lower.contains('camera') || lower.contains('gallery') || lower.contains('photos')) return 'Photography';
    if (lower.contains('video') || lower.contains('player') || lower.contains('youtube') || lower.contains('netflix')) return 'Video & Media';
    if (lower.contains('music') || lower.contains('audio') || lower.contains('sound') || lower.contains('spotify')) return 'Music & Audio';
    if (lower.contains('game') || lower.contains('play.games')) return 'Games';
    if (lower.contains('browser') || lower.contains('chrome') || lower.contains('firefox') || lower.contains('opera')) return 'Browser';
    if (lower.contains('mail') || lower.contains('gmail') || lower.contains('outlook')) return 'Email';
    if (lower.contains('chat') || lower.contains('message') || lower.contains('whatsapp') || lower.contains('telegram') || lower.contains('social') || lower.contains('facebook') || lower.contains('instagram') || lower.contains('twitter')) return 'Social';
    if (lower.contains('map') || lower.contains('navigation') || lower.contains('gps')) return 'Maps & Navigation';
    if (lower.contains('calc') || lower.contains('calendar') || lower.contains('clock') || lower.contains('deskclock') || lower.contains('notes') || lower.contains('office') || lower.contains('document') || lower.contains('pdf')) return 'Productivity';
    if (isSystemApp) return 'System';
    return 'Tools';
  }

  EdgeInsets _getGridPadding(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 140.0 + safeBottom + bottomInset);
  }

  @override
  Widget build(BuildContext context) {
    final indexedCount = _images
        .where((img) => img.isProcessed || img.embedding != null)
        .length;
    final isWorkerRunning =
        BackgroundWorkerService.instance.isBackgroundWorkerActive;
    final isPaused = BackgroundWorkerService.instance.isPaused;

    final activeTabs = _getActiveTabDefs(
      indexedCount: indexedCount,
      isWorkerRunning: isWorkerRunning,
      isPaused: isPaused,
    );
    _updateTabControllerIfNeeded(activeTabs);

    final isPhotosActive = _tabController.index < activeTabs.length &&
        activeTabs[_tabController.index].key == 'photos';

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const _TopBarLogo(),
        centerTitle: false,
        titleSpacing: 16.0,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF15786C),
                Color(0xFF15786C),
                Color(0xFF2E8E82),
                Color(0xFF67B2A8),
                Color(0xFFD6EAE6),
              ],
              stops: [0.0, 0.22, 0.52, 0.78, 1.0],
            ),
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorColor: const Color(0xFF15786C),
          indicatorWeight: 3.5,
          labelColor: const Color(0xFF15786C),
          unselectedLabelColor: const Color(0xFF475569),
          labelStyle: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13.5,
          ),
          tabs: activeTabs.asMap().entries.map((entry) {
            final idx = entry.key;
            final tabDef = entry.value;
            return _buildTab(
              tabIndex: idx,
              label: tabDef.label,
              count: tabDef.countGetter(),
              assetPath: tabDef.assetPath,
              icon: tabDef.icon,
            );
          }).toList(),
        ),
        actions: [
          // On Photos tab: Pause / Resume / Start Background Worker
          if (isPhotosActive &&
              AiService.instance.isModelLoaded &&
              _images.isNotEmpty)
            IconButton(
              icon: Icon(
                isWorkerRunning
                    ? (isPaused
                          ? Icons.play_circle_filled
                          : Icons.pause_circle_filled)
                    : (indexedCount == _images.length
                          ? Icons.check_circle_outline
                          : Icons.play_circle_outline),
                color: isWorkerRunning
                    ? (isPaused ? Colors.amberAccent : Colors.white)
                    : (indexedCount == _images.length
                          ? Colors.lightGreenAccent
                          : Colors.white70),
                size: 26,
              ),
              tooltip: isWorkerRunning
                  ? (isPaused
                        ? 'Resume Background Worker'
                        : 'Pause Background Worker')
                  : (indexedCount == _images.length
                        ? 'Worker Auto-Stopped (All photos indexed)'
                        : 'Start Background Worker'),
              onPressed: _togglePauseResume,
            ),
          // Right-aligned Animated Processing Progress Pill
          Builder(
            builder: (context) {
              final pill = _buildAppBarProgressPill();
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.85, end: 1.0).animate(animation),
                    child: child,
                  ),
                ),
                child: pill != null
                    ? Padding(
                        key: const ValueKey('progress_pill_active'),
                        padding: const EdgeInsets.symmetric(horizontal: 4.0),
                        child: Center(
                          child: pill,
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('empty_progress')),
              );
            },
          ),
          // Persistent indicator in AppBar when AI model is offline
          if (!AiService.instance.isModelLoaded)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: InkWell(
                onTap: () => context.push('/model-downloader'),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 13, color: Colors.amberAccent),
                      SizedBox(width: 4),
                      Text(
                        'Setup AI',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.swap_horiz_rounded),
            tooltip: 'Rearrange Tabs',
            onPressed: () {
              HapticFeedback.lightImpact();
              _showRearrangeTabsBottomSheet();
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () async {
              final result = await context.push('/settings');
              await _loadSortModeSetting(force: true);
              _syncSettings();
              if (result is String) {
                _handleRescanCommand(result);
              }
            },
          ),
        ],
      ),
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          if (_searchFocusNode.hasFocus) {
            final renderBox =
                _searchBarKey.currentContext?.findRenderObject() as RenderBox?;
            if (renderBox != null) {
              final local = renderBox.globalToLocal(event.position);
              if (renderBox.paintBounds.contains(local)) {
                return; // tapped inside search bar, do not unfocus
              }
            }
            FocusManager.instance.primaryFocus?.unfocus();
            SystemChannels.textInput.invokeMethod('TextInput.hide');
          }
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (scrollInfo) {
            if (_searchFocusNode.hasFocus &&
                (scrollInfo is ScrollUpdateNotification ||
                 scrollInfo is UserScrollNotification ||
                 scrollInfo is ScrollStartNotification)) {
              FocusManager.instance.primaryFocus?.unfocus();
              SystemChannels.textInput.invokeMethod('TextInput.hide');
            }
            return false;
          },
          child: Stack(
            children: [
              Column(
                children: [
                  // Permission Banner (if any permission is denied)
                  if (_hasDeniedPermissions) _buildPermissionBanner(),

                  // Model Status Banner (if model missing, on device, or downloading)
                  _buildModelStatusBanner(),

                  // Tab Content: Dynamically renders only active tabs
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: activeTabs.map((tabDef) => tabDef.viewBuilder()).toList(),
                    ),
                  ),
                ],
              ),

              // Floating Dynamic Island Search Bar at bottom of screen with Sunrise Rubbery In-Animation
              Positioned(
                left: 0,
                right: 0,
                bottom: MediaQuery.viewInsetsOf(context).bottom,
                child: SafeArea(
                  child: _SunriseSearchBar(
                    child: _buildFloatingSearchIsland(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Floating Search Island Widget (No background container/card, floating at bottom)
  Widget _buildFloatingSearchIsland() {
    return AnimatedBuilder(
      animation: Listenable.merge([_searchController, _searchFocusNode]),
      builder: (context, _) {
        final isFilesReading = _isInitialLoading || _isStillLoadingContent;
        final isFocusedOrTyping =
            _searchFocusNode.hasFocus || _searchController.text.isNotEmpty;
        final hasActiveSearch =
            _hasSubmittedSearch && _searchController.text.trim().isNotEmpty;
        final showCancelOrClear = hasActiveSearch || _isSearching;

        String readingStatusText;
        if (_isLoadingImages) {
          readingStatusText = 'Reading photos...';
        } else if (_isLoadingVideos) {
          readingStatusText = 'Reading videos...';
        } else if (_isLoadingAudios) {
          readingStatusText = 'Reading audio...';
        } else if (_isLoadingDocuments) {
          readingStatusText = 'Reading documents...';
        } else if (_isLoadingApps || _isLoadingContacts || _isLoadingSms) {
          readingStatusText = 'Reading apps & contacts...';
        } else {
          readingStatusText = 'Reading files...';
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _AnimatedSearchGlow(
            key: _searchBarKey,
            hasActiveSearch: hasActiveSearch,
            isSearching: _isSearching,
            searchEpoch: _searchEpoch,
            child: Container(
              decoration: BoxDecoration(
                color: isFilesReading ? const Color(0xFFF8FAFC) : Colors.white,
                borderRadius: BorderRadius.circular(50),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: isFocusedOrTyping ? 0.12 : 0.08,
                    ),
                    blurRadius: 14,
                    spreadRadius: 1,
                    offset: const Offset(0, 3),
                  ),
                ],
                border: Border.all(
                  color: isFilesReading
                      ? Colors.grey.shade300
                      : (isFocusedOrTyping
                          ? const Color(0xFF15786C).withValues(alpha: 0.35)
                          : Colors.grey.shade200),
                  width: 1.2,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Leading Icon (Left):
                    // Shows spinner when _isSearching is true; locked icon when files reading; search icon otherwise
                    GestureDetector(
                      onTap: () {
                        if (isFilesReading) return;
                        if (_searchController.text.trim().isNotEmpty) {
                          _onSearchAction();
                        } else {
                          _searchFocusNode.requestFocus();
                        }
                      },
                      child: _isSearching
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Color(0xFF15786C),
                              ),
                            )
                          : Icon(
                              isFilesReading
                                  ? Icons.lock_outline_rounded
                                  : Icons.search,
                              color: isFilesReading
                                  ? Colors.grey.shade400
                                  : const Color(0xFF15786C),
                              size: 24,
                            ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          if (isFilesReading)
                            Row(
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                    color: Color(0xFF15786C),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    readingStatusText,
                                    style: TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.grey.shade600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            )
                          else if (!isFocusedOrTyping)
                            _AnimatedSearchHint(
                              staticStyle: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w400,
                                color: Colors.grey.shade400,
                              ),
                              animatedStyle: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: const Color(
                                  0xFF15786C,
                                ).withValues(alpha: 0.8),
                              ),
                            ),
                          TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            enabled: !isFilesReading,
                            showCursor: !isFilesReading,
                            minLines: 1,
                            maxLines: 2,
                            textInputAction: TextInputAction.search,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF1E293B),
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 0.0,
                                vertical: 8.0,
                              ),
                              isDense: true,
                            ),
                            onSubmitted: (_) =>
                                isFilesReading ? null : _onSearchAction(),
                            onChanged: (val) {
                              _searchDebounceTimer?.cancel();
                              if (val.trim().isEmpty) {
                                if (_hasSubmittedSearch) {
                                  setState(() {
                                    _hasSubmittedSearch = false;
                                    _searchEpoch = 0;
                                  });
                                  _performUniversalSearch('');
                                }
                              } else {
                                if (_hasSubmittedSearch) {
                                  setState(() {
                                    _hasSubmittedSearch = false;
                                  });
                                }
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    // Trailing Action Button (Right):
                    // When files are reading: disabled locked button
                    // When searching or search active: prominent cancel 'X' button (NO LOADER HERE!)
                    // When idle: teal search button
                    if (isFilesReading)
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(50),
                        ),
                        child: Icon(
                          Icons.hourglass_top_rounded,
                          size: 20,
                          color: Colors.grey.shade500,
                        ),
                      )
                    else
                      Material(
                        color: showCancelOrClear
                            ? const Color(0xFFE53935)
                            : const Color(0xFF15786C),
                        borderRadius: BorderRadius.circular(50),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(50),
                          onTap: () {
                            if (showCancelOrClear) {
                              _cancelSearch();
                            } else {
                              _onSearchAction();
                            }
                          },
                          child: Tooltip(
                            message: showCancelOrClear ? 'Cancel search' : 'Search',
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: Center(
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  transitionBuilder: (child, anim) => ScaleTransition(
                                    scale: anim,
                                    child: child,
                                  ),
                                  child: showCancelOrClear
                                      ? const Icon(
                                          Icons.close_rounded,
                                          key: ValueKey('cancel_search_icon'),
                                          size: 24,
                                          color: Colors.white,
                                        )
                                      : const Icon(
                                          Icons.search_rounded,
                                          key: ValueKey('execute_search_icon'),
                                          size: 24,
                                          color: Colors.white,
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchShimmerGrid() {
    return CustomScrollView(
      physics: const NeverScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _gridColumns,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1.0,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => const _ShimmerCardWidget(),
              childCount: _gridColumns * 4,
            ),
          ),
        ),
      ],
    );
  }

  // --- ALL / TIMELINE TAB & METHODS ---

  Widget _buildAllTimelineTab() {
    if (_isInitialLoading && _searchController.text.trim().isEmpty) {
      return _buildSearchShimmerGrid();
    }

    final hasPermissionProblem = _hasDeniedPermissions ||
        _isPermanentlyDenied ||
        _missingPermissions.isNotEmpty;

    // While searching:
    if (_isSearching) {
      return _buildSearchShimmerGrid();
    }

    // If search text has no match:
    if (_hasSubmittedSearch &&
        _searchController.text.isNotEmpty &&
        _filteredTimelineItems.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off_outlined,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 12),
              Text(
                'No items match "${_searchController.text}"',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // When not searching: if timeline is empty
    if (_filteredTimelineItems.isEmpty) {
      // ONLY show reload / permission button if it failed by permissions!
      if (hasPermissionProblem) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.security_outlined,
                  size: 64,
                  color: Colors.orange.shade400,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Permissions Needed to Access Storage',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF15786C),
                  ),
                  onPressed: _requestMissingPermissions,
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('Grant Permissions'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _reloadPermittedData,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Reload All Data'),
                ),
              ],
            ),
          ),
        );
      }

      // If still loading or initial timer active: show shimmer
      if (_isInitialLoading || _isStillLoadingContent) {
        return _buildSearchShimmerGrid();
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.hourglass_empty_rounded,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 12),
              const Text(
                'No media or items found',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Add photos, videos, or documents to your device to view them here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF15786C),
                ),
                onPressed: _pickImagesManually,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Pick Photos Manually'),
              ),
            ],
          ),
        ),
      );
    }

    final displayCount = math.min(_timelineDisplayLimit, _filteredTimelineItems.length);
    final hasMore = displayCount < _filteredTimelineItems.length;

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        _onTabScroll(0, scrollInfo);
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () async {
          _reloadPermittedData();
        },
        color: const Color(0xFF15786C),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 8,
              ),
              sliver: SliverGrid(
                gridDelegate:
                    SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gridColumns,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 1.0,
                    ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = _filteredTimelineItems[index];
                  final card = _buildTimelineCard(item);
                  return _PopInCard(
                    key: ValueKey('pop_timeline_${item.type.name}_${item.id}'),
                    index: index < 12 ? index : 0,
                    child: card,
                  );
                }, childCount: displayCount),
              ),
            ),
            if (hasMore)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _gridColumns,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.0,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => const _ShimmerCardWidget(),
                    childCount: _gridColumns,
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 140.0 +
                    MediaQuery.paddingOf(context).bottom +
                    MediaQuery.viewInsetsOf(context).bottom,
              ),
            ),
          ],
        ),
      ),
    );
  }


  // PDF Thumbnail Cache and Scanned vs Text PDF helpers
  final Map<String, Uint8List?> _pdfThumbnailCache = {};

  Future<Uint8List?> _getPdfFirstPageThumbnail(String pdfPath) async {
    if (_pdfThumbnailCache.containsKey(pdfPath)) {
      return _pdfThumbnailCache[pdfPath];
    }
    try {
      final file = File(pdfPath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final images = TextExtractionService.extractEmbeddedJpegImages(
        bytes,
        maxImages: 1,
      );
      final result = images.isNotEmpty ? images.first : null;
      _pdfThumbnailCache[pdfPath] = result;
      return result;
    } catch (e) {
      debugPrint('Error extracting PDF thumbnail: $e');
      _pdfThumbnailCache[pdfPath] = null;
      return null;
    }
  }

  bool _isScannedPdf(DeviceDocument doc) {
    if (doc.category != DocumentCategory.pdf) return false;
    if (doc.extractedText != null && doc.extractedText!.contains('--- Page')) {
      return true;
    }
    if (_pdfThumbnailCache.containsKey(doc.path) &&
        _pdfThumbnailCache[doc.path] != null) {
      return true;
    }
    return false;
  }

  /// Distinct Text Content Card: Single square card (no nested card) with title on top-left,
  /// text content directly on the card, and inner white fader shadow covering bottom 50% from bottom to center.
  Widget _buildTextContentCard({
    required String title,
    required String textContent,
    required String typeLabel,
    required Color typeColor,
    required IconData typeIcon,
    DateTime? timestamp,
    VoidCallback? onTap,
    Widget? topTrailing,
    String? subtitle,
  }) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Stack(
          children: [
            // 1. Text & Headers directly on the single card
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  _gridColumns == 4 ? 8 : 14,
                  _gridColumns == 4 ? 8 : 12,
                  _gridColumns == 4 ? 8 : 14,
                  _gridColumns == 4 ? 6 : 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top Row: Icon on left, title & subtitle right next to icon, timestamp on right
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          padding: EdgeInsets.all(_gridColumns == 4 ? 3.5 : 5.5),
                          decoration: BoxDecoration(
                            color: typeColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(typeIcon, size: _gridColumns == 4 ? 12 : 15, color: typeColor),
                        ),
                        SizedBox(width: _gridColumns == 4 ? 5 : 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: _gridColumns == 4 ? 10.5 : (_gridColumns == 3 ? 11.5 : 12.5),
                                  color: const Color(0xFF1E293B),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (subtitle != null && subtitle.isNotEmpty && _gridColumns <= 3) ...[
                                const SizedBox(height: 1.5),
                                Text(
                                  subtitle,
                                  style: TextStyle(
                                    fontSize: _gridColumns == 3 ? 9.0 : 10.0,
                                    color: Colors.grey.shade600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (topTrailing != null && _gridColumns <= 3) ...[
                          const SizedBox(width: 4),
                          topTrailing,
                        ],
                        if (timestamp != null &&
                            timestamp.millisecondsSinceEpoch > 0 &&
                            _gridColumns <= 2) ...[
                          const SizedBox(width: 4),
                          Text(
                            _formatTimelineDate(timestamp),
                            style: TextStyle(
                              fontSize: 9.0,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ],
                    ),
                    SizedBox(height: _gridColumns == 4 ? 4 : 8),

                    // Text Content directly on the card
                    Expanded(
                      child: Text(
                        textContent.trim().isNotEmpty
                            ? textContent.trim()
                            : 'No text content available',
                        style: TextStyle(
                          fontSize: _gridColumns == 4 ? 9.5 : (_gridColumns == 3 ? 10.5 : 11.5),
                          height: 1.35,
                          color: Colors.grey.shade800,
                          letterSpacing: 0.1,
                        ),
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 2. White Fader directly on the square card covering bottom 50%
            Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: 0.50,
                widthFactor: 1.0,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(_cardRadius),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.white,
                        Colors.white.withValues(alpha: 0.95),
                        Colors.white.withValues(alpha: 0.65),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.35, 0.70, 1.0],
                    ),
                  ),
                ),
              ),
            ),

            // 4. Ripple InkWell
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(_cardRadius),
                  onTap: onTap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Scanned PDF Image Card: Perfect square single card with dynamic border radius showing page 1 image preview directly
  Widget _buildScannedPdfCard({
    required DeviceDocument doc,
    VoidCallback? onTap,
  }) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_cardRadius),
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. Scanned Image Thumbnail filling card directly
                FutureBuilder<Uint8List?>(
                  future: _getPdfFirstPageThumbnail(doc.path),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.done &&
                        snapshot.data != null &&
                        snapshot.data!.isNotEmpty) {
                      return Image.memory(
                        snapshot.data!,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.low,
                      );
                    }
                    return Container(
                      color: Colors.purple.shade50.withValues(alpha: 0.5),
                      child: Center(
                        child: Icon(
                          Icons.document_scanner,
                          size: _gridColumns == 4 ? 30 : 44,
                          color: Colors.purple.shade300,
                        ),
                      ),
                    );
                  },
                ),

                // Top-left floating document scanner icon
                Positioned(
                  top: _gridColumns == 4 ? 8 : 12,
                  left: _gridColumns == 4 ? 8 : 14,
                  child: Container(
                    padding: EdgeInsets.all(_gridColumns == 4 ? 3.5 : 5.5),
                    decoration: BoxDecoration(
                      color: Colors.purple.shade700.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.document_scanner,
                      size: _gridColumns == 4 ? 12 : 15,
                      color: Colors.white,
                    ),
                  ),
                ),

                // Top-right PDF badge (show on 2 and 3 columns)
                if (_gridColumns <= 3)
                  Positioned(
                    top: 12,
                    right: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.60),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'PDF',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),

                // Bottom Left: Document Name, and under that Timestamp
                Positioned(
                  bottom: _gridColumns == 4 ? 8 : 12,
                  left: _gridColumns == 4 ? 8 : 14,
                  right: _gridColumns == 4 ? 8 : 14,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        doc.name,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: _gridColumns == 4 ? 10.5 : (_gridColumns == 3 ? 11.5 : 13),
                          color: const Color(0xFF1E293B),
                          height: 1.2,
                          shadows: const [Shadow(color: Colors.white, blurRadius: 6)],
                        ),
                        maxLines: _gridColumns == 2 ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_gridColumns <= 3) ...[
                        const SizedBox(height: 3),
                        Text(
                          _formatDate(doc.modifiedDate),
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Colors.grey.shade700,
                            fontWeight: FontWeight.w500,
                            shadows: const [
                              Shadow(color: Colors.white, blurRadius: 4),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineCard(TimelineItem item) {
    // 1. Text PDF or Document with Extracted Text
    if (item.type == TimelineItemType.document &&
        item.originalObject is DeviceDocument) {
      final doc = item.originalObject as DeviceDocument;
      if (_isScannedPdf(doc)) {
        return _buildScannedPdfCard(
          doc: doc,
          onTap: () => _onTimelineItemTapped(item),
        );
      } else if (doc.extractedText != null && doc.extractedText!.isNotEmpty) {
        return _buildTextContentCard(
          title: doc.name,
          textContent: doc.extractedText!,
          typeLabel: doc.categoryLabel,
          typeColor: doc.color,
          typeIcon: doc.icon,
          subtitle: doc.categoryLabel,
          timestamp: doc.modifiedDate,
          onTap: () => _onTimelineItemTapped(item),
        );
      } else {
        return _buildDocumentCard(doc);
      }
    }

    // 2. SMS Message: Text Content Card
    if (item.type == TimelineItemType.sms && item.originalObject is DeviceSms) {
      final sms = item.originalObject as DeviceSms;
      return _buildTextContentCard(
        title: sms.address,
        textContent: sms.body,
        typeLabel: 'SMS',
        typeColor: const Color(0xFF0D9488),
        typeIcon: Icons.sms_outlined,
        subtitle: '${sms.type} Message',
        timestamp: sms.date,
        onTap: () => _onTimelineItemTapped(item),
      );
    }

    // 3. OCR Text match in Photo
    if (item.type == TimelineItemType.photo &&
        item.originalObject is DeviceImage &&
        (item.originalObject as DeviceImage).extractedText != null &&
        (item.originalObject as DeviceImage).extractedText!.isNotEmpty &&
        _hasSubmittedSearch &&
        _searchController.text.isNotEmpty &&
        (item.originalObject as DeviceImage).extractedText!
            .toLowerCase()
            .contains(_searchController.text.trim().toLowerCase())) {
      final img = item.originalObject as DeviceImage;
      return _buildTextContentCard(
        title: img.name,
        textContent: img.extractedText!,
        typeLabel: 'PHOTO OCR',
        typeColor: const Color(0xFF15786C),
        typeIcon: Icons.document_scanner_outlined,
        subtitle: 'OCR Text Match',
        timestamp: img.modifiedDate,
        onTap: () => _onTimelineItemTapped(item),
      );
    }

    // 4. Photo without OCR
    if (item.type == TimelineItemType.photo && item.path != null) {
      return _buildTimelinePhotoCard(item);
    }

    // 5. Standard item (Video, Audio, Contact, Call, App)
    return _buildTimelineStandardCard(item);
  }

  /// Timeline Photo Card: Single square card with image, 50% bottom fader, and info
  Widget _buildTimelinePhotoCard(TimelineItem item) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_cardRadius),
            onTap: () => _onTimelineItemTapped(item),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (item.path != null)
                  Image.file(
                    File(item.path!),
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    cacheWidth: 280,
                    errorBuilder: (context, error, stackTrace) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (item.path != null && !File(item.path!).existsSync()) {
                          _handleLiveFileDeleted(item.path!);
                        }
                      });
                      return Container(
                        color: Colors.grey.shade200,
                        child: Center(
                          child: Icon(
                            Icons.photo,
                            color: Colors.grey.shade400,
                            size: _gridColumns == 4 ? 26 : 36,
                          ),
                        ),
                      );
                    },
                  ),
                // Floating top-left icon only for image cards
                Positioned(
                  top: _gridColumns == 4 ? 8 : 12,
                  left: _gridColumns == 4 ? 8 : 14,
                  child: Container(
                    padding: EdgeInsets.all(_gridColumns == 4 ? 3.5 : 4.5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Image.asset(
                      'assets/iamges/images.png',
                      width: _gridColumns == 4 ? 12 : 15,
                      height: _gridColumns == 4 ? 12 : 15,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Icons.image_outlined,
                        size: _gridColumns == 4 ? 12 : 15,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Timeline Standard Item: Single square card with 50% bottom fader
  Widget _buildTimelineStandardCard(TimelineItem item) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_cardRadius),
            onTap: () => _onTimelineItemTapped(item),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      _gridColumns == 4 ? 8 : 14,
                      _gridColumns == 4 ? 8 : 12,
                      _gridColumns == 4 ? 8 : 14,
                      _gridColumns == 4 ? 6 : 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (item.type == TimelineItemType.app &&
                                item.originalObject is DeviceApp)
                              AppIconWidget(
                                packageName:
                                    (item.originalObject as DeviceApp)
                                        .packageName,
                                size: _gridColumns == 4 ? 22 : (_gridColumns == 3 ? 24 : 28),
                              )
                            else
                              Container(
                                padding: EdgeInsets.all(_gridColumns == 4 ? 3.5 : 5.5),
                                decoration: BoxDecoration(
                                  color: item.color.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  item.icon,
                                  size: _gridColumns == 4 ? 12 : 15,
                                  color: item.color,
                                ),
                              ),
                            const Spacer(),
                            if (item.timestamp.millisecondsSinceEpoch > 0 && _gridColumns <= 2)
                              Text(
                                _formatTimelineDate(item.timestamp),
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                          ],
                        ),
                        SizedBox(height: _gridColumns == 4 ? 6 : 10),
                        Text(
                          item.title,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: _gridColumns == 4 ? 10.5 : (_gridColumns == 3 ? 11.5 : 13),
                            color: const Color(0xFF1E293B),
                          ),
                          maxLines: _gridColumns == 2 ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_gridColumns <= 3) ...[
                          const SizedBox(height: 3),
                          Text(
                            item.subtitle,
                            style: TextStyle(
                              fontSize: _gridColumns == 3 ? 9.5 : 11,
                              color: Colors.grey.shade600,
                              height: 1.2,
                            ),
                            maxLines: _gridColumns == 2 ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // White Fader covering bottom 50%
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 0.50,
                    widthFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(_cardRadius),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.white,
                            Colors.white.withValues(alpha: 0.95),
                            Colors.white.withValues(alpha: 0.65),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                          stops: const [0.0, 0.35, 0.70, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Single Square Document Card (Word, Excel, PPT, etc.)
  Widget _buildDocumentCard(DeviceDocument doc) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_cardRadius),
            onTap: () => _openMediaFile(doc.path),
            child: Stack(
              children: [
                // Subtle center watermark icon of doc type
                Center(
                  child: Icon(
                    doc.icon,
                    size: _gridColumns == 4 ? 32 : 46,
                    color: doc.color.withValues(alpha: 0.08),
                  ),
                ),

                // Top row: Document type icon on top-left, extension badge on top-right
                Positioned(
                  top: _gridColumns == 4 ? 8 : 12,
                  left: _gridColumns == 4 ? 8 : 14,
                  right: _gridColumns == 4 ? 8 : 14,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        padding: EdgeInsets.all(_gridColumns == 4 ? 3.5 : 5.5),
                        decoration: BoxDecoration(
                          color: doc.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(doc.icon, size: _gridColumns == 4 ? 12 : 15, color: doc.color),
                      ),
                      const Spacer(),
                      if (_gridColumns <= 3) ...[
                        if (_hasSubmittedSearch && doc.score != null && doc.score! >= 0.70)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF15786C).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${(doc.score! * 100).toInt()}% Match',
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF15786C),
                              ),
                            ),
                          ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: doc.color.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            doc.extension.toUpperCase().replaceAll('.', ''),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: doc.color,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                // Bottom Left: Document Name, and under that Timestamp
                Positioned(
                  bottom: _gridColumns == 4 ? 8 : 12,
                  left: _gridColumns == 4 ? 8 : 14,
                  right: _gridColumns == 4 ? 8 : 14,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        doc.name,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: _gridColumns == 4 ? 10.5 : (_gridColumns == 3 ? 11.5 : 13),
                          color: const Color(0xFF1E293B),
                          height: 1.2,
                        ),
                        maxLines: _gridColumns == 2 ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_gridColumns <= 3) ...[
                        const SizedBox(height: 3),
                        Text(
                          _formatDate(doc.modifiedDate),
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Colors.grey.shade500,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStaggeredGrid() {
    final count = math.min(_displayLimit, _searchResults.length);
    final hasMore = count < _searchResults.length;

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        _onTabScroll(1, scrollInfo);
        return false;
      },
      child: RefreshIndicator(
        onRefresh: _loadAllDeviceImages,
        child: GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: _getGridPadding(context),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _gridColumns,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.0,
          ),
          itemCount: hasMore ? count + _gridColumns : count,
          itemBuilder: (context, index) {
            if (index >= count) {
              return const _ShimmerCardWidget();
            }
            final img = _searchResults[index];
            final card = _buildPhotoCard(img, index);
            return _PopInCard(
              key: ValueKey('pop_photo_${img.id}'),
              index: index < 12 ? index : 0,
              child: card,
            );
          },
        ),
      ),
    );
  }

  Widget _buildPhotoCard(DeviceImage img, int index) {
    final hasScore = img.score != null;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_cardRadius),
            onTap: () => _openMediaFile(img.path),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(img.path),
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                  cacheWidth: 280,
                  filterQuality: FilterQuality.low,
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) {
                        if (wasSynchronouslyLoaded) return child;
                        return AnimatedOpacity(
                          opacity: frame == null ? 0 : 1,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          child: child,
                        );
                      },
                  errorBuilder: (context, error, stackTrace) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!File(img.path).existsSync()) {
                        _handleLiveFileDeleted(img.path);
                      }
                    });
                    return Container(
                      color: Colors.grey.shade200,
                      child: Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: Colors.grey.shade400,
                          size: 36,
                        ),
                      ),
                    );
                  },
                ),

                // Floating top-left icon only for image cards
                Positioned(
                  top: _gridColumns == 4 ? 8 : 12,
                  left: _gridColumns == 4 ? 8 : 14,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: EdgeInsets.all(_gridColumns == 4 ? 3.5 : 4.5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Image.asset(
                          'assets/iamges/images.png',
                          width: _gridColumns == 4 ? 12 : 15,
                          height: _gridColumns == 4 ? 12 : 15,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) => Icon(
                            Icons.image_outlined,
                            size: _gridColumns == 4 ? 12 : 15,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (img.isEmbedding && _gridColumns <= 3) ...[
                        const SizedBox(width: 4),
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhotosTab(
    int indexedCount,
    bool isWorkerRunning,
    bool isPaused,
  ) {
    if (_isInitialLoading && _searchController.text.trim().isEmpty) {
      return _buildSearchShimmerGrid();
    }

    if (_searchResults.isEmpty) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off_outlined,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 12),
              Text(
                'No photos match "${_searchController.text}"',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      }

      final hasPermissionProblem = _hasDeniedPermissions ||
          _isPermanentlyDenied ||
          _missingPermissions.contains('Photos');

      if (hasPermissionProblem) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.security_outlined,
                size: 64,
                color: Colors.orange.shade400,
              ),
              const SizedBox(height: 12),
              const Text(
                'Photo Access Permission Needed',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF15786C),
                ),
                onPressed: _requestMissingPermissions,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Grant Access'),
              ),
            ],
          ),
        );
      }

      // If still loading or initial timer active: show shimmer
      if (_isInitialLoading || _isLoadingImages) {
        return _buildSearchShimmerGrid();
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.photo_library_outlined,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 12),
              const Text(
                'No photos found on device',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Photos taken or saved to your device storage will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF15786C),
                ),
                onPressed: _pickImagesManually,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Pick Photos Manually'),
              ),
            ],
          ),
        ),
      );
    }

    return _buildStaggeredGrid();
  }

  // --- DOCUMENTS TAB & METHODS ---

  Future<void> _loadAllDeviceDocuments({bool forceRescan = false}) async {
    setState(() {
      _isLoadingDocuments = true;
      _documentsStatus = 'Loading cached documents...';
    });

    try {
      // 1. First load cached documents from database
      final cachedDocs = await DatabaseService.instance.getAllDocumentRecords();
      final List<DeviceDocument> initialDocs = [];
      final List<String> missingDocs = [];
      for (final cd in cachedDocs.values) {
        if (!File(cd.path).existsSync()) {
          missingDocs.add(cd.path);
          continue;
        }
        initialDocs.add(
          DeviceDocument(
            id: cd.path,
            path: cd.path,
            name: cd.name,
            extension: cd.extension,
            fileSize: cd.fileSize,
            modifiedDate: DateTime.fromMillisecondsSinceEpoch(
              cd.modifiedTimestamp,
            ),
            category: DocumentCategory.values.firstWhere(
              (c) => c.name == cd.category,
              orElse: () => DocumentCategory.other,
            ),
            location: cd.location ?? '',
            extractedText: cd.extractedText,
            isOcrProcessed: cd.isOcrProcessed,
            isProcessed: cd.isProcessed,
            embedding: cd.embedding,
          ),
        );
      }

      if (missingDocs.isNotEmpty) {
        await DatabaseService.instance.deleteRecordsBatch(missingDocs);
        for (final p in missingDocs) {
          cachedDocs.remove(p);
          LiveStorageWatcherService.instance.removeKnownPath(p);
        }
      }

      final cleanInitialDocs = DuplicateRemoverService.instance
          .removeDuplicateDocuments(initialDocs);

      final scanDocsEnabled = PreferencesService.instance.isCategoryScanningEnabled('documents');
      if (!scanDocsEnabled) {
        if (mounted) {
          setState(() {
            _documents = cleanInitialDocs;
            _applyDocumentFilters();
            _isLoadingDocuments = false;
            _documentsStatus = '${_documents.length} documents (Scanning paused in Settings)';
            _updateTimeline();
          });
        }
        return;
      }

      if (cleanInitialDocs.isNotEmpty && mounted) {
        setState(() {
          _documents = cleanInitialDocs;
          _applyDocumentFilters();
          _documentsStatus = '${_documents.length} documents';
          _updateTimeline();
        });

        if (!forceRescan) {
          if (mounted) setState(() => _isLoadingDocuments = false);
          _triggerPendingTextExtraction();
          return;
        }
      }

      // 2. Discover documents from storage
      final rawDocs = await DocumentCollectorService.instance
          .collectAllDocuments(
            onProgress: (count, elapsedMs) {
              if (mounted) {
                setState(() {
                  final secs = (elapsedMs / 1000).toStringAsFixed(1);
                  _documentsStatus = '⚡ Discovered $count documents (${secs}s)';
                });
              }
            },
          );
      final docs = DuplicateRemoverService.instance.removeDuplicateDocuments(
        rawDocs,
      );

      // Merge new documents with cached OCR data
      final List<CachedDocumentRecord> toBatchInsert = [];
      for (final doc in docs) {
        final existing = cachedDocs[doc.path];
        if (existing != null) {
          doc.extractedText = existing.extractedText;
          doc.isOcrProcessed = existing.isOcrProcessed;
          doc.embedding = existing.embedding;
          doc.isProcessed = existing.isProcessed;
        } else {
          toBatchInsert.add(
            CachedDocumentRecord(
              path: doc.path,
              name: doc.name,
              extension: doc.extension,
              category: doc.category.name,
              fileSize: doc.fileSize,
              modifiedTimestamp: doc.modifiedDate.millisecondsSinceEpoch,
              location: doc.location,
              isOcrProcessed: false,
              isProcessed: false,
            ),
          );
        }
      }

      if (toBatchInsert.isNotEmpty) {
        await DatabaseService.instance.saveDocumentBatch(toBatchInsert);
      }

      if (mounted) {
        setState(() {
          _documents = docs;
          _applyDocumentFilters();
          _isLoadingDocuments = false;
          _documentsStatus = '${_documents.length} documents';
          _updateTimeline();
        });
      }

      // 3. Process OCR on PDF documents in background
      final pendingDocs = _documents
          .where(
            (d) =>
                !d.isProcessed &&
                !d.isOcrProcessed &&
                (d.category == DocumentCategory.pdf ||
                    d.category == DocumentCategory.text),
          )
          .toList();
      if (pendingDocs.isNotEmpty) {
        _setLiveProcessing(
          'Document OCR: Extracting ${pendingDocs.length} documents...',
        );
        BackgroundWorkerService.instance.runExtractionOnDocuments(
          pendingDocs,
          onDocExtracted: (doc, text) {
            if (mounted) {
              setState(() {});
              _setLiveProcessing(
                'Document OCR: Extracted text from ${doc.name}',
                autoDismiss: const Duration(seconds: 2),
              );
              _updateTimeline();
            }
          },
        );
      }
    } catch (e) {
      debugPrint('Error loading documents: $e');
      if (mounted) {
        setState(() {
          _isLoadingDocuments = false;
          _documentsStatus = 'Finished scanning documents';
        });
      }
    }
  }

  void _applyDocumentFilters() {
    final query = _searchController.text.trim().toLowerCase();
    List<DeviceDocument> result = List.from(_documents);

    if (_selectedDocCategory != null) {
      result = result.where((d) => d.category == _selectedDocCategory).toList();
    }

    if (_hasSubmittedSearch && query.isNotEmpty) {
      result = result.where((d) {
        final hasAiScore = (d.score ?? 0.0) >= 0.72;
        return d.name.toLowerCase().contains(query) ||
            (d.extractedText != null &&
                d.extractedText!.toLowerCase().contains(query)) ||
            hasAiScore;
      }).toList();
    }
    _sortDocumentsList(result);

    setState(() {
      _filteredDocuments = result;
    });
  }

  Widget _buildDocumentsTab() {
    if (_isInitialLoading && _searchController.text.trim().isEmpty) {
      return _buildSearchShimmerGrid();
    }

    if (_documents.isEmpty) {
      final hasPermissionProblem = _hasDeniedPermissions ||
          _isPermanentlyDenied ||
          _missingPermissions.contains('Documents');

      if (hasPermissionProblem) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.security_outlined,
                  size: 64,
                  color: Colors.orange.shade400,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Storage Permission Needed',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF15786C),
                  ),
                  onPressed: _requestMissingPermissions,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Grant Access'),
                ),
              ],
            ),
          ),
        );
      }

      if (_isInitialLoading || _isLoadingDocuments) {
        return _buildSearchShimmerGrid();
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.description_outlined,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 12),
              const Text(
                'No documents found on device',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'PDFs, Word docs, Excel spreadsheets, and presentations will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final pdfCount = _documents
        .where((d) => d.category == DocumentCategory.pdf)
        .length;
    final wordCount = _documents
        .where((d) => d.category == DocumentCategory.word)
        .length;
    final excelCount = _documents
        .where((d) => d.category == DocumentCategory.excel)
        .length;
    final pptCount = _documents
        .where((d) => d.category == DocumentCategory.presentation)
        .length;
    final textCount = _documents
        .where((d) => d.category == DocumentCategory.text)
        .length;
    final ebookCount = _documents
        .where((d) => d.category == DocumentCategory.ebook)
        .length;

    return RefreshIndicator(
      onRefresh: _loadAllDeviceDocuments,
      color: const Color(0xFF15786C),
      child: Column(
        children: [
          // Category Filter Chips
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.white,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildDocCategoryChip('All', _documents.length, null),
                  const SizedBox(width: 6),
                  if (pdfCount > 0) ...[
                    _buildDocCategoryChip(
                      'PDF',
                      pdfCount,
                      DocumentCategory.pdf,
                      color: const Color(0xFFE53935),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (wordCount > 0) ...[
                    _buildDocCategoryChip(
                      'Word',
                      wordCount,
                      DocumentCategory.word,
                      color: const Color(0xFF1E88E5),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (excelCount > 0) ...[
                    _buildDocCategoryChip(
                      'Excel',
                      excelCount,
                      DocumentCategory.excel,
                      color: const Color(0xFF2E7D32),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (pptCount > 0) ...[
                    _buildDocCategoryChip(
                      'PPT',
                      pptCount,
                      DocumentCategory.presentation,
                      color: const Color(0xFFF57C00),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (textCount > 0) ...[
                    _buildDocCategoryChip(
                      'Text',
                      textCount,
                      DocumentCategory.text,
                      color: const Color(0xFF00897B),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (ebookCount > 0) ...[
                    _buildDocCategoryChip(
                      'E-Books',
                      ebookCount,
                      DocumentCategory.ebook,
                      color: const Color(0xFF8E24AA),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),

          // Document List
          Expanded(
            child: _filteredDocuments.isEmpty
                ? ((_hasSubmittedSearch && _searchController.text.isNotEmpty)
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.search_off_outlined,
                                size: 64,
                                color: Colors.grey.shade400,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No documents match "${_searchController.text}"',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade700,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      )
                    : _buildSearchShimmerGrid())
                : NotificationListener<ScrollNotification>(
                    onNotification: (scrollInfo) {
                      _onTabScroll(4, scrollInfo);
                      return false;
                    },
                    child: GridView.builder(
                      padding: _getGridPadding(context),
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: _gridColumns,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 1.0,
                          ),
                      itemCount: math.min(_docDisplayLimit, _filteredDocuments.length) < _filteredDocuments.length
                          ? math.min(_docDisplayLimit, _filteredDocuments.length) + _gridColumns
                          : math.min(_docDisplayLimit, _filteredDocuments.length),
                      itemBuilder: (context, index) {
                        final displayCount = math.min(_docDisplayLimit, _filteredDocuments.length);
                        if (index >= displayCount) {
                          return const _ShimmerCardWidget();
                        }
                        final doc = _filteredDocuments[index];
                        Widget card;

                        // 1. Scanned PDF: Render as an Image Card Preview
                        if (_isScannedPdf(doc)) {
                          card = _buildScannedPdfCard(
                            doc: doc,
                            onTap: () => _openMediaFile(doc.path),
                          );
                        } else if ((doc.extractedText != null &&
                                doc.extractedText!.trim().isNotEmpty) ||
                            doc.category == DocumentCategory.pdf ||
                            doc.category == DocumentCategory.text) {
                          final previewText =
                              (doc.extractedText != null &&
                                  doc.extractedText!.trim().isNotEmpty)
                              ? doc.extractedText!
                              : (doc.isOcrProcessed
                                    ? 'No selectable text content in document'
                                    : 'Indexing text content...');
                          card = _buildTextContentCard(
                            title: doc.name,
                            textContent: previewText,
                            typeLabel: doc.categoryLabel,
                            typeColor: doc.color,
                            typeIcon: doc.icon,
                            subtitle:
                                '${doc.categoryLabel} • ${_formatDate(doc.modifiedDate).split(' ').first}',
                            timestamp: doc.modifiedDate,
                            onTap: () => _openMediaFile(doc.path),
                          );
                        } else {
                          // 3. Other Documents (Word, Excel, PPT)
                          card = _buildDocumentCard(doc);
                        }

                        return _PopInCard(
                          key: ValueKey('pop_doc_${doc.id}'),
                          index: index < 12 ? index : 0,
                          child: card,
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocCategoryChip(
    String label,
    int count,
    DocumentCategory? category, {
    Color? color,
  }) {
    final isSelected = _selectedDocCategory == category;
    final chipColor = color ?? const Color(0xFF15786C);

    return FilterChip(
      selected: isSelected,
      label: Text('$label ($count)'),
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
        color: isSelected ? Colors.white : Colors.black87,
      ),
      backgroundColor: Colors.grey.shade100,
      selectedColor: chipColor,
      checkmarkColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: isSelected ? chipColor : Colors.grey.shade300),
      ),
      onSelected: (_) {
        setState(() {
          _selectedDocCategory = isSelected ? null : category;
          _applyDocumentFilters();
        });
      },
    );
  }

  void _showDocumentDetails(DeviceDocument doc) {
    if (!File(doc.path).existsSync()) {
      _handleLiveFileDeleted(doc.path);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Document was deleted from device storage and removed.'),
          duration: Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: doc.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(doc.icon, color: doc.color, size: 28),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            doc.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${doc.categoryLabel} • ${doc.extension}',
                            style: TextStyle(
                              fontSize: 12,
                              color: doc.color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Divider(height: 1),
                const SizedBox(height: 14),
                _buildDocDetailRow(Icons.folder_outlined, 'Location', doc.path),
                _buildDocDetailRow(
                  Icons.data_usage,
                  'File Size',
                  '${_formatFileSize(doc.fileSize)} (${doc.fileSize} bytes)',
                ),
                _buildDocDetailRow(
                  Icons.access_time,
                  'Modified',
                  _formatDate(doc.modifiedDate),
                ),
                if (doc.extractedText != null &&
                    doc.extractedText!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Extracted Text (OCR / PDF):',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF15786C),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 120),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        doc.extractedText!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (doc.category == DocumentCategory.pdf &&
                        (doc.extractedText == null ||
                            doc.extractedText!.isEmpty))
                      TextButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Extracting text / OCR from PDF...',
                              ),
                            ),
                          );
                          final text = await TextExtractionService.instance
                              .extractTextFromPdf(doc.path);
                          if (text.isNotEmpty) {
                            doc.extractedText = text;
                            doc.isOcrProcessed = true;
                            await DatabaseService.instance
                                .updateDocumentOcrText(doc.path, text);
                            if (mounted) {
                              setState(() {});
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Extracted ${text.length} characters!',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.document_scanner, size: 16),
                        label: const Text('Extract / OCR'),
                      ),
                    const Spacer(),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF15786C),
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: doc.path));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Copied path to clipboard: ${doc.path}',
                            ),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy Path'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDocDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 10),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  // --- VIDEOS TAB & METHODS ---

  Future<void> _loadAllDeviceVideos({bool forceRescan = false}) async {
    setState(() {
      _isLoadingVideos = true;
    });

    try {
      // 1. Instant load from SQLite Database
      final cachedVideos = await DatabaseService.instance.getAllVideoRecords();
      final List<String> missingVids = [];
      final List<DeviceVideo> initialVids = [];
      for (final cv in cachedVideos.values) {
        if (!File(cv.path).existsSync()) {
          missingVids.add(cv.path);
          continue;
        }
        initialVids.add(
          DeviceVideo(
            id: cv.path,
            path: cv.path,
            name: cv.name,
            fileSize: cv.fileSize,
            modifiedDate: DateTime.fromMillisecondsSinceEpoch(cv.modifiedTimestamp),
            location: cv.location,
            isProcessed: cv.isProcessed,
            embedding: cv.embedding,
          ),
        );
      }

      if (missingVids.isNotEmpty) {
        await DatabaseService.instance.deleteRecordsBatch(missingVids);
        for (final p in missingVids) {
          cachedVideos.remove(p);
          LiveStorageWatcherService.instance.removeKnownPath(p);
        }
      }

      final scanVideosEnabled = PreferencesService.instance.isCategoryScanningEnabled('videos');
      if (!scanVideosEnabled) {
        if (mounted) {
          setState(() {
            _videos = initialVids;
            _filteredVideos = initialVids;
            _isLoadingVideos = false;
            _updateTimeline();
          });
        }
        return;
      }

      if (initialVids.isNotEmpty && mounted) {
        _sortVideosList(initialVids);
        setState(() {
          _videos = initialVids;
          _filteredVideos = initialVids;
          _updateTimeline();
        });

        if (!forceRescan) {
          if (mounted) setState(() => _isLoadingVideos = false);
          _embedPendingVideos();
          return;
        }
      }

      // 2. Discover from storage
      final rawVids = await MediaCollectorService.instance.collectVideos();
      final vids = DuplicateRemoverService.instance.removeDuplicateVideos(
        rawVids,
      );

      // Preserve previously computed embeddings and processed states from cache
      for (final v in vids) {
        final cached = cachedVideos[v.path];
        if (cached != null) {
          if (cached.embedding != null) v.embedding = cached.embedding;
          if (cached.isProcessed) v.isProcessed = true;
        }
      }

      // Save to SQLite DB
      final toSave = vids.map((v) {
        return CachedVideoRecord(
          path: v.path,
          name: v.name,
          fileSize: v.fileSize,
          modifiedTimestamp: v.modifiedDate.millisecondsSinceEpoch,
          location: v.location,
          isProcessed: v.isProcessed,
          embedding: v.embedding,
        );
      }).toList();
      await DatabaseService.instance.saveVideoBatch(toSave);

      if (mounted) {
        _sortVideosList(vids);
        setState(() {
          _videos = vids;
          _filteredVideos = vids;
          _isLoadingVideos = false;
          _updateTimeline();
        });
      }

      // Process AI text embeddings using video name & location (NOT vision binary model)
      await _embedPendingVideos();
    } catch (e) {
      debugPrint('Error loading videos: $e');
      if (mounted) setState(() => _isLoadingVideos = false);
    }
  }

  Future<void> _embedPendingVideos() async {
    if (AiService.instance.isModelLoaded && _videos.isNotEmpty) {
      final pendingVids = _videos
          .where((v) => !v.isProcessed && v.embedding == null)
          .toList();
      if (pendingVids.isNotEmpty) {
        _setLiveProcessing(
          'Video Text AI: Embedding ${pendingVids.length} videos...',
        );
      }
      await AiService.instance.embedAllByText<DeviceVideo>(
        _videos,
        textProvider: (v) => '${v.name} ${v.location}',
        onBatchCompleted: () {
          if (mounted) {
            final done = _videos
                .where((v) => v.isProcessed || v.embedding != null)
                .length;
            _setLiveProcessing(
              'Video Text AI: $done/${_videos.length} videos',
            );
            setState(() {});
          }
        },
      );
      _setLiveProcessing(
        'Video Text AI: All ${_videos.length} videos embedded',
        autoDismiss: const Duration(seconds: 2),
      );
    }
  }

  void _applyVideoFilters() {
    final q = _searchController.text.trim().toLowerCase();
    List<DeviceVideo> result;
    if (!_hasSubmittedSearch || q.isEmpty) {
      result = List.from(_videos);
      for (var v in result) {
        v.score = null;
      }
    } else {
      result = _videos.where((v) {
        return v.name.toLowerCase().contains(q);
      }).toList();
    }
    _sortVideosList(result);
    setState(() {
      _filteredVideos = result;
    });
  }

  Future<void> _performVideoSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || !AiService.instance.isModelLoaded) {
      _applyVideoFilters();
      return;
    }

    final currentRequestId = ++_searchRequestId;
    setState(() => _isSearching = true);
    try {
      final ranked = await AiService.instance.search<DeviceVideo>(
        query,
        _videos,
      );
      final lower = query.toLowerCase();
      final isLong = lower.length >= 2;
      final matched = ranked.where((v) {
        final nameMatch = isLong && v.name.toLowerCase().contains(lower);
        final hasAiScore = (v.score ?? 0.0) >= 0.72;
        return nameMatch || hasAiScore;
      }).toList();
      _sortVideosList(matched);
      if (mounted && currentRequestId == _searchRequestId) {
        setState(() {
          _filteredVideos = matched;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted && currentRequestId == _searchRequestId) {
        setState(() => _isSearching = false);
        _applyVideoFilters();
      }
    }
  }

  Widget _buildVideosTab() {
    if (_isInitialLoading && _searchController.text.trim().isEmpty) {
      return _buildSearchShimmerGrid();
    }

    if (_filteredVideos.isEmpty) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.search_off_outlined,
                  size: 64,
                  color: Colors.grey.shade400,
                ),
                const SizedBox(height: 12),
                Text(
                  'No videos match "${_searchController.text}"',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final hasPermissionProblem = _hasDeniedPermissions ||
          _isPermanentlyDenied ||
          _missingPermissions.contains('Videos');

      if (hasPermissionProblem) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.security_outlined,
                  size: 64,
                  color: Colors.orange.shade400,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Video Access Permission Needed',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF15786C),
                  ),
                  onPressed: _requestMissingPermissions,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Grant Access'),
                ),
              ],
            ),
          ),
        );
      }

      if (_isInitialLoading || _isLoadingVideos) {
        return _buildSearchShimmerGrid();
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.videocam_outlined,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 12),
              const Text(
                'No videos found on device',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Recorded videos or downloaded video files will show up here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final count = math.min(_videoDisplayLimit, _filteredVideos.length);
    final hasMore = count < _filteredVideos.length;

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        _onTabScroll(2, scrollInfo);
        return false;
      },
      child: RefreshIndicator(
        onRefresh: _loadAllDeviceVideos,
        color: const Color(0xFF15786C),
        child: GridView.builder(
          padding: _getGridPadding(context),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _gridColumns,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.0,
          ),
          itemCount: hasMore ? count + _gridColumns : count,
          itemBuilder: (context, index) {
            if (index >= count) {
              return const _ShimmerCardWidget();
            }
            final vid = _filteredVideos[index];
            final hasScore = vid.score != null;
            final card = _buildVideoCard(vid, hasScore ? index + 1 : null);
            return _PopInCard(
              key: ValueKey('pop_vid_${vid.id}'),
              index: index < 12 ? index : 0,
              child: card,
            );
          },
        ),
      ),
    );
  }

  /// Single Square Video Card with 50% bottom fader
  Widget _buildVideoCard(DeviceVideo vid, int? rank) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_cardRadius),
            onTap: () => _openMediaFile(vid.path),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      _gridColumns == 4 ? 8 : 14,
                      _gridColumns == 4 ? 8 : 12,
                      _gridColumns == 4 ? 8 : 14,
                      _gridColumns == 4 ? 6 : 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              padding: EdgeInsets.all(_gridColumns == 4 ? 3.5 : 5.5),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.videocam,
                                size: _gridColumns == 4 ? 12 : 15,
                                color: Colors.red.shade700,
                              ),
                            ),
                            const Spacer(),
                            if (_gridColumns <= 2)
                              Text(
                                _formatDate(vid.modifiedDate).split(' ').first,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                          ],
                        ),
                        SizedBox(height: _gridColumns == 4 ? 6 : 10),
                        Text(
                          vid.name,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: _gridColumns == 4 ? 10.5 : (_gridColumns == 3 ? 11.5 : 13),
                            color: const Color(0xFF1E293B),
                          ),
                          maxLines: _gridColumns == 2 ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_gridColumns <= 3) ...[
                          const SizedBox(height: 3),
                          Text(
                            _formatDate(vid.modifiedDate).split(' ').first,
                            style: TextStyle(
                              fontSize: _gridColumns == 3 ? 9.5 : 10.5,
                              color: Colors.grey.shade600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // White Fader directly on the square card covering bottom 50%
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 0.50,
                    widthFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(_cardRadius),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.white,
                            Colors.white.withValues(alpha: 0.95),
                            Colors.white.withValues(alpha: 0.65),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                          stops: const [0.0, 0.35, 0.70, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showVideoDetails(DeviceVideo vid, int? rank) {
    if (!File(vid.path).existsSync()) {
      _handleLiveFileDeleted(vid.path);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Video was deleted from device storage and removed.'),
          duration: Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.videocam,
                        color: Colors.red.shade700,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            vid.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Device Video File',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(height: 1),
                const SizedBox(height: 12),
                _buildDocDetailRow(Icons.folder_outlined, 'Path', vid.path),
                _buildDocDetailRow(
                  Icons.data_usage,
                  'File Size',
                  '${_formatFileSize(vid.fileSize)} (${vid.fileSize} bytes)',
                ),
                _buildDocDetailRow(
                  Icons.access_time,
                  'Modified',
                  _formatDate(vid.modifiedDate),
                ),
                _buildDocDetailRow(
                  Icons.auto_awesome,
                  'AI Search Status',
                  (vid.isProcessed || vid.embedding != null)
                      ? 'Text Embedding Indexed (${vid.embedding?.length ?? 0}-dim vector)'
                      : 'Pending Text Embedding',
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF15786C),
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: vid.path));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Copied video path: ${vid.path}'),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy Path'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- AUDIOS TAB & METHODS ---

  Future<void> _loadAllDeviceAudios({bool forceRescan = false}) async {
    setState(() {
      _isLoadingAudios = true;
    });

    try {
      // 1. Instant load from SQLite Database
      final cachedAudios = await DatabaseService.instance.getAllAudioRecords();
      final List<String> missingAuds = [];
      final List<DeviceAudio> initialAuds = [];
      for (final ca in cachedAudios.values) {
        if (!File(ca.path).existsSync()) {
          missingAuds.add(ca.path);
          continue;
        }
        initialAuds.add(
          DeviceAudio(
            id: ca.path,
            path: ca.path,
            name: ca.name,
            fileSize: ca.fileSize,
            modifiedDate: DateTime.fromMillisecondsSinceEpoch(ca.modifiedTimestamp),
            location: ca.location,
            isProcessed: ca.isProcessed,
            embedding: ca.embedding,
          ),
        );
      }

      if (missingAuds.isNotEmpty) {
        await DatabaseService.instance.deleteRecordsBatch(missingAuds);
        for (final p in missingAuds) {
          cachedAudios.remove(p);
          LiveStorageWatcherService.instance.removeKnownPath(p);
        }
      }

      final scanAudioEnabled = PreferencesService.instance.isCategoryScanningEnabled('audio');
      if (!scanAudioEnabled) {
        if (mounted) {
          setState(() {
            _audios = initialAuds;
            _filteredAudios = initialAuds;
            _isLoadingAudios = false;
            _updateTimeline();
          });
        }
        return;
      }

      if (initialAuds.isNotEmpty && mounted) {
        _sortAudiosList(initialAuds);
        setState(() {
          _audios = initialAuds;
          _filteredAudios = initialAuds;
          _updateTimeline();
        });

        if (!forceRescan) {
          if (mounted) setState(() => _isLoadingAudios = false);
          _embedPendingAudios();
          return;
        }
      }

      // 2. Discover from storage
      final rawAuds = await MediaCollectorService.instance.collectAudios();
      final auds = DuplicateRemoverService.instance.removeDuplicateAudios(
        rawAuds,
      );

      // Preserve previously computed embeddings and processed states from cache
      for (final a in auds) {
        final cached = cachedAudios[a.path];
        if (cached != null) {
          if (cached.embedding != null) a.embedding = cached.embedding;
          if (cached.isProcessed) a.isProcessed = true;
        }
      }

      // Save to SQLite DB
      final toSave = auds.map((a) {
        return CachedAudioRecord(
          path: a.path,
          name: a.name,
          fileSize: a.fileSize,
          modifiedTimestamp: a.modifiedDate.millisecondsSinceEpoch,
          location: a.location,
          isProcessed: a.isProcessed,
          embedding: a.embedding,
        );
      }).toList();
      await DatabaseService.instance.saveAudioBatch(toSave);

      if (mounted) {
        _sortAudiosList(auds);
        setState(() {
          _audios = auds;
          _filteredAudios = auds;
          _isLoadingAudios = false;
          _updateTimeline();
        });
      }

      // Process AI text embeddings using audio name & location (NOT vision binary model)
      await _embedPendingAudios();
    } catch (e) {
      debugPrint('Error loading audios: $e');
      if (mounted) setState(() => _isLoadingAudios = false);
    }
  }

  Future<void> _embedPendingAudios() async {
    if (AiService.instance.isModelLoaded && _audios.isNotEmpty) {
      final pendingAuds = _audios
          .where((a) => !a.isProcessed && a.embedding == null)
          .toList();
      if (pendingAuds.isNotEmpty) {
        _setLiveProcessing(
          'Audio Text AI: Embedding ${pendingAuds.length} audio files...',
        );
      }
      await AiService.instance.embedAllByText<DeviceAudio>(
        _audios,
        textProvider: (a) => '${a.name} ${a.location}',
        onBatchCompleted: () {
          if (mounted) {
            final done = _audios
                .where((a) => a.isProcessed || a.embedding != null)
                .length;
            _setLiveProcessing(
              'Audio Text AI: $done/${_audios.length} audio files',
            );
            setState(() {});
          }
        },
      );
      _setLiveProcessing(
        'Audio Text AI: All ${_audios.length} audio files embedded',
        autoDismiss: const Duration(seconds: 2),
      );
    }
  }

  void _applyAudioFilters() {
    final q = _searchController.text.trim().toLowerCase();
    List<DeviceAudio> result;
    if (!_hasSubmittedSearch || q.isEmpty) {
      result = List.from(_audios);
      for (var a in result) {
        a.score = null;
      }
    } else {
      result = _audios.where((a) {
        return a.name.toLowerCase().contains(q);
      }).toList();
    }
    _sortAudiosList(result);
    setState(() {
      _filteredAudios = result;
    });
  }

  Future<void> _performAudioSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || !AiService.instance.isModelLoaded) {
      _applyAudioFilters();
      return;
    }

    final currentRequestId = ++_searchRequestId;
    setState(() => _isSearching = true);
    try {
      final ranked = await AiService.instance.search<DeviceAudio>(
        query,
        _audios,
      );
      final lower = query.toLowerCase();
      final isLong = lower.length >= 2;
      final matched = ranked.where((a) {
        final nameMatch = isLong && a.name.toLowerCase().contains(lower);
        final hasAiScore = (a.score ?? 0.0) >= 0.72;
        return nameMatch || hasAiScore;
      }).toList();
      _sortAudiosList(matched);
      if (mounted && currentRequestId == _searchRequestId) {
        setState(() {
          _filteredAudios = matched;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted && currentRequestId == _searchRequestId) {
        setState(() => _isSearching = false);
        _applyAudioFilters();
      }
    }
  }

  Widget _buildAudiosTab() {
    if (_isInitialLoading && _searchController.text.trim().isEmpty) {
      return _buildSearchShimmerGrid();
    }

    if (_filteredAudios.isEmpty) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.search_off_outlined,
                  size: 64,
                  color: Colors.grey.shade400,
                ),
                const SizedBox(height: 12),
                Text(
                  'No audio files match "${_searchController.text}"',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final hasPermissionProblem = _hasDeniedPermissions ||
          _isPermanentlyDenied ||
          _missingPermissions.contains('Audio');

      if (hasPermissionProblem) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.security_outlined,
                  size: 64,
                  color: Colors.orange.shade400,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Audio Access Permission Needed',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF15786C),
                  ),
                  onPressed: _requestMissingPermissions,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Grant Access'),
                ),
              ],
            ),
          ),
        );
      }

      if (_isInitialLoading || _isLoadingAudios) {
        return _buildSearchShimmerGrid();
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.audiotrack_outlined,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 12),
              const Text(
                'No audio files found on device',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Audio recordings, songs, or podcasts saved on your device will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final count = math.min(_audioDisplayLimit, _filteredAudios.length);
    final hasMore = count < _filteredAudios.length;

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        _onTabScroll(3, scrollInfo);
        return false;
      },
      child: RefreshIndicator(
        onRefresh: _loadAllDeviceAudios,
        color: const Color(0xFF15786C),
        child: GridView.builder(
          padding: _getGridPadding(context),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _gridColumns,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.0,
          ),
          itemCount: hasMore ? count + _gridColumns : count,
          itemBuilder: (context, index) {
            if (index >= count) {
              return const _ShimmerCardWidget();
            }
            final aud = _filteredAudios[index];
            final hasScore = aud.score != null;
            final card = _buildAudioCard(aud, hasScore ? index + 1 : null);
            return _PopInCard(
              key: ValueKey('pop_aud_${aud.id}'),
              index: index < 12 ? index : 0,
              child: card,
            );
          },
        ),
      ),
    );
  }

  /// Single Square Audio Card with 50% bottom fader
  Widget _buildAudioCard(DeviceAudio aud, int? rank) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_cardRadius),
            onTap: () => _openMediaFile(aud.path),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      _gridColumns == 4 ? 8 : 14,
                      _gridColumns == 4 ? 8 : 12,
                      _gridColumns == 4 ? 8 : 14,
                      _gridColumns == 4 ? 6 : 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              padding: EdgeInsets.all(_gridColumns == 4 ? 3.5 : 5.5),
                              decoration: BoxDecoration(
                                color: Colors.deepPurple.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.audiotrack,
                                size: _gridColumns == 4 ? 12 : 15,
                                color: Colors.deepPurple.shade700,
                              ),
                            ),
                            const Spacer(),
                            if (_gridColumns <= 2)
                              Text(
                                _formatDate(aud.modifiedDate).split(' ').first,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                          ],
                        ),
                        SizedBox(height: _gridColumns == 4 ? 6 : 10),
                        Text(
                          aud.name,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: _gridColumns == 4 ? 10.5 : (_gridColumns == 3 ? 11.5 : 13),
                            color: const Color(0xFF1E293B),
                          ),
                          maxLines: _gridColumns == 2 ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_gridColumns <= 3) ...[
                          const SizedBox(height: 3),
                          Text(
                            _formatDate(aud.modifiedDate).split(' ').first,
                            style: TextStyle(
                              fontSize: _gridColumns == 3 ? 9.5 : 10.5,
                              color: Colors.grey.shade600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // White Fader directly on the square card covering bottom 50%
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 0.50,
                    widthFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(_cardRadius),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.white,
                            Colors.white.withValues(alpha: 0.95),
                            Colors.white.withValues(alpha: 0.65),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                          stops: const [0.0, 0.35, 0.70, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAudioDetails(DeviceAudio aud, int? rank) {
    if (!File(aud.path).existsSync()) {
      _handleLiveFileDeleted(aud.path);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Audio track was deleted from device storage and removed.'),
          duration: Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple.shade50,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.audiotrack,
                        color: Colors.deepPurple.shade700,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            aud.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Device Audio Track',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(height: 1),
                const SizedBox(height: 12),
                _buildDocDetailRow(Icons.folder_outlined, 'Path', aud.path),
                _buildDocDetailRow(
                  Icons.data_usage,
                  'File Size',
                  '${_formatFileSize(aud.fileSize)} (${aud.fileSize} bytes)',
                ),
                _buildDocDetailRow(
                  Icons.access_time,
                  'Modified',
                  _formatDate(aud.modifiedDate),
                ),
                _buildDocDetailRow(
                  Icons.auto_awesome,
                  'AI Search Status',
                  (aud.isProcessed || aud.embedding != null)
                      ? 'Text Embedding Indexed (${aud.embedding?.length ?? 0}-dim vector)'
                      : 'Pending Text Embedding',
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF15786C),
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: aud.path));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Copied audio path: ${aud.path}'),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy Path'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- APPS TAB & METHODS ---

  bool _isUserFacingApp(DeviceApp app) {
    final pkg = app.packageName.toLowerCase();
    final name = app.name.toLowerCase();

    // 1. Popular 3rd party consumer apps (even if OEM pre-installed into /system or /product partition)
    if (pkg.contains('instagram') || name.contains('instagram')) return true;
    if (pkg.contains('facebook') || name.contains('facebook')) return true;
    if (pkg.contains('whatsapp') || name.contains('whatsapp')) return true;
    if (pkg.contains('netflix') || pkg.contains('spotify') || pkg.contains('youtube')) return true;
    if (pkg.contains('twitter') || pkg.contains('threads') || pkg.contains('tiktok')) return true;
    if (pkg.contains('snapchat') || pkg.contains('telegram') || pkg.contains('linkedin')) return true;
    if (pkg.contains('chrome') || pkg.contains('firefox') || pkg.contains('opera')) return true;
    if (pkg.contains('amazon') || pkg.contains('flipkart') || pkg.contains('reddit')) return true;
    if (pkg.contains('camera') || pkg.contains('gallery') || pkg.contains('photos')) return true;

    // 2. Strict exclusion of internal Android/Qualcomm framework daemons and overlays
    if (pkg.startsWith('android') ||
        pkg.startsWith('com.android.internal') ||
        pkg.startsWith('com.android.server') ||
        pkg.startsWith('com.android.providers') ||
        pkg.startsWith('com.qualcomm') ||
        pkg.startsWith('com.sec.android.app.launcher') ||
        pkg.contains('.overlay') ||
        pkg.contains('.systemui') ||
        name.startsWith('com.') ||
        name.startsWith('android.')) {
      return false;
    }

    // 3. User installed apps are always valid
    if (!app.isSystemApp) return true;

    // 4. For system partition apps, allow user tools with friendly names
    return name.isNotEmpty && !name.contains('Service') && !name.contains('Daemon');
  }

  Future<void> _loadDeviceApps() async {
    setState(() => _isLoadingApps = true);
    try {
      // 1. Instant load from SQLite Database (only user installed apps)
      final cachedApps = await DatabaseService.instance.getAllAppRecords();
      if (cachedApps.isNotEmpty && mounted) {
        final List<DeviceApp> initialApps = cachedApps
            .map((ca) => DeviceApp(
                  name: ca.name,
                  packageName: ca.packageName,
                  version: ca.version,
                  isSystemApp: ca.isSystemApp,
                  category: _inferAppCategory(ca.packageName, ca.isSystemApp),
                ))
            .where((a) => _isUserFacingApp(a))
            .toList();
        setState(() {
          _apps = initialApps;
          _applyAppFilters();
          _updateTimeline();
        });
      }

      final scanAppsEnabled = PreferencesService.instance.isCategoryScanningEnabled('apps');
      if (!scanAppsEnabled) {
        if (mounted) setState(() => _isLoadingApps = false);
        return;
      }

      // 2. Discover from device (only user installed apps)
      final rawApps = await DeviceInfoService.instance.getInstalledApps();
      final seenPackages = <String>{};
      final List<DeviceApp> apps = [];
      for (final a in rawApps) {
        if (_isUserFacingApp(a) && seenPackages.add(a.packageName)) {
          apps.add(a);
        }
      }

      // Save to SQLite DB
      final toSave = apps.map((a) {
        return CachedAppRecord(
          packageName: a.packageName,
          name: a.name,
          version: a.version,
          isSystemApp: a.isSystemApp,
        );
      }).toList();
      await DatabaseService.instance.saveAppBatch(toSave);

      if (mounted) {
        setState(() {
          _apps = apps;
          _isLoadingApps = false;
          _applyAppFilters();
          _updateTimeline();
        });
      }
    } catch (e) {
      debugPrint('Error loading apps: $e');
      if (mounted) setState(() => _isLoadingApps = false);
    }
  }

  void _applyAppFilters() {
    final q = _searchController.text.trim().toLowerCase();
    List<DeviceApp> result = _apps.where((a) => _isUserFacingApp(a)).toList();

    if (_hasSubmittedSearch && q.isNotEmpty) {
      result = result.where((a) => _isAppMatch(a, q)).toList();
    }
    _sortAppsList(result);

    setState(() {
      _filteredApps = result;
    });
  }

  bool _isAppMatch(DeviceApp app, String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return true;

    final name = app.name.toLowerCase();
    final pkg = app.packageName.toLowerCase();

    // 1. Exact match
    if (name == q || pkg == q) return true;

    // Shortcuts & Acronyms
    if (q == 'ig' && (name.contains('instagram') || pkg.contains('instagram'))) return true;
    if (q == 'fb' && (name.contains('facebook') || pkg.contains('facebook'))) return true;
    if (q == 'wa' && (name.contains('whatsapp') || pkg.contains('whatsapp'))) return true;
    if (q == 'yt' && (name.contains('youtube') || pkg.contains('youtube'))) return true;

    // Multi-word queries like "instagram app" or "insta app"
    final queryWords = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    for (final qw in queryWords) {
      if (qw == 'app' || qw == 'apk' || qw == 'application') continue;
      if (name == qw || name.startsWith(qw) || name.contains(qw) || pkg.contains(qw)) return true;
    }

    // 2. Prefix match
    if (name.startsWith(q)) return true;

    // 3. Substring match on name
    if (name.contains(q)) return true;

    // Do not match generic punctuation (like '.') against package names
    final isPurePunctuation = RegExp(r'^[\.\-_\s]+$').hasMatch(q);
    if (!isPurePunctuation && pkg.contains(q)) return true;

    // 4. Word-boundary prefix match (e.g. "in" -> "Instagram")
    final words = name.split(RegExp(r'[\s_\-\.]+'));
    for (final word in words) {
      if (word.startsWith(q)) return true;
    }

    // 5. Subsequence (Fuzzy) Match (e.g. "inagram" -> "Instagram", "fb" -> "Facebook", "yt" -> "YouTube")
    if (_isSubsequence(q, name)) {
      return true;
    }
    if (!isPurePunctuation && _isSubsequence(q, pkg)) {
      return true;
    }

    // 6. Typo / Levenshtein Distance Match (for queries with at least 3 chars)
    if (q.length >= 3) {
      for (final word in words) {
        if (_fuzzyDistance(q, word) <= 2) return true;
        if (word.length >= q.length &&
            _fuzzyDistance(q, word.substring(0, q.length)) <= 1) {
          return true;
        }
      }
      if ((name.length - q.length).abs() <= 3 && _fuzzyDistance(q, name) <= 2) {
        return true;
      }
    }

    // 7. Anagram / Letter-multiset match (e.g. all query letters in app name)
    if (q.length >= 4 && _isCharSubset(q, name)) {
      return true;
    }

    return false;
  }

  double _scoreAppMatch(DeviceApp app, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return 0.0;
    final name = app.name.toLowerCase();
    final pkg = app.packageName.toLowerCase();

    // 1. Exact match
    if (name == q) return 1.0;

    // Popular app shortcuts
    if (q == 'ig' && (name.contains('instagram') || pkg.contains('instagram'))) return 0.98;
    if (q == 'fb' && (name.contains('facebook') || pkg.contains('facebook'))) return 0.98;
    if (q == 'wa' && (name.contains('whatsapp') || pkg.contains('whatsapp'))) return 0.98;
    if (q == 'yt' && (name.contains('youtube') || pkg.contains('youtube'))) return 0.98;

    // Multi-word queries like "instagram app"
    final queryWords = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    for (final qw in queryWords) {
      if (qw == 'app' || qw == 'apk' || qw == 'application') continue;
      if (name == qw) return 0.98;
      if (name.startsWith(qw)) return 0.94;
      if (name.contains(qw)) return 0.88;
    }

    // 2. Prefix match (e.g. "insta" -> "Instagram")
    if (name.startsWith(q)) return 0.95;

    // 3. Word-boundary prefix match
    final words = name.split(RegExp(r'[\s_\-\.]+'));
    for (final word in words) {
      if (word.startsWith(q)) return 0.92;
    }

    // 4. Substring match
    if (name.contains(q)) return 0.88;

    final isPurePunctuation = RegExp(r'^[\.\-_\s]+$').hasMatch(q);
    if (pkg == q) return 0.85;
    if (!isPurePunctuation && pkg.startsWith(q)) return 0.75;
    if (!isPurePunctuation && pkg.contains(q)) return 0.65;
    if (_isSubsequence(q, name)) return 0.60;
    if (!isPurePunctuation && _isSubsequence(q, pkg)) return 0.50;
    if (q.length >= 3 && _fuzzyDistance(q, name) <= 2) return 0.55;
    if (q.length >= 4 && _isCharSubset(q, name)) return 0.50;
    return 0.30;
  }

  bool _isSubsequence(String query, String target) {
    if (query.isEmpty) return true;
    if (target.isEmpty) return false;
    int qIdx = 0;
    for (int tIdx = 0; tIdx < target.length; tIdx++) {
      if (query[qIdx] == target[tIdx]) {
        qIdx++;
        if (qIdx == query.length) return true;
      }
    }
    return false;
  }

  int _fuzzyDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    List<int> prev = List.generate(b.length + 1, (i) => i);
    List<int> curr = List.filled(b.length + 1, 0);

    for (int i = 0; i < a.length; i++) {
      curr[0] = i + 1;
      for (int j = 0; j < b.length; j++) {
        final cost = (a[i] == b[j]) ? 0 : 1;
        curr[j + 1] = math.min(
          curr[j] + 1,
          math.min(prev[j + 1] + 1, prev[j] + cost),
        );
      }
      final temp = prev;
      prev = curr;
      curr = temp;
    }
    return prev[b.length];
  }

  bool _isCharSubset(String query, String target) {
    final Map<int, int> qCounts = {};
    for (final code in query.codeUnits) {
      if (code >= 97 && code <= 122) {
        qCounts[code] = (qCounts[code] ?? 0) + 1;
      }
    }
    final Map<int, int> tCounts = {};
    for (final code in target.codeUnits) {
      tCounts[code] = (tCounts[code] ?? 0) + 1;
    }
    for (final entry in qCounts.entries) {
      if ((tCounts[entry.key] ?? 0) < entry.value) {
        return false;
      }
    }
    return true;
  }

  Widget _buildAppsTab() {
    if (_isInitialLoading && _searchController.text.trim().isEmpty) {
      return _buildSearchShimmerGrid();
    }

    return RefreshIndicator(
      onRefresh: _loadDeviceApps,
      color: const Color(0xFF15786C),
      child: ((_isInitialLoading || _isLoadingApps) &&
              _filteredApps.isEmpty &&
              _searchController.text.isEmpty)
          ? _buildSearchShimmerGrid()
          : _filteredApps.isEmpty
              ? SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.apps_outlined,
                              size: 64,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _hasSubmittedSearch && _searchController.text.isNotEmpty
                                  ? 'No applications match "${_searchController.text}"'
                                  : 'No installed applications found.',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _loadDeviceApps,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('Refresh Apps'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: (scrollInfo) {
                    _onTabScroll(5, scrollInfo);
                    return false;
                  },
                  child: GridView.builder(
                    padding: _getGridPadding(context),
                    gridDelegate:
                        SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gridColumns,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 1.0,
                    ),
                    itemCount: math.min(_appDisplayLimit, _filteredApps.length) < _filteredApps.length
                        ? math.min(_appDisplayLimit, _filteredApps.length) + _gridColumns
                        : math.min(_appDisplayLimit, _filteredApps.length),
                    itemBuilder: (context, index) {
                      final displayCount = math.min(_appDisplayLimit, _filteredApps.length);
                      if (index >= displayCount) {
                        return const _ShimmerCardWidget();
                      }
                      final app = _filteredApps[index];
                      return _PopInCard(
                        key: ValueKey('pop_app_${app.packageName}'),
                        index: index < 12 ? index : 0,
                        child: _buildAppCard(app),
                      );
                    },
                  ),
                ),
    );
  }

  /// Single Square App Card with real logo, app name, and category
  Widget _buildAppCard(DeviceApp app) {
    const appColor = Color(0xFF15786C);
    final appBg = const Color(0xFF15786C).withValues(alpha: 0.10);

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_cardRadius),
            onTap: () => DeviceInfoService.instance.openApp(app.packageName),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                _gridColumns == 4 ? 8 : 14,
                _gridColumns == 4 ? 8 : 14,
                _gridColumns == 4 ? 8 : 14,
                _gridColumns == 4 ? 6 : 12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      AppIconWidget(
                        packageName: app.packageName,
                        size: _gridColumns == 4 ? 30 : (_gridColumns == 3 ? 36 : 42),
                        fallbackColor: appColor,
                        fallbackBg: appBg,
                      ),
                      const Spacer(),
                      if (_gridColumns <= 3)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3.5,
                          ),
                          decoration: BoxDecoration(
                            color: appBg,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'Installed',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: appColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    app.name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: _gridColumns == 4 ? 10.5 : (_gridColumns == 3 ? 11.5 : 13.5),
                      color: const Color(0xFF1E293B),
                      height: 1.2,
                    ),
                    maxLines: _gridColumns == 2 ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_gridColumns <= 3) ...[
                    const SizedBox(height: 3),
                    Text(
                      app.category,
                      style: TextStyle(
                        fontSize: _gridColumns == 3 ? 9.5 : 11,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showAppDetails(DeviceApp app) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: app.isSystemApp
                          ? Colors.orange.shade100
                          : const Color(0xFF15786C).withValues(alpha: 0.15),
                      child: Text(
                        app.name.isNotEmpty ? app.name[0].toUpperCase() : 'A',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                          color: app.isSystemApp
                              ? Colors.orange.shade800
                              : const Color(0xFF15786C),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            app.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            app.isSystemApp
                                ? 'System Application'
                                : 'User Installed Application',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                _buildDocDetailRow(Icons.tag, 'Package Name', app.packageName),
                _buildDocDetailRow(
                  Icons.numbers,
                  'Version',
                  app.version.isNotEmpty ? app.version : 'Unknown',
                ),
                _buildDocDetailRow(
                  Icons.security,
                  'Type',
                  app.isSystemApp
                      ? 'System / Pre-installed'
                      : 'Third-Party / User Installed',
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF15786C),
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: app.packageName));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Copied package name: ${app.packageName}',
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy Package'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- CONTACTS TAB & METHODS ---

  Future<void> _loadDeviceContacts({bool forceRescan = false}) async {
    setState(() => _isLoadingContacts = true);
    try {
      // 1. Instant load from SQLite Database
      final cachedContacts = await DatabaseService.instance.getAllContactRecords();
      if (cachedContacts.isNotEmpty && mounted) {
        final List<DeviceContact> initialContacts = cachedContacts.map((cc) {
          return DeviceContact(
            id: cc.id,
            name: cc.name,
            number: cc.number,
          );
        }).toList();
        setState(() {
          _contacts = initialContacts;
          _applyContactFilters();
          _updateTimeline();
        });

        if (!forceRescan) {
          if (mounted) setState(() => _isLoadingContacts = false);
          return;
        }
      }

      final scanContactsEnabled = PreferencesService.instance.isCategoryScanningEnabled('contacts');
      if (!scanContactsEnabled) {
        if (mounted) setState(() => _isLoadingContacts = false);
        return;
      }

      // 2. Discover from device
      final rawContacts = await DeviceInfoService.instance.getContacts();
      final uniqueContacts = DuplicateRemoverService.instance
          .removeDuplicateContacts(rawContacts);

      // Save to SQLite DB
      final toSave = uniqueContacts.map((c) {
        return CachedContactRecord(
          id: c.id,
          name: c.name,
          number: c.number,
        );
      }).toList();
      await DatabaseService.instance.saveContactBatch(toSave);

      if (mounted) {
        setState(() {
          _contacts = uniqueContacts;
          _isLoadingContacts = false;
          _applyContactFilters();
          _updateTimeline();
        });
      }
    } catch (e) {
      debugPrint('Error loading contacts: $e');
      if (mounted) setState(() => _isLoadingContacts = false);
    }
  }

  void _applyContactFilters() {
    final q = _searchController.text.trim().toLowerCase();
    final base = (!_hasSubmittedSearch || q.isEmpty)
        ? _contacts
        : _contacts.where((c) {
            return c.name.toLowerCase().contains(q) ||
                c.number.toLowerCase().contains(q);
          }).toList();

    final deduped = DuplicateRemoverService.instance.removeDuplicateContacts(
      base,
    );
    _sortContactsList(deduped);
    setState(() => _filteredContacts = deduped);
  }

  Widget _buildContactsTab() {
    if (_isInitialLoading && _searchController.text.trim().isEmpty) {
      return _buildSearchShimmerGrid();
    }

    if (_filteredContacts.isEmpty) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.search_off_outlined,
                  size: 64,
                  color: Colors.grey.shade400,
                ),
                const SizedBox(height: 12),
                Text(
                  'No contacts match "${_searchController.text}"',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final isPermMissing = _missingPermissions.contains('Contacts');
      if (isPermMissing) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.security_outlined,
                  size: 64,
                  color: Colors.orange.shade400,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Contacts Permission Needed',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Allow Pipit to access your contacts to view and search them.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF15786C),
                  ),
                  onPressed: _requestMissingPermissions,
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('Allow Contacts Access'),
                ),
              ],
            ),
          ),
        );
      }

      if (_isInitialLoading || _isLoadingContacts) {
        return _buildSearchShimmerGrid();
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.contacts_outlined,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 12),
              const Text(
                'No contacts found on device',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Contacts stored on your device or Google account will be listed here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final count = math.min(_contactDisplayLimit, _filteredContacts.length);
    final hasMore = count < _filteredContacts.length;

    return RefreshIndicator(
      onRefresh: _loadDeviceContacts,
      color: const Color(0xFF15786C),
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          _onTabScroll(6, scrollInfo);
          return false;
        },
        child: GridView.builder(
          padding: _getGridPadding(context),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _gridColumns,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.0,
          ),
          itemCount: hasMore ? count + _gridColumns : count,
          itemBuilder: (context, index) {
            if (index >= count) {
              return const _ShimmerCardWidget();
            }
            final contact = _filteredContacts[index];
            return _PopInCard(
              key: ValueKey('pop_contact_${contact.id}'),
              index: index < 12 ? index : 0,
              child: _buildContactCard(contact),
            );
          },
        ),
      ),
    );
  }

  /// Single Square Contact Card with 50% bottom fader
  Widget _buildContactCard(DeviceContact contact) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_cardRadius),
            onTap: () => DeviceInfoService.instance.openContact(number: contact.number),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      _gridColumns == 4 ? 8 : 14,
                      _gridColumns == 4 ? 8 : 12,
                      _gridColumns == 4 ? 8 : 14,
                      _gridColumns == 4 ? 6 : 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              padding: EdgeInsets.all(_gridColumns == 4 ? 3.5 : 5.5),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF15786C,
                                ).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.person,
                                size: _gridColumns == 4 ? 12 : 15,
                                color: const Color(0xFF15786C),
                              ),
                            ),
                            const Spacer(),
                            if (_gridColumns <= 3)
                              IconButton(
                                icon: const Icon(
                                  Icons.copy,
                                  size: 14,
                                  color: Color(0xFF15786C),
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                tooltip: 'Copy Number',
                                onPressed: () {
                                  Clipboard.setData(
                                    ClipboardData(text: contact.number),
                                  );
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Copied ${contact.number}'),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                        SizedBox(height: _gridColumns == 4 ? 6 : 10),
                        Text(
                          contact.name,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: _gridColumns == 4 ? 10.5 : (_gridColumns == 3 ? 11.5 : 13),
                            color: const Color(0xFF1E293B),
                          ),
                          maxLines: _gridColumns == 2 ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_gridColumns <= 3) ...[
                          const SizedBox(height: 3),
                          Text(
                            contact.number.isNotEmpty
                                ? contact.number
                                : 'No number',
                            style: TextStyle(
                              fontSize: _gridColumns == 3 ? 9.5 : 11,
                              color: Colors.grey.shade600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // White Fader directly on card covering bottom 50%
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 0.50,
                    widthFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(_cardRadius),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.white,
                            Colors.white.withValues(alpha: 0.95),
                            Colors.white.withValues(alpha: 0.65),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                          stops: const [0.0, 0.35, 0.70, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showContactDetails(DeviceContact contact) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: const Color(
                        0xFF15786C,
                      ).withValues(alpha: 0.15),
                      child: Text(
                        contact.name.isNotEmpty
                            ? contact.name[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                          color: Color(0xFF15786C),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            contact.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            contact.number,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                _buildDocDetailRow(Icons.person_outline, 'Name', contact.name),
                _buildDocDetailRow(
                  Icons.phone_outlined,
                  'Phone',
                  contact.number,
                ),
                _buildDocDetailRow(Icons.tag, 'Contact ID', contact.id),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF15786C),
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: contact.number));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Copied ${contact.number}')),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy Number'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- SMS TAB & METHODS ---

  Future<void> _loadDeviceSms({bool forceRescan = false}) async {
    setState(() => _isLoadingSms = true);
    try {
      // 1. Instant load from SQLite Database
      final cachedSms = await DatabaseService.instance.getAllSmsRecords();
      if (cachedSms.isNotEmpty && mounted) {
        final List<DeviceSms> initialSms = cachedSms.map((cs) {
          return DeviceSms(
            id: cs.id,
            address: cs.address,
            body: cs.body,
            date: DateTime.fromMillisecondsSinceEpoch(cs.dateTimestamp),
            type: cs.type,
            isProcessed: cs.isProcessed,
          );
        }).toList();
        setState(() {
          _smsList = initialSms;
          _applySmsFilters();
          _updateTimeline();
        });

        if (!forceRescan) {
          if (mounted) setState(() => _isLoadingSms = false);
          return;
        }
      }

      final scanSmsEnabled = PreferencesService.instance.isCategoryScanningEnabled('sms');
      if (!scanSmsEnabled) {
        if (mounted) setState(() => _isLoadingSms = false);
        return;
      }

      // 2. Discover from device
      final rawSms = await DeviceInfoService.instance.getSms();
      final sms = DuplicateRemoverService.instance.removeDuplicateSms(rawSms);

      final cachedMap = {for (final cs in cachedSms) cs.id: cs};

      // Save to SQLite DB
      final toSave = sms.map((s) {
        final existing = cachedMap[s.id];
        final bool isAlreadyProcessed = existing?.isProcessed ?? true;
        return CachedSmsRecord(
          id: s.id,
          address: s.address,
          body: s.body,
          dateTimestamp: s.date.millisecondsSinceEpoch,
          type: s.type,
          isProcessed: isAlreadyProcessed,
        );
      }).toList();
      await DatabaseService.instance.saveSmsBatch(toSave);

      if (mounted) {
        setState(() {
          _smsList = sms.map((s) {
            final existing = cachedMap[s.id];
            return DeviceSms(
              id: s.id,
              address: s.address,
              body: s.body,
              date: s.date,
              type: s.type,
              isProcessed: existing?.isProcessed ?? true,
            );
          }).toList();
          _isLoadingSms = false;
          _applySmsFilters();
          _updateTimeline();
        });
      }
    } catch (e) {
      debugPrint('Error loading SMS: $e');
      if (mounted) setState(() => _isLoadingSms = false);
    }
  }

  void _applySmsFilters() {
    final q = _searchController.text.trim().toLowerCase();
    List<DeviceSms> result;
    if (!_hasSubmittedSearch || q.isEmpty) {
      result = List.from(_smsList);
    } else {
      final matched = _smsList.where((s) {
        return s.address.toLowerCase().contains(q) ||
            s.body.toLowerCase().contains(q) ||
            s.type.toLowerCase().contains(q);
      }).toList();

      // Deduplicate by sender address when searching so a contact doesn't appear dozens of times with different timestamps
      result = DuplicateRemoverService.instance.removeDuplicateSms(
        matched,
      );
    }
    _sortSmsList(result);
    setState(() {
      _filteredSms = result;
    });
  }

  Widget _buildSmsTab() {
    if (_isInitialLoading && _searchController.text.trim().isEmpty) {
      return _buildSearchShimmerGrid();
    }

    if (_filteredSms.isEmpty) {
      if (_hasSubmittedSearch && _searchController.text.isNotEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.search_off_outlined,
                  size: 64,
                  color: Colors.grey.shade400,
                ),
                const SizedBox(height: 12),
                Text(
                  'No SMS matches "${_searchController.text}"',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      }

      final isPermMissing = _missingPermissions.contains('SMS');
      if (isPermMissing) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.security_outlined,
                  size: 64,
                  color: Colors.orange.shade400,
                ),
                const SizedBox(height: 12),
                const Text(
                  'SMS Permission Needed',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Allow Pipit to access your SMS messages to view and search them.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF15786C),
                  ),
                  onPressed: _requestMissingPermissions,
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('Allow SMS Access'),
                ),
              ],
            ),
          ),
        );
      }

      if (_isInitialLoading || _isLoadingSms) {
        return _buildSearchShimmerGrid();
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.sms_outlined,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 12),
              const Text(
                'No SMS messages found on device',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Text messages received on your device will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final count = math.min(_smsDisplayLimit, _filteredSms.length);
    final hasMore = count < _filteredSms.length;

    return RefreshIndicator(
      onRefresh: () => _loadDeviceSms(forceRescan: true),
      color: const Color(0xFF15786C),
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          _onTabScroll(7, scrollInfo);
          return false;
        },
        child: GridView.builder(
          padding: _getGridPadding(context),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _gridColumns,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.0,
          ),
          itemCount: hasMore ? count + _gridColumns : count,
          itemBuilder: (context, index) {
            if (index >= count) {
              return const _ShimmerCardWidget();
            }
            final sms = _filteredSms[index];
            final card = _buildTextContentCard(
              title: sms.address,
              textContent: sms.body,
              typeLabel: sms.type,
              typeColor: sms.type == 'Sent'
                  ? const Color(0xFF1E88E5)
                  : const Color(0xFF15786C),
              typeIcon: sms.type == 'Sent' ? Icons.outbox : Icons.inbox,
              subtitle: '${sms.type} Message',
              timestamp: sms.date,
              onTap: () => DeviceInfoService.instance.openSms(address: sms.address, body: sms.body),
            );
            return _PopInCard(
              key: ValueKey('pop_sms_${sms.id}'),
              index: index < 12 ? index : 0,
              child: card,
            );
          },
        ),
      ),
    );
  }

  void _showSmsDetails(DeviceSms sms) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(23)),
        title: Row(
          children: [
            Icon(Icons.sms, color: const Color(0xFF15786C), size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                sms.address,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${sms.type} • ${_formatDate(sms.date)}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 250),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  sms.body,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy Message'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: sms.body));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied SMS text to clipboard')),
              );
            },
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF15786C),
            ),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _AnimatedSearchHint extends StatefulWidget {
  final TextStyle staticStyle;
  final TextStyle animatedStyle;

  const _AnimatedSearchHint({
    required this.staticStyle,
    required this.animatedStyle,
  });

  @override
  State<_AnimatedSearchHint> createState() => _AnimatedSearchHintState();
}

class _AnimatedSearchHintState extends State<_AnimatedSearchHint> {
  List<String> _suggestions = const [
    'dog',
    'cat',
    'receipt',
    'invoice',
    'passport',
  ];
  int _suggestionIndex = 0;
  int _charIndex = 0;
  bool _isDeleting = false;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
    _startTypingLoop();
  }

  Future<void> _loadSuggestions() async {
    try {
      final jsonString = await rootBundle.loadString(
        'assets/search_suggestions.json',
      );
      final dynamic decoded = jsonDecode(jsonString);
      if (decoded is List && decoded.isNotEmpty) {
        final list = decoded.map((e) => e.toString()).toList();
        if (mounted) {
          setState(() {
            _suggestions = list;
            if (_suggestionIndex >= _suggestions.length) {
              _suggestionIndex = 0;
            }
          });
        }
      }
    } catch (_) {}
  }

  void _startTypingLoop() {
    _typingTimer?.cancel();
    if (_suggestions.isEmpty) return;
    final currentWord = _suggestions[_suggestionIndex];

    if (!_isDeleting) {
      if (_charIndex < currentWord.length) {
        _charIndex++;
        if (mounted) setState(() {});
        _typingTimer = Timer(
          const Duration(milliseconds: 90),
          _startTypingLoop,
        );
      } else {
        // Full word typed, pause so user can read it
        _typingTimer = Timer(const Duration(milliseconds: 1400), () {
          _isDeleting = true;
          _startTypingLoop();
        });
      }
    } else {
      if (_charIndex > 0) {
        _charIndex--;
        if (mounted) setState(() {});
        _typingTimer = Timer(
          const Duration(milliseconds: 45),
          _startTypingLoop,
        );
      } else {
        // Finished deleting, move to next suggestion
        _isDeleting = false;
        _suggestionIndex = (_suggestionIndex + 1) % _suggestions.length;
        _typingTimer = Timer(
          const Duration(milliseconds: 250),
          _startTypingLoop,
        );
      }
    }
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_suggestions.isEmpty) return const SizedBox.shrink();
    final currentWord = _suggestions[_suggestionIndex];
    final displayedText = _charIndex <= currentWord.length
        ? currentWord.substring(0, _charIndex)
        : currentWord;

    return IgnorePointer(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('Search for ', style: widget.staticStyle),
          Text(displayedText, style: widget.animatedStyle),
        ],
      ),
    );
  }
}

class _ShimmerCardWidget extends StatefulWidget {
  const _ShimmerCardWidget();

  @override
  State<_ShimmerCardWidget> createState() => _ShimmerCardWidgetState();
}

class _ShimmerCardWidgetState extends State<_ShimmerCardWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final shimmerValue = _controller.value;
        return Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(23),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          color: Color.lerp(
            Colors.grey.shade100,
            Colors.grey.shade200,
            shimmerValue,
          ),
          child: AspectRatio(
            aspectRatio: 1.0,
            child: Stack(
              children: [
                Positioned(
                  top: 12,
                  left: 14,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 24,
                  left: 14,
                  right: 36,
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 10,
                  left: 14,
                  width: 60,
                  child: Container(
                    height: 9,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PopInCard extends StatefulWidget {
  final Widget child;
  final int index;

  const _PopInCard({super.key, required this.child, this.index = 0});

  @override
  State<_PopInCard> createState() => _PopInCardState();
}

class _PopInCardState extends State<_PopInCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _shimmerSweep;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
    );

    _scaleAnimation = Tween<double>(
      begin: 0.84,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.65, curve: Curves.easeOut),
    ));

    _shimmerSweep = Tween<double>(
      begin: -1.0,
      end: 2.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    final delayMs = math.min(widget.index * 35, 320);
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final sweepVal = _shimmerSweep.value;
        return FadeTransition(
          opacity: _fadeAnimation,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: Stack(
              children: [
                widget.child,
                // Shimmer sweep flash while popping in
                if (_controller.value < 0.98)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(23),
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment(sweepVal - 1.0, -1.0),
                              end: Alignment(sweepVal + 1.0, 1.0),
                              colors: [
                                Colors.transparent,
                                Colors.white.withValues(alpha: 0.35),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.5, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Animated Top Bar Logo with smooth pop-in entrance and shimmer sweep highlight
class _TopBarLogo extends StatefulWidget {
  const _TopBarLogo();

  @override
  State<_TopBarLogo> createState() => _TopBarLogoState();
}

class _TopBarLogoState extends State<_TopBarLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _shimmerAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    );

    // Smooth bouncy pop-in
    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.7, curve: Curves.easeOutBack),
      ),
    );

    // Fade in
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );

    // Shimmer sweep across the bird logo right as it lands
    _shimmerAnimation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 1.0, curve: Curves.easeInOutCubic),
      ),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final shimmerVal = _shimmerAnimation.value;
        return FadeTransition(
          opacity: _fadeAnimation,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: GestureDetector(
              onTap: () {
                // Interactive micro-bounce when tapped
                _controller.forward(from: 0.3);
              },
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      'assets/iamges/logo.png',
                      height: 32,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                  if (shimmerVal > -0.9 && shimmerVal < 1.9)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment(shimmerVal - 1.0, -1.0),
                                end: Alignment(shimmerVal + 1.0, 1.0),
                                colors: [
                                  Colors.transparent,
                                  Colors.white.withValues(alpha: 0.4),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.5, 1.0],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Animated Search Bar wrapper with a fast, rubbery "sunrise" entrance animation (slides down to up)
class _SunriseSearchBar extends StatefulWidget {
  final Widget child;

  const _SunriseSearchBar({required this.child});

  @override
  State<_SunriseSearchBar> createState() => _SunriseSearchBarState();
}

class _SunriseSearchBarState extends State<_SunriseSearchBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );

    // Rubbery spring overshoot curve (overshoots by ~10% like a rubber band and snaps into rest)
    const rubberyCurve = Cubic(0.34, 1.56, 0.64, 1.0);

    // Rises from below the screen (down to up, like a sunrise)
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.0, 1.45),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: rubberyCurve));

    // Rubbery scale pop
    _scaleAnimation = Tween<double>(
      begin: 0.88,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: rubberyCurve));

    // Fast fade-in
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    ));

    // Slight micro-delay so the screen view settles before the sunrise bounce
    Future.delayed(const Duration(milliseconds: 70), () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Animated moving glow with dynamic intensity and randomized shimmer around the search bar
class _AnimatedSearchGlow extends StatefulWidget {
  final Widget child;
  final bool hasActiveSearch;
  final bool isSearching;
  final int searchEpoch;

  const _AnimatedSearchGlow({
    super.key,
    required this.child,
    required this.hasActiveSearch,
    required this.isSearching,
    required this.searchEpoch,
  });

  @override
  State<_AnimatedSearchGlow> createState() => _AnimatedSearchGlowState();
}

class _AnimatedSearchGlowState extends State<_AnimatedSearchGlow>
    with TickerProviderStateMixin {
  late final AnimationController _rotationController;
  late final AnimationController _pulseController;
  Timer? _burstTimer;
  bool _isBursting = false;
  double _randomSeedOffset = 0.0;
  final math.Random _random = math.Random();

  @override
  void initState() {
    super.initState();
    // Continuous rotation for always-moving perimeter sweep (3.8 seconds per complete cycle)
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3800),
    )..repeat();

    // Harmonic pulse controller for organic breathing & dynamic flaring
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);

    if (widget.hasActiveSearch || widget.searchEpoch > 0) {
      _triggerPostSearchBurst();
    }
  }

  void _triggerPostSearchBurst() {
    _burstTimer?.cancel();
    setState(() {
      _isBursting = true;
      _randomSeedOffset = _random.nextDouble() * 12.0;
    });
    // Post-search heightened energy burst lasts 5 seconds before settling into active search mode
    _burstTimer = Timer(const Duration(milliseconds: 5000), () {
      if (mounted) {
        setState(() {
          _isBursting = false;
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant _AnimatedSearchGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchEpoch != oldWidget.searchEpoch && widget.searchEpoch > 0) {
      _triggerPostSearchBurst();
    } else if (oldWidget.isSearching && !widget.isSearching && widget.hasActiveSearch) {
      _triggerPostSearchBurst();
    } else if (!widget.hasActiveSearch && oldWidget.hasActiveSearch) {
      _burstTimer?.cancel();
      _isBursting = false;
    }
  }

  @override
  void dispose() {
    _burstTimer?.cancel();
    _rotationController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_rotationController, _pulseController]),
      builder: (context, _) {
        final rotation = _rotationController.value;
        final pulse = _pulseController.value;

        // Multi-frequency harmonic wave generates organic, random-like natural flaring
        final t = (pulse * 2 * math.pi) + _randomSeedOffset;
        final harmonicNoise = 0.5 +
            0.26 * math.sin(t * 2.3 + 0.7) +
            0.15 * math.sin(t * 5.1 + 2.1) +
            0.09 * math.cos(t * 7.9 + 1.2);

        final bool isActive =
            widget.hasActiveSearch || widget.isSearching || _isBursting;

        final double intensity;
        final double blurRadius;
        final double spreadRadius;

        if (widget.isSearching) {
          // Peak search processing: vibrant active random breathing
          intensity = (0.78 + 0.22 * harmonicNoise).clamp(0.0, 1.0);
          blurRadius = 24.0 + 12.0 * harmonicNoise;
          spreadRadius = 3.0 + 3.0 * harmonicNoise;
        } else if (_isBursting) {
          // Fresh post-search burst: heightened energetic flare that randomly shimmers
          intensity = (0.72 + 0.28 * harmonicNoise).clamp(0.0, 1.0);
          blurRadius = 22.0 + 14.0 * harmonicNoise;
          spreadRadius = 2.5 + 3.5 * harmonicNoise;
        } else if (widget.hasActiveSearch) {
          // Sustained search active: clear elevated glow with subtle random modulation
          intensity = (0.50 + 0.28 * harmonicNoise).clamp(0.0, 1.0);
          blurRadius = 18.0 + 10.0 * harmonicNoise;
          spreadRadius = 1.5 + 2.5 * harmonicNoise;
        } else {
          // Ambient idle: calm, elegant always-moving subtle aura
          intensity = (0.24 + 0.10 * math.sin(pulse * 2 * math.pi)).clamp(0.0, 1.0);
          blurRadius = 12.0 + 4.0 * math.sin(pulse * 2 * math.pi);
          spreadRadius = 1.0;
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // 1. Background Aura Glow (spreads outward behind search bar)
            Positioned.fill(
              child: CustomPaint(
                painter: _SearchAuraGlowPainter(
                  rotationValue: rotation,
                  intensity: intensity,
                  blurRadius: blurRadius,
                  spreadRadius: spreadRadius,
                  isActive: isActive,
                ),
              ),
            ),
            // 2. The Search Bar Island
            widget.child,
          ],
        );
      },
    );
  }
}

class _SearchAuraGlowPainter extends CustomPainter {
  final double rotationValue;
  final double intensity;
  final double blurRadius;
  final double spreadRadius;
  final bool isActive;

  _SearchAuraGlowPainter({
    required this.rotationValue,
    required this.intensity,
    required this.blurRadius,
    required this.spreadRadius,
    required this.isActive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = Offset.zero & size;
    final angle = rotationValue * 2 * math.pi;

    final sweepGradient = SweepGradient(
      center: Alignment.center,
      startAngle: 0.0,
      endAngle: 2 * math.pi,
      transform: GradientRotation(angle),
      colors: [
        const Color(0xFF15786C).withValues(alpha: (intensity * 0.90).clamp(0.0, 1.0)),
        const Color(0xFF10B981).withValues(alpha: (intensity * 0.95).clamp(0.0, 1.0)),
        const Color(0xFF06B6D4).withValues(alpha: (intensity * 1.00).clamp(0.0, 1.0)),
        const Color(0xFF34D399).withValues(alpha: (intensity * 0.95).clamp(0.0, 1.0)),
        const Color(0xFF2DD4BF).withValues(alpha: (intensity * 0.90).clamp(0.0, 1.0)),
        const Color(0xFF15786C).withValues(alpha: (intensity * 0.90).clamp(0.0, 1.0)),
      ],
      stops: const [0.0, 0.22, 0.45, 0.68, 0.88, 1.0],
    );

    final glowRRect = RRect.fromRectAndRadius(
      rect.inflate(spreadRadius),
      Radius.circular((size.height / 2) + spreadRadius),
    );

    final glowPaint = Paint()
      ..shader = sweepGradient.createShader(rect)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurRadius);

    canvas.drawRRect(glowRRect, glowPaint);
  }

  @override
  bool shouldRepaint(covariant _SearchAuraGlowPainter oldDelegate) {
    return oldDelegate.rotationValue != rotationValue ||
        oldDelegate.intensity != intensity ||
        oldDelegate.blurRadius != blurRadius ||
        oldDelegate.spreadRadius != spreadRadius;
  }
}

/// Ultra-modern bottom sheet enabling users to drag & rearrange Home tabs directly.
/// The 'All' tab remains permanently pinned at position #1 ("same space"),
/// while other active categories can be rearranged via long-press drag or drag handle.
class _HomeTabRearrangeSheet extends StatefulWidget {
  final VoidCallback onReorderCompleted;

  const _HomeTabRearrangeSheet({
    required this.onReorderCompleted,
  });

  @override
  State<_HomeTabRearrangeSheet> createState() => _HomeTabRearrangeSheetState();
}

class _HomeTabRearrangeSheetState extends State<_HomeTabRearrangeSheet> {
  late List<String> _categoryOrder;

  static const Map<String, ({String title, String asset, IconData icon})> _cats = {
    'photos': (title: 'Photos', asset: 'assets/iamges/images.png', icon: Icons.photo_library_outlined),
    'videos': (title: 'Videos', asset: 'assets/iamges/video.png', icon: Icons.videocam_outlined),
    'audio': (title: 'Audio', asset: 'assets/iamges/music.png', icon: Icons.audiotrack_outlined),
    'documents': (title: 'Documents', asset: 'assets/iamges/documents.png', icon: Icons.description_outlined),
    'apps': (title: 'Apps', asset: 'assets/iamges/apps.png', icon: Icons.apps_rounded),
    'contacts': (title: 'Contacts', asset: 'assets/iamges/contacts.png', icon: Icons.contacts_outlined),
    'sms': (title: 'SMS', asset: 'assets/iamges/message.png', icon: Icons.sms_outlined),
  };

  @override
  void initState() {
    super.initState();
    _categoryOrder = List<String>.from(PreferencesService.instance.categoryOrder);
  }

  Future<void> _handleReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (oldIndex == newIndex) return;

    HapticFeedback.mediumImpact();
    setState(() {
      final moved = _categoryOrder.removeAt(oldIndex);
      _categoryOrder.insert(newIndex, moved);
    });

    await PreferencesService.instance.setCategoryOrder(_categoryOrder);
    widget.onReorderCompleted();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = PreferencesService.instance;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        14,
        20,
        MediaQuery.paddingOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle pill at top of sheet
          Center(
            child: Container(
              width: 42,
              height: 4.5,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Title row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Rearrange Home Tabs',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                      letterSpacing: -0.3,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Long press and drag items to reorder your tabs',
                    style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 22, color: Color(0xFF64748B)),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Pinned 'All' item ("make the all at same space")
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF15786C).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Image.asset(
                    'assets/iamges/all.png',
                    width: 24,
                    height: 24,
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.auto_awesome_motion_outlined,
                      size: 20,
                      color: Color(0xFF15786C),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'All (Universal Feed)',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          SizedBox(width: 6),
                          Icon(Icons.lock_outline_rounded, size: 13, color: Color(0xFF64748B)),
                        ],
                      ),
                      Text(
                        'Always pinned in first position',
                        style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF15786C),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Fixed #1',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Reorderable list of categories
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              physics: const BouncingScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: _categoryOrder.length,
              onReorder: _handleReorder,
              proxyDecorator: (Widget child, int index, Animation<double> animation) {
                return AnimatedBuilder(
                  animation: animation,
                  builder: (BuildContext context, Widget? child) {
                    return Material(
                      elevation: 6,
                      color: Colors.white,
                      shadowColor: const Color(0xFF15786C).withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(14),
                      child: child,
                    );
                  },
                  child: child,
                );
              },
              itemBuilder: (context, index) {
                final catKey = _categoryOrder[index];
                final meta = _cats[catKey] ?? (title: catKey, asset: 'assets/iamges/images.png', icon: Icons.folder_outlined);
                final isEnabled = prefs.isCategoryScanningEnabled(catKey);

                return ReorderableDelayedDragStartListener(
                  key: ValueKey('sheet_cat_$catKey'),
                  index: index,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: isEnabled ? const Color(0xFFF8FAFC) : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isEnabled ? const Color(0xFFE2E8F0) : Colors.grey.shade200,
                      ),
                    ),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Icon(
                              Icons.drag_indicator_rounded,
                              color: Color(0xFF94A3B8),
                              size: 22,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isEnabled
                                ? const Color(0xFF15786C).withValues(alpha: 0.1)
                                : Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '#${index + 2}',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: isEnabled ? const Color(0xFF15786C) : Colors.grey.shade500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Image.asset(
                          meta.asset,
                          width: 28,
                          height: 28,
                          errorBuilder: (context, error, stackTrace) => Icon(
                            meta.icon,
                            size: 22,
                            color: isEnabled ? const Color(0xFF15786C) : Colors.grey.shade400,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            meta.title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isEnabled ? const Color(0xFF0F172A) : Colors.grey.shade500,
                            ),
                          ),
                        ),
                        if (!isEnabled)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEE2E2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'Disabled in Settings',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFDC2626),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),

          // Bottom buttons: Done & Manage in Settings
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await context.push('/settings');
                    widget.onReorderCompleted();
                  },
                  icon: const Icon(Icons.settings_outlined, size: 16),
                  label: const Text('Visibility Settings'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF15786C),
                    side: const BorderSide(color: Color(0xFF15786C)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF15786C),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}




