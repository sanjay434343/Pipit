import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:go_router/go_router.dart';
import '../../services/database_service.dart';
import '../../services/preferences_service.dart';

/// Screen explaining all permissions Pipit requests and allowing one-click batch permission grant.
class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> with WidgetsBindingObserver {
  bool _isChecking = true;
  bool _isRequesting = false;

  bool _photosGranted = false;
  bool _storageGranted = false;
  bool _contactsGranted = false;
  bool _smsGranted = false;

  bool _isPermanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAllPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAllPermissions();
    }
  }

  Future<void> _checkAllPermissions() async {
    setState(() => _isChecking = true);

    try {
      // 1. Photos & Videos
      final photos = await Permission.photos.isGranted;
      final videos = await Permission.videos.isGranted;
      final storage = await Permission.storage.isGranted;
      final manageStorage = await Permission.manageExternalStorage.isGranted;
      final hasMedia = (photos && videos) || storage || manageStorage;

      // 2. Storage & Files (manage storage or legacy storage or audio)
      final audio = await Permission.audio.isGranted;
      final hasStorage = manageStorage || storage || audio;

      // 3. Contacts
      final hasContacts = await Permission.contacts.isGranted;

      // 4. SMS
      final hasSms = await Permission.sms.isGranted;

      // Check permanently denied
      final permDenied = await Permission.contacts.isPermanentlyDenied ||
          await Permission.sms.isPermanentlyDenied ||
          (await Permission.storage.isPermanentlyDenied &&
              await Permission.manageExternalStorage.isPermanentlyDenied);

      if (mounted) {
        setState(() {
          _photosGranted = hasMedia;
          _storageGranted = hasStorage;
          _contactsGranted = hasContacts;
          _smsGranted = hasSms;
          _isPermanentlyDenied = permDenied;
          _isChecking = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  Future<void> _requestAllPermissions() async {
    if (_isRequesting) return;
    setState(() => _isRequesting = true);
    HapticFeedback.mediumImpact();

    try {
      final permissions = <Permission>[
        Permission.photos,
        Permission.videos,
        Permission.audio,
        Permission.storage,
        Permission.manageExternalStorage,
        Permission.contacts,
        Permission.sms,
      ];

      await permissions.request();
    } catch (e) {
      debugPrint('[PermissionScreen] Error requesting permissions: $e');
    }

    await _checkAllPermissions();

    if (mounted) {
      setState(() => _isRequesting = false);
      if (_allGranted) {
        HapticFeedback.lightImpact();
        _proceedToHome();
      }
    }
  }

  bool get _allGranted =>
      _photosGranted && _storageGranted && _contactsGranted && _smsGranted;

  Future<void> _proceedToHome() async {
    await PreferencesService.instance.setHasCompletedPermissions(true);
    await PreferencesService.instance.setHasVisitedAll(true);
    await DatabaseService.instance.setAppSetting('has_completed_permissions', 'true');
    await DatabaseService.instance.setAppSetting('has_visited_all', 'true');
    if (!mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    const tealColor = Color(0xFF15786C);
    const darkTeal = Color(0xFF0A443C);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Navigator.of(context).canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: darkTeal),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        title: const Text(
          'Permissions',
          style: TextStyle(
            color: darkTeal,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Header Logo & Badge
                    Center(
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE2F3F0),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: tealColor.withValues(alpha: 0.25),
                            width: 1.5,
                          ),
                        ),
                        child: Center(
                          child: ColorFiltered(
                            colorFilter: const ColorFilter.mode(
                              tealColor,
                              BlendMode.srcIn,
                            ),
                            child: Image.asset(
                              'assets/iamges/logo.png',
                              width: 44,
                              height: 44,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) => const Icon(
                                Icons.shield_rounded,
                                color: tealColor,
                                size: 36,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    const Text(
                      'Access & Privacy',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                        color: Color(0xFF0F2D28),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Pipit works 100% on your device. To index and search your local media, documents, and messages, we need access to the following:',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14.5,
                        height: 1.45,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFF4E736E),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Permission Items
                    _buildPermissionTile(
                      icon: Icons.photo_library_rounded,
                      title: 'Photos & Videos',
                      description:
                          'Recognize people, scenes, visual text, and search photos by meaning.',
                      isGranted: _photosGranted,
                      accentColor: const Color(0xFF0284C7),
                    ),
                    const SizedBox(height: 12),
                    _buildPermissionTile(
                      icon: Icons.folder_shared_rounded,
                      title: 'Files & Documents',
                      description:
                          'Index PDF documents, text files, and audio tracks across local storage.',
                      isGranted: _storageGranted,
                      accentColor: const Color(0xFF059669),
                    ),
                    const SizedBox(height: 12),
                    _buildPermissionTile(
                      icon: Icons.contacts_rounded,
                      title: 'Contacts',
                      description:
                          'Look up people by name, relation, or details directly in search.',
                      isGranted: _contactsGranted,
                      accentColor: const Color(0xFFD97706),
                    ),
                    const SizedBox(height: 12),
                    _buildPermissionTile(
                      icon: Icons.chat_bubble_rounded,
                      title: 'Messages (SMS)',
                      description:
                          'Search your text conversations and SMS snippets with complete offline privacy.',
                      isGranted: _smsGranted,
                      accentColor: const Color(0xFF8B5CF6),
                    ),
                    const SizedBox(height: 20),

                    // Privacy Assurance Card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F6F3),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFFBCE1DA),
                          width: 1.2,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.lock_outline_rounded,
                            color: tealColor,
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                Text(
                                  'Zero Cloud Uploads Guaranteed',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: darkTeal,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'Your files, photos, contacts, and messages never leave your phone. All AI extraction and semantic search happen locally.',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.4,
                                    color: Color(0xFF336058),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),

            // Bottom Actions Bar
            Container(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isPermanentlyDenied) ...[
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: tealColor,
                          side: const BorderSide(color: tealColor, width: 1.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(50),
                          ),
                        ),
                        icon: const Icon(Icons.settings_outlined, size: 20),
                        label: const Text(
                          'Open App Settings',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        onPressed: openAppSettings,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  // Primary "Allow All" Button
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: tealColor,
                        foregroundColor: Colors.white,
                        elevation: 3,
                        shadowColor: tealColor.withValues(alpha: 0.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(50),
                        ),
                      ),
                      onPressed: (_isRequesting || _isChecking) ? null : _requestAllPermissions,
                      child: (_isRequesting || _isChecking)
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _allGranted
                                      ? Icons.check_circle_rounded
                                      : Icons.lock_open_rounded,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _allGranted
                                      ? 'All Permissions Granted'
                                      : 'Allow All Permissions',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),

                  // Secondary skip/continue button
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: _proceedToHome,
                    child: Text(
                      _allGranted ? 'Continue' : 'Skip for now',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionTile({
    required IconData icon,
    required String title,
    required String description,
    required bool isGranted,
    required Color accentColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isGranted ? const Color(0xFFF7FAF9) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isGranted
              ? const Color(0xFFBCE1DA)
              : Colors.grey.shade200,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isGranted
                  ? const Color(0xFF15786C).withValues(alpha: 0.12)
                  : accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: isGranted ? const Color(0xFF15786C) : accentColor,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1E293B),
                        ),
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: isGranted
                            ? const Color(0xFF15786C).withValues(alpha: 0.15)
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isGranted
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            size: 13,
                            color: isGranted
                                ? const Color(0xFF15786C)
                                : Colors.grey.shade500,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isGranted ? 'Allowed' : 'Required',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isGranted
                                  ? const Color(0xFF15786C)
                                  : Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
