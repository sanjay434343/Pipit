import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:go_router/go_router.dart';
import '../../services/ai_service.dart';
import '../../services/database_service.dart';
import '../../services/preferences_service.dart';

/// Metadata for a category item in the settings and tab reordering list.
class _CategoryMeta {
  final String title;
  final String subtitle;
  final String assetPath;
  final IconData icon;

  const _CategoryMeta({
    required this.title,
    required this.subtitle,
    required this.assetPath,
    required this.icon,
  });
}

/// Ultra-modern, redesigned Settings & Content Discovery Screen for Pipit.
/// Provides deep control over:
/// - Category scanning toggles (immediately removes tab & purges all SQLite records & embeddings)
/// - Flexible library sorting modes
/// - Responsive grid density (2, 3, or 4 columns)
/// - Hardware-accelerated LiteRT AI engine (GPU / CPU / NNAPI)
/// - Parallel worker concurrency
/// - Realtime database maintenance & library rescans
class SettingsScreen extends StatefulWidget {
  final VoidCallback? onSettingsChanged;

  const SettingsScreen({
    super.key,
    this.onSettingsChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // AI & Engine state
  int _selectedThreads = 4;
  PreferredBackend _selectedBackend = PreferredBackend.gpu;
  bool _isLoadingModel = false;
  bool _isPurging = false;
  String? _statusFeedback;

  // Layout & Sorting state
  int _gridColumns = 2;
  String _sortMode = 'date_desc';

  // Category Scanning & Reordering States
  List<String> _categoryOrder = [];
  bool _scanPhotos = true;
  bool _scanVideos = true;
  bool _scanAudio = true;
  bool _scanDocuments = true;
  bool _scanApps = true;
  bool _scanContacts = true;
  bool _scanSms = true;

  static const Map<String, _CategoryMeta> _categoryMetadata = {
    'photos': _CategoryMeta(
      title: 'Photos & Images',
      subtitle: 'Camera roll, screenshots, and visual media embeddings',
      assetPath: 'assets/iamges/images.png',
      icon: Icons.photo_library_outlined,
    ),
    'videos': _CategoryMeta(
      title: 'Videos',
      subtitle: 'Video clips, title embeddings and visual tags',
      assetPath: 'assets/iamges/video.png',
      icon: Icons.videocam_outlined,
    ),
    'audio': _CategoryMeta(
      title: 'Audio & Music',
      subtitle: 'Songs, voice recordings, and podcasts',
      assetPath: 'assets/iamges/music.png',
      icon: Icons.audiotrack_outlined,
    ),
    'documents': _CategoryMeta(
      title: 'Documents',
      subtitle: 'PDF, Word, OCR text extraction and semantic search',
      assetPath: 'assets/iamges/documents.png',
      icon: Icons.description_outlined,
    ),
    'apps': _CategoryMeta(
      title: 'Installed Apps',
      subtitle: 'Installed applications for instant launch & search',
      assetPath: 'assets/iamges/apps.png',
      icon: Icons.apps_rounded,
    ),
    'contacts': _CategoryMeta(
      title: 'Contacts & Address Book',
      subtitle: 'Device contacts, names, and phone numbers',
      assetPath: 'assets/iamges/contacts.png',
      icon: Icons.contacts_outlined,
    ),
    'sms': _CategoryMeta(
      title: 'SMS Messages',
      subtitle: 'SMS messages, codes, and text threads',
      assetPath: 'assets/iamges/message.png',
      icon: Icons.sms_outlined,
    ),
  };

  @override
  void initState() {
    super.initState();
    _selectedThreads = AiService.instance.parallelThreads;
    _selectedBackend = AiService.instance.preferredBackend;
    _loadAllSettings();
  }

  void _loadAllSettings() {
    final prefs = PreferencesService.instance;
    setState(() {
      _gridColumns = prefs.gridColumns;
      _sortMode = prefs.sortMode;
      _categoryOrder = List<String>.from(prefs.categoryOrder);
      _scanPhotos = prefs.isCategoryScanningEnabled('photos');
      _scanVideos = prefs.isCategoryScanningEnabled('videos');
      _scanAudio = prefs.isCategoryScanningEnabled('audio');
      _scanDocuments = prefs.isCategoryScanningEnabled('documents');
      _scanApps = prefs.isCategoryScanningEnabled('apps');
      _scanContacts = prefs.isCategoryScanningEnabled('contacts');
      _scanSms = prefs.isCategoryScanningEnabled('sms');
    });
  }

  bool _isCategoryEnabled(String key) {
    switch (key.toLowerCase()) {
      case 'photos':
        return _scanPhotos;
      case 'videos':
        return _scanVideos;
      case 'audio':
        return _scanAudio;
      case 'documents':
        return _scanDocuments;
      case 'apps':
        return _scanApps;
      case 'contacts':
        return _scanContacts;
      case 'sms':
        return _scanSms;
      default:
        return true;
    }
  }

  Future<void> _onReorderCategories(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (oldIndex == newIndex) return;

    HapticFeedback.mediumImpact();
    setState(() {
      final movedItem = _categoryOrder.removeAt(oldIndex);
      _categoryOrder.insert(newIndex, movedItem);
    });

    await PreferencesService.instance.setCategoryOrder(_categoryOrder);
    widget.onSettingsChanged?.call();

    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.swap_vert_rounded, color: Colors.white, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Category order saved. Home tabs rearranged.',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF15786C),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          duration: const Duration(milliseconds: 1600),
        ),
      );
    }
  }

  /// Toggle scanning on/off for a specific category.
  /// When turned OFF:
  /// - Persists preference
  /// - Wipes all database rows, OCR text, and LiteRT embeddings from SQLite
  /// - Immediately notifies Home Screen to remove the tab and clear in-memory cache
  Future<void> _toggleCategoryScanning(String category, bool enabled) async {
    // 1. Save to SharedPreferences & SQLite app_settings
    await PreferencesService.instance.setCategoryScanningEnabled(category, enabled);

    // 2. If disabled, completely purge all data & embeddings from SQLite
    if (!enabled) {
      await DatabaseService.instance.purgeCategoryData(category);
    }

    // 3. Update local state
    setState(() {
      switch (category.toLowerCase()) {
        case 'photos':
          _scanPhotos = enabled;
          break;
        case 'videos':
          _scanVideos = enabled;
          break;
        case 'audio':
          _scanAudio = enabled;
          break;
        case 'documents':
          _scanDocuments = enabled;
          break;
        case 'apps':
          _scanApps = enabled;
          break;
        case 'contacts':
          _scanContacts = enabled;
          break;
        case 'sms':
          _scanSms = enabled;
          break;
      }
    });

    // 4. Notify parent / HomeScreen to adapt tabs immediately
    widget.onSettingsChanged?.call();

    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                enabled ? Icons.check_circle_rounded : Icons.delete_sweep_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  enabled
                      ? '${_getCategoryName(category)} scanning enabled. Tab restored.'
                      : '${_getCategoryName(category)} disabled. Tab removed & all data/embeddings purged.',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: enabled ? const Color(0xFF15786C) : const Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          duration: const Duration(milliseconds: 2200),
        ),
      );
    }
  }

  String _getCategoryName(String category) {
    switch (category.toLowerCase()) {
      case 'photos':
        return 'Photos';
      case 'videos':
        return 'Videos';
      case 'audio':
        return 'Audio & Music';
      case 'documents':
        return 'Documents';
      case 'apps':
        return 'Apps';
      case 'contacts':
        return 'Contacts';
      case 'sms':
        return 'SMS Messages';
      default:
        return category;
    }
  }

  Future<void> _changeGridColumns(int cols) async {
    setState(() => _gridColumns = cols);
    await PreferencesService.instance.setGridColumns(cols);
    widget.onSettingsChanged?.call();
  }

  Future<void> _changeSortMode(String mode) async {
    setState(() => _sortMode = mode);
    await PreferencesService.instance.setSortMode(mode);
    widget.onSettingsChanged?.call();
  }

  Future<void> _changeBackend(PreferredBackend backend) async {
    setState(() => _selectedBackend = backend);
    AiService.instance.setPreferredBackend(backend);
    if (AiService.instance.isModelLoaded) {
      setState(() {
        _isLoadingModel = true;
        _statusFeedback = 'Switching to ${backend.name.toUpperCase()}...';
      });
      try {
        await AiService.instance.switchBackend(backend);
        if (mounted) {
          setState(() {
            _isLoadingModel = false;
            _statusFeedback = 'Active: ${AiService.instance.activeBackend}';
          });
          widget.onSettingsChanged?.call();
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLoadingModel = false;
            _statusFeedback = 'Backend switch info: $e';
          });
        }
      }
    }
  }

  void _updateThreads(int count) {
    final clamped = count.clamp(1, 8);
    setState(() => _selectedThreads = clamped);
    AiService.instance.setParallelThreads(clamped);
    widget.onSettingsChanged?.call();
  }

  Future<void> _pickAndLoadModel() async {
    final granted = await Permission.storage.request().isGranted ||
        await Permission.manageExternalStorage.request().isGranted ||
        await Permission.photos.request().isGranted;

    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Storage permission required.'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }

    try {
      FilePickerResult? result;
      try {
        result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['litertlm', 'task', 'bin', 'tflite'],
        );
      } catch (_) {
        result = await FilePicker.platform.pickFiles(type: FileType.any);
      }

      if (result == null || result.files.single.path == null) return;

      final filePath = result.files.single.path!;
      final fileName = result.files.single.name;

      if (fileName.toLowerCase().endsWith('.apk')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Please select a valid .litertlm model file.'),
              backgroundColor: Colors.red.shade700,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
        return;
      }

      setState(() {
        _isLoadingModel = true;
        _statusFeedback = 'Loading $fileName...';
      });

      await AiService.instance.loadModel(
        filePath,
        fileName,
        preferredBackend: _selectedBackend,
      );

      if (mounted) {
        setState(() {
          _isLoadingModel = false;
          _statusFeedback =
              'Loaded $fileName (${AiService.instance.vectorDimension}-d, ${AiService.instance.activeBackend})';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Model loaded successfully on ${AiService.instance.activeBackend}!',
            ),
            backgroundColor: const Color(0xFF15786C),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );

        widget.onSettingsChanged?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingModel = false;
          _statusFeedback = 'Failed: $e';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading model: $e'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  Future<void> _purgeExcludedMedia() async {
    setState(() => _isPurging = true);
    try {
      final removed = await DatabaseService.instance.removeExcludedMedia();
      if (mounted) {
        setState(() => _isPurging = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              removed > 0
                  ? 'Purged $removed excluded/WhatsApp sticker records.'
                  : 'Database cache is clean. No excluded media found.',
            ),
            backgroundColor: const Color(0xFF15786C),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isPurging = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Purge error: $e'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  void _triggerRescan(String command, String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Triggering $label...'),
        backgroundColor: const Color(0xFF15786C),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
    Navigator.of(context).pop(command);
  }

  String _getThreadPerformanceLabel(int count) {
    if (count <= 1) return 'Eco • Battery Saver';
    if (count <= 2) return 'Light • Low Heat';
    if (count <= 4) return 'Optimal • Recommended';
    if (count <= 6) return 'High Throughput';
    return 'Turbo • Maximum Speed';
  }

  /* ───────────────────────── UI BUILD ───────────────────────── */

  @override
  Widget build(BuildContext context) {
    const brandColor = Color(0xFF15786C);
    const inkColor = Color(0xFF0F172A);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: inkColor),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Settings',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: inkColor,
            letterSpacing: -0.4,
          ),
        ),
        centerTitle: true,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
            decoration: BoxDecoration(
              color: const Color(0xFFE2F3F0),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: brandColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  AiService.instance.isModelLoaded ? 'AI Active' : 'Offline Mode',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: brandColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 40),
        children: [
          // ── 1. CATEGORY SCANNING & TAB VISIBILITY (HERO SECTION) ──
          _buildHeaderPill(
            icon: Icons.dashboard_customize_outlined,
            title: 'Categories & Tab Visibility',
            subtitle: 'Long-press & drag to change tab order on Home. Toggle off to stop scanning and purge database.',
          ),
          const SizedBox(height: 10),
          _buildSectionCard(
            children: [
              // Fixed 'All' category at position #1 ("make the all at same space")
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF15786C).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Image.asset(
                        'assets/iamges/all.png',
                        width: 26,
                        height: 26,
                        errorBuilder: (context, error, stackTrace) => const Icon(
                          Icons.auto_awesome_motion_outlined,
                          size: 24,
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
                                'All (Master Timeline)',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              SizedBox(width: 6),
                              Icon(
                                Icons.lock_outline_rounded,
                                size: 14,
                                color: Color(0xFF64748B),
                              ),
                            ],
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Permanent position #1 • Unified cross-category stream',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF15786C),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Fixed #1',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Drag Tip
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.swap_vert_rounded,
                      size: 15,
                      color: Colors.grey.shade700,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Press & hold any item below to drag and reorder tabs on Home:',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // Dynamic Reorderable Category List
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: _categoryOrder.length,
                onReorder: _onReorderCategories,
                proxyDecorator: (Widget child, int index, Animation<double> animation) {
                  return AnimatedBuilder(
                    animation: animation,
                    builder: (BuildContext context, Widget? child) {
                      return Material(
                        elevation: 6,
                        color: Colors.white,
                        shadowColor: const Color(0xFF15786C).withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(16),
                        child: child,
                      );
                    },
                    child: child,
                  );
                },
                itemBuilder: (context, index) {
                  final catKey = _categoryOrder[index];
                  final meta = _categoryMetadata[catKey] ??
                      _CategoryMeta(
                        title: _getCategoryName(catKey),
                        subtitle: 'Category data and search index',
                        assetPath: 'assets/iamges/images.png',
                        icon: Icons.folder_outlined,
                      );
                  final isEnabled = _isCategoryEnabled(catKey);

                  return Container(
                    key: ValueKey('category_order_$catKey'),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ReorderableDelayedDragStartListener(
                          index: index,
                          child: _buildCategoryTile(
                            positionNumber: index + 2,
                            dragHandle: ReorderableDragStartListener(
                              index: index,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                                child: Icon(
                                  Icons.drag_indicator_rounded,
                                  color: Color(0xFF94A3B8),
                                  size: 22,
                                ),
                              ),
                            ),
                            title: meta.title,
                            subtitle: meta.subtitle,
                            assetPath: meta.assetPath,
                            icon: meta.icon,
                            isEnabled: isEnabled,
                            onChanged: (val) => _toggleCategoryScanning(catKey, val),
                          ),
                        ),
                        if (index < _categoryOrder.length - 1)
                          const _CustomDivider(),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),

              // Reset sequence option
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    HapticFeedback.lightImpact();
                    setState(() {
                      _categoryOrder = List<String>.from(PreferencesService.defaultCategoryOrder);
                    });
                    await PreferencesService.instance.setCategoryOrder(_categoryOrder);
                    widget.onSettingsChanged?.call();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text('Category order reset to default sequence.'),
                          backgroundColor: const Color(0xFF15786C),
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.refresh_rounded, size: 14),
                  label: const Text(
                    'Reset to Default Order',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF15786C),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),

          // ── 2. SORTING MODE ──
          _buildHeaderPill(
            icon: Icons.sort_rounded,
            title: 'Sorting Preferences',
            subtitle: 'Choose how search results and tab items are ordered across all categories.',
          ),
          const SizedBox(height: 10),
          _buildSectionCard(
            children: [
              _buildSortOption(
                modeKey: 'date_desc',
                title: 'Date Created / Modified (Newest First)',
                subtitle: 'Recommended • Most recent items appear at the top',
                icon: Icons.schedule_rounded,
              ),
              const _CustomDivider(),
              _buildSortOption(
                modeKey: 'date_asc',
                title: 'Date (Oldest First)',
                subtitle: 'Earliest items appear on top',
                icon: Icons.history_rounded,
              ),
              const _CustomDivider(),
              _buildSortOption(
                modeKey: 'name_asc',
                title: 'Name (A to Z)',
                subtitle: 'Alphabetical order from A to Z',
                icon: Icons.sort_by_alpha_rounded,
              ),
              const _CustomDivider(),
              _buildSortOption(
                modeKey: 'name_desc',
                title: 'Name (Z to A)',
                subtitle: 'Reverse alphabetical order from Z to A',
                icon: Icons.sort_by_alpha_rounded,
              ),
              const _CustomDivider(),
              _buildSortOption(
                modeKey: 'size_desc',
                title: 'File Size (Largest First)',
                subtitle: 'Heaviest files and media shown first',
                icon: Icons.storage_rounded,
              ),
              const _CustomDivider(),
              _buildSortOption(
                modeKey: 'size_asc',
                title: 'File Size (Smallest First)',
                subtitle: 'Lightest and smallest files shown first',
                icon: Icons.sd_storage_outlined,
              ),
            ],
          ),
          const SizedBox(height: 26),

          // ── 3. GRID LAYOUT & DENSITY ──
          _buildHeaderPill(
            icon: Icons.grid_view_rounded,
            title: 'Grid Density',
            subtitle: 'Customize the number of cards displayed per row on library grids.',
          ),
          const SizedBox(height: 10),
          _buildSectionCard(
            children: [
              Row(
                children: [
                  _buildGridOption(columns: 2, label: 'Comfortable', detail: '2 columns (Default)'),
                  const SizedBox(width: 10),
                  _buildGridOption(columns: 3, label: 'Compact', detail: '3 columns'),
                  const SizedBox(width: 10),
                  _buildGridOption(columns: 4, label: 'Dense', detail: '4 columns'),
                ],
              ),
            ],
          ),
          const SizedBox(height: 26),

          // ── 4. AI ENGINE & PERFORMANCE ──
          _buildHeaderPill(
            icon: Icons.memory_rounded,
            title: 'AI Engine & Hardware Acceleration',
            subtitle: 'Configure on-device LiteRT embedding workers and compute backend.',
          ),
          const SizedBox(height: 10),
          _buildSectionCard(
            children: [
              // Backend selector
              const Text(
                'Hardware Acceleration Backend',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: inkColor),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _buildBackendChip(
                      backend: PreferredBackend.gpu,
                      label: 'GPU',
                      icon: Icons.bolt_rounded,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildBackendChip(
                      backend: PreferredBackend.cpu,
                      label: 'CPU',
                      icon: Icons.memory_rounded,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildBackendChip(
                      backend: PreferredBackend.npu,
                      label: 'NPU',
                      icon: Icons.developer_board_rounded,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const _CustomDivider(),
              const SizedBox(height: 14),

              // Concurrency slider
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Parallel Worker Threads',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: inkColor),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE2F3F0),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$_selectedThreads threads',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: brandColor),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _getThreadPerformanceLabel(_selectedThreads),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 8),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3.5,
                  activeTrackColor: brandColor,
                  inactiveTrackColor: Colors.grey.shade200,
                  thumbColor: brandColor,
                  overlayColor: brandColor.withValues(alpha: 0.12),
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8.0),
                ),
                child: Slider(
                  value: _selectedThreads.toDouble(),
                  min: 1.0,
                  max: 8.0,
                  divisions: 7,
                  onChanged: (val) => _updateThreads(val.round()),
                ),
              ),
              const SizedBox(height: 12),
              const _CustomDivider(),
              const SizedBox(height: 14),

              // Model Status & Loader
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE2F3F0),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.smart_toy_rounded, color: brandColor, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AiService.instance.currentModelName ?? 'No Model Loaded',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: inkColor),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _statusFeedback ??
                              (AiService.instance.isModelLoaded
                                  ? '${AiService.instance.vectorDimension}-d Vector Embeddings'
                                  : 'Pick a .litertlm model or download in-app'),
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: inkColor,
                        side: BorderSide(color: Colors.grey.shade300),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                      onPressed: _isLoadingModel ? null : _pickAndLoadModel,
                      icon: const Icon(Icons.file_open_outlined, size: 17),
                      label: const Text('Pick Model File', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: brandColor,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                      onPressed: () => context.push('/model-downloader'),
                      icon: const Icon(Icons.cloud_download_rounded, size: 17),
                      label: const Text('Download Hub', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 26),

          // ── 5. LIBRARY RE-SCAN & MAINTENANCE ──
          _buildHeaderPill(
            icon: Icons.sync_rounded,
            title: 'Library Maintenance & Storage',
            subtitle: 'Force a complete re-scan or clear cached stickers and excluded media.',
          ),
          const SizedBox(height: 10),
          _buildSectionCard(
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: brandColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  onPressed: () => _triggerRescan('rescan_all', 'Full Library Re-scan'),
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                  label: const Text('Re-scan Full Device Library', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildQuickChip('Photos', Icons.photo_library_outlined, 'rescan_photos'),
                  _buildQuickChip('Videos', Icons.videocam_outlined, 'rescan_videos'),
                  _buildQuickChip('Audio', Icons.audiotrack_outlined, 'rescan_audios'),
                  _buildQuickChip('Docs', Icons.description_outlined, 'rescan_docs'),
                  _buildQuickChip('Apps', Icons.apps_rounded, 'rescan_apps'),
                  _buildQuickChip('Contacts', Icons.contacts_outlined, 'rescan_contacts'),
                  _buildQuickChip('SMS', Icons.sms_outlined, 'rescan_sms'),
                ],
              ),
              const SizedBox(height: 14),
              const _CustomDivider(),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.blueGrey.shade700,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: _isPurging ? null : _purgeExcludedMedia,
                  icon: _isPurging
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cleaning_services_rounded, size: 18),
                  label: const Text('Purge Excluded Media & WhatsApp Stickers', style: TextStyle(fontSize: 12.5)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 30),

          // ── 6. PRIVACY FOOTER ──
          Center(
            child: Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shield_rounded, size: 16, color: Colors.grey.shade500),
                    const SizedBox(width: 6),
                    Text(
                      '100% On-Device & Private',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Pipit never uploads files, embeddings, contacts, or SMS to any server.',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /* ───────────────────────── WIDGET BUILDERS ───────────────────────── */

  Widget _buildHeaderPill({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: const Color(0xFF15786C)),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            height: 1.35,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildSectionCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildCategoryTile({
    required int positionNumber,
    required Widget dragHandle,
    required String title,
    required String subtitle,
    required String assetPath,
    required IconData icon,
    required bool isEnabled,
    required ValueChanged<bool> onChanged,
    bool isDestructiveNotice = false,
  }) {
    const brandColor = Color(0xFF15786C);

    return Container(
      color: Colors.transparent,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          dragHandle,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 2),
            decoration: BoxDecoration(
              color: isEnabled
                  ? const Color(0xFF15786C).withValues(alpha: 0.1)
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '#$positionNumber',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: isEnabled ? const Color(0xFF15786C) : Colors.grey.shade500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isEnabled ? const Color(0xFFE2F3F0) : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(13),
            ),
            padding: const EdgeInsets.all(7),
            child: Image.asset(
              assetPath,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Icon(
                icon,
                color: isEnabled ? brandColor : Colors.grey.shade400,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isEnabled ? const Color(0xFF0F172A) : Colors.grey.shade500,
                      ),
                    ),
                    if (!isEnabled) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'Purged',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFFDC2626),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  isEnabled ? subtitle : 'Tab removed • All records and embeddings purged from DB',
                  style: TextStyle(
                    fontSize: 11,
                    color: isEnabled ? Colors.grey.shade600 : Colors.red.shade400,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: isEnabled,
            activeThumbColor: brandColor,
            activeTrackColor: const Color(0xFFBCE1DA),
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: Colors.grey.shade300,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildSortOption({
    required String modeKey,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final isSelected = _sortMode == modeKey;
    const brandColor = Color(0xFF15786C);

    return InkWell(
      onTap: () => _changeSortMode(modeKey),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFFE2F3F0) : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: isSelected ? brandColor : Colors.grey.shade600,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                      color: isSelected ? brandColor : const Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            Icon(
              isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
              color: isSelected ? brandColor : Colors.grey.shade300,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridOption({
    required int columns,
    required String label,
    required String detail,
  }) {
    final isSelected = _gridColumns == columns;
    const brandColor = Color(0xFF15786C);

    return Expanded(
      child: GestureDetector(
        onTap: () => _changeGridColumns(columns),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFE2F3F0) : Colors.grey.shade50,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected ? brandColor : Colors.grey.shade200,
              width: isSelected ? 1.8 : 1.0,
            ),
          ),
          child: Column(
            children: [
              Text(
                '$columns',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: isSelected ? brandColor : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isSelected ? brandColor : Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                detail,
                style: TextStyle(
                  fontSize: 9.5,
                  color: isSelected ? brandColor.withValues(alpha: 0.8) : Colors.grey.shade500,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBackendChip({
    required PreferredBackend backend,
    required String label,
    required IconData icon,
  }) {
    final isSelected = _selectedBackend == backend;
    const brandColor = Color(0xFF15786C);

    return GestureDetector(
      onTap: () => _changeBackend(backend),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? brandColor : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? brandColor : Colors.grey.shade300,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: isSelected ? Colors.white : brandColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.bold,
                color: isSelected ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickChip(String label, IconData icon, String command) {
    return ActionChip(
      avatar: Icon(icon, size: 15, color: const Color(0xFF15786C)),
      label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      backgroundColor: const Color(0xFFF1F5F9),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(color: Colors.grey.shade300),
      onPressed: () => _triggerRescan(command, '$label Re-scan'),
    );
  }
}

class _CustomDivider extends StatelessWidget {
  const _CustomDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Divider(color: Colors.grey.shade100, height: 1),
    );
  }
}
