import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../../services/ai_service.dart';
import '../../services/model_downloader_service.dart';
import '../../services/model_storage_service.dart';

/// Ultra-modern, minimalist, center-focused AI Model Downloader Screen for Pipit.
/// Features:
/// - Real-time parallel 4-stream chunk download visualization
/// - Accurate 0% / progress / 100% detection (resolves false 100% bug)
/// - Pipit's signature emerald & mint palette (0xFF15786C & 0xFF10B981)
/// - Comprehensive offline on-device AI status and RAM cache management
class ModelDownloaderScreen extends StatefulWidget {
  const ModelDownloaderScreen({super.key});

  @override
  State<ModelDownloaderScreen> createState() => _ModelDownloaderScreenState();
}

class _ModelDownloaderScreenState extends State<ModelDownloaderScreen> {
  bool _isVerifying = false;

  static const Color _primaryGreen = Color(0xFF15786C);
  static const Color _accentMint = Color(0xFF10B981);
  static const Color _inkColor = Color(0xFF0F172A);
  static const Color _slateColor = Color(0xFF64748B);

  @override
  void initState() {
    super.initState();
    ModelDownloaderService.instance.addListener(_onServiceUpdate);
    ModelStorageService.instance.addListener(_onServiceUpdate);
    AiService.instance.addListener(_onServiceUpdate);

    // Initial storage scan
    ModelStorageService.instance.scanAvailableModels();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ModelDownloaderService.instance.removeListener(_onServiceUpdate);
    ModelStorageService.instance.removeListener(_onServiceUpdate);
    AiService.instance.removeListener(_onServiceUpdate);
    super.dispose();
  }

  /// Locate the actual model file on disk without greedy fallback to unrelated files.
  StoredModelInfo? _resolveTargetModelOnDisk(ModelPreset target) {
    final storage = ModelStorageService.instance;
    for (final m in storage.availableModels) {
      final nameLower = m.name.toLowerCase();
      if (nameLower == target.filename.toLowerCase() ||
          nameLower.contains('embeddinggemma')) {
        try {
          final file = File(m.path);
          if (file.existsSync() && file.lengthSync() > 10 * 1024 * 1024) {
            return m;
          }
        } catch (_) {}
      }
    }
    return null;
  }

  void _startTargetDownload() {
    final downloader = ModelDownloaderService.instance;
    if (downloader.isBusy) return;

    HapticFeedback.mediumImpact();

    if (downloader.isPaused) {
      downloader.resumeDownload();
      return;
    }

    final model = ModelDownloaderService.targetModel;
    downloader.startDownload(
      url: model.downloadUrl,
      fileName: model.filename,
      parallelChunks: 4,
    );
  }

  Future<void> _verifyAndLoadToRam(StoredModelInfo info) async {
    if (_isVerifying) return;
    setState(() => _isVerifying = true);
    HapticFeedback.lightImpact();

    final messenger = ScaffoldMessenger.of(context);
    final verify = await ModelStorageService.instance.verifyModelFile(info.path);

    if (!verify.isValid) {
      if (mounted) setState(() => _isVerifying = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Verification Failed: ${verify.message}'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      );
      return;
    }

    final success = await ModelStorageService.instance.autoLoadModelToRam(forceReload: true);
    if (mounted) {
      setState(() => _isVerifying = false);
      if (success) {
        messenger.showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${info.name} loaded into RAM (${AiService.instance.activeBackend}).',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ],
            ),
            backgroundColor: _primaryGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Failed to initialize model in RAM.'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        );
      }
    }
  }

  Future<void> _pickLocalModelFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['litertlm', 'bin', 'task', 'tflite'],
      );
      if (result == null || result.files.single.path == null) return;

      final path = result.files.single.path!;
      final name = result.files.single.name;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Selected local file: $name. Loading into RAM...'),
            backgroundColor: _primaryGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        );
      }

      await AiService.instance.loadModel(path, name);
      await ModelStorageService.instance.scanAvailableModels();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load local file: $e'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        );
      }
    }
  }

  void _showCustomUrlDialog(BuildContext context) {
    final urlController = TextEditingController();
    final filenameController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            void updateFilenameFromUrl(String url) {
              if (filenameController.text.trim().isEmpty) {
                final uri = Uri.tryParse(url.trim());
                if (uri != null && uri.pathSegments.isNotEmpty) {
                  final lastSeg = uri.pathSegments.last;
                  if (lastSeg.isNotEmpty) {
                    filenameController.text = lastSeg;
                    setDialogState(() {});
                  }
                }
              }
            }

            return AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              icon: const Icon(Icons.link_rounded, color: _primaryGreen, size: 28),
              title: const Text(
                'Custom Model URL',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enter direct download URL for a model file (.litertlm, .bin, or .tflite):',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFF475569)),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: urlController,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    onChanged: updateFilenameFromUrl,
                    decoration: InputDecoration(
                      labelText: 'Download URL',
                      hintText: 'https://huggingface.co/.../model.litertlm',
                      prefixIcon: const Icon(Icons.link_rounded, size: 20, color: _primaryGreen),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: filenameController,
                    decoration: InputDecoration(
                      labelText: 'Target File Name',
                      hintText: 'my_model.litertlm',
                      prefixIcon: const Icon(Icons.insert_drive_file_outlined, size: 20, color: _primaryGreen),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryGreen,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    final url = urlController.text.trim();
                    if (url.isEmpty) return;

                    var filename = filenameController.text.trim();
                    if (filename.isEmpty) {
                      final parsedUri = Uri.tryParse(url);
                      if (parsedUri != null && parsedUri.pathSegments.isNotEmpty) {
                        filename = parsedUri.pathSegments.last;
                      } else {
                        filename = url.split('/').last.split('?').first;
                      }
                      if (!filename.contains('.')) {
                        filename = '$filename.litertlm';
                      }
                    }

                    Navigator.of(ctx).pop();
                    ModelDownloaderService.instance.startDownload(
                      url: url,
                      fileName: filename,
                      parallelChunks: 4,
                    );
                  },
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showModelInfoDialog(BuildContext context) {
    final model = ModelDownloaderService.targetModel;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          icon: const Icon(Icons.info_outline_rounded, color: _primaryGreen, size: 28),
          title: const Text('Model Architecture', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(model.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 6),
              Text(
                model.description,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569), height: 1.35),
              ),
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 12),
              _buildInfoRow('File Name', model.filename),
              const SizedBox(height: 6),
              _buildInfoRow('File Size', model.formattedEstimatedSize),
              const SizedBox(height: 6),
              _buildInfoRow('Engine', 'Google LiteRT-LM Multimodal'),
              const SizedBox(height: 6),
              _buildInfoRow('Inference', '100% On-Device (Zero Cloud)'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close', style: TextStyle(color: _primaryGreen, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
        Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloader = ModelDownloaderService.instance;
    final ai = AiService.instance;
    final targetModel = ModelDownloaderService.targetModel;

    // Resolve actual model existence on disk (avoid false positive 100%)
    final existingModel = _resolveTargetModelOnDisk(targetModel);
    final bool isDownloadedOnDisk = existingModel != null;
    final bool isModelActiveInRam = ai.isModelLoaded && ai.embeddingModel != null;

    // Fix 100% Bug: If NOT on disk and NOT in RAM, reset any stale completed state
    if (!isDownloadedOnDisk &&
        !isModelActiveInRam &&
        !downloader.isBusy &&
        downloader.status == DownloadStatus.completed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        downloader.resetToIdle();
      });
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1.5,
        leading: IconButton(
          icon: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded, size: 16, color: _inkColor),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'AI Intelligence Engine',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: _inkColor,
            letterSpacing: -0.3,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded, color: _primaryGreen, size: 22),
            tooltip: 'Model Info',
            onPressed: () => _showModelInfoDialog(context),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Color(0xFF64748B), size: 22),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onSelected: (val) {
              if (val == 'custom_url') {
                _showCustomUrlDialog(context);
              } else if (val == 'pick_file') {
                _pickLocalModelFile();
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'pick_file',
                child: Row(
                  children: [
                    Icon(Icons.folder_open_rounded, size: 18, color: _primaryGreen),
                    SizedBox(width: 10),
                    Text('Select Local Model File', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'custom_url',
                child: Row(
                  children: [
                    Icon(Icons.link_rounded, size: 18, color: _primaryGreen),
                    SizedBox(width: 10),
                    Text('Custom Download URL', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Top Status Badge Pill
              _buildTopStatusPill(
                isDownloaded: isDownloadedOnDisk,
                isActiveInRam: isModelActiveInRam,
                downloader: downloader,
              ),
              const SizedBox(height: 24),

              // Hero Radial Hub (Centerpiece)
              _buildHeroCenterGauge(
                downloader: downloader,
                isDownloaded: isDownloadedOnDisk,
                isActiveInRam: isModelActiveInRam,
                targetModel: targetModel,
              ),
              if (downloader.isDownloading) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF86EFAC)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.notifications_active_outlined, size: 14, color: Color(0xFF166534)),
                      SizedBox(width: 7),
                      Text(
                        'Background download active • Safe to exit or turn screen off',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF166534),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),

              // Feature Highlights Bento Cards
              _buildFeatureBentoCards(),
              const SizedBox(height: 20),

              // Storage & Engine Specs Pill
              _buildSpecsCard(targetModel, isDownloadedOnDisk),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomActionBar(
        downloader: downloader,
        isDownloaded: isDownloadedOnDisk,
        isActiveInRam: isModelActiveInRam,
        existingModel: existingModel,
      ),
    );
  }

  /// Clean top status badge pill indicating engine state
  Widget _buildTopStatusPill({
    required bool isDownloaded,
    required bool isActiveInRam,
    required ModelDownloaderService downloader,
  }) {
    String label;
    Color bgColor;
    Color textColor;
    IconData icon;

    if (downloader.isDownloading) {
      label = 'Background Downloading • Notification Active';
      bgColor = const Color(0xFFE0F2FE);
      textColor = const Color(0xFF0369A1);
      icon = Icons.downloading_rounded;
    } else if (downloader.isPaused) {
      label = 'Download Paused';
      bgColor = const Color(0xFFFEF3C7);
      textColor = const Color(0xFFB45309);
      icon = Icons.pause_circle_outline_rounded;
    } else if (isActiveInRam) {
      label = 'AI Active in RAM (${AiService.instance.activeBackend})';
      bgColor = const Color(0xFFD1FAE5);
      textColor = const Color(0xFF047857);
      icon = Icons.bolt_rounded;
    } else if (isDownloaded) {
      label = 'Installed on Device Storage';
      bgColor = const Color(0xFFE2F3F0);
      textColor = _primaryGreen;
      icon = Icons.check_circle_outline_rounded;
    } else {
      label = 'Engine Offline • 440 MB Required';
      bgColor = const Color(0xFFF1F5F9);
      textColor = _slateColor;
      icon = Icons.cloud_download_outlined;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: textColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: textColor),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }

  /// Minimalist circular hero gauge displaying the live percentage,
  /// download metrics, and parallel multi-stream status.
  Widget _buildHeroCenterGauge({
    required ModelDownloaderService downloader,
    required bool isDownloaded,
    required bool isActiveInRam,
    required ModelPreset targetModel,
  }) {
    final status = downloader.status;
    final isDownloading = downloader.isDownloading;
    final isPaused = downloader.isPaused;
    final isConnecting = status == DownloadStatus.connecting;
    final isVerifying = status == DownloadStatus.verifying;
    final isCompleted = (status == DownloadStatus.completed || isActiveInRam) && isDownloaded;

    double progressVal = 0.0;
    if (isCompleted) {
      progressVal = 1.0;
    } else if (isDownloading || isPaused || isConnecting || downloader.downloadedBytes > 0) {
      progressVal = downloader.progress.clamp(0.0, 1.0);
    }

    final percentText = '${(progressVal * 100).toInt()}%';

    return Container(
      width: 260,
      height: 260,
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Ambient soft background glow
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isCompleted
                  ? _accentMint.withValues(alpha: 0.06)
                  : (isDownloading ? _primaryGreen.withValues(alpha: 0.06) : Colors.white),
              boxShadow: [
                BoxShadow(
                  color: isCompleted
                      ? _accentMint.withValues(alpha: 0.15)
                      : (isDownloading
                          ? _primaryGreen.withValues(alpha: 0.12)
                          : Colors.black.withValues(alpha: 0.03)),
                  blurRadius: 36,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),

          // Circular progress ring
          SizedBox(
            width: 230,
            height: 230,
            child: CircularProgressIndicator(
              value: (isVerifying || isConnecting) ? null : progressVal,
              strokeWidth: 10,
              strokeCap: StrokeCap.round,
              backgroundColor: const Color(0xFFE2E8F0),
              valueColor: AlwaysStoppedAnimation<Color>(
                isCompleted ? _accentMint : _primaryGreen,
              ),
            ),
          ),

          // Center Info
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isCompleted) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD1FAE5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_rounded, color: Color(0xFF059669), size: 28),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '100%',
                    style: TextStyle(
                      fontSize: 42,
                      fontWeight: FontWeight.w800,
                      color: _inkColor,
                      letterSpacing: -1.5,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Installed & Verified',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _primaryGreen),
                  ),
                  Text(
                    targetModel.formattedEstimatedSize,
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
                  ),
                ] else if (isVerifying) ...[
                  const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(strokeWidth: 3, color: _primaryGreen),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Verifying...',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _inkColor),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Checking file tensors',
                    style: TextStyle(fontSize: 12, color: _slateColor),
                  ),
                ] else if (isDownloading || isPaused || isConnecting || downloader.downloadedBytes > 0) ...[
                  Text(
                    percentText,
                    style: const TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w900,
                      color: _inkColor,
                      letterSpacing: -2,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    downloader.formattedProgress,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _slateColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Live Speed & ETA badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.bolt_rounded, size: 14, color: _primaryGreen),
                        const SizedBox(width: 3),
                        Text(
                          isDownloading
                              ? downloader.formattedSpeed
                              : (isPaused ? 'Paused' : 'Connecting'),
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _primaryGreen),
                        ),
                        if (isDownloading) ...[
                          const SizedBox(width: 6),
                          const Text('•', style: TextStyle(color: _slateColor, fontSize: 10)),
                          const SizedBox(width: 6),
                          Text(
                            downloader.formattedEta,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: _slateColor),
                          ),
                        ],
                      ],
                    ),
                  ),
                ] else ...[
                  // Pure Idle state: 0%
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE2F3F0),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.auto_awesome_rounded, color: _primaryGreen, size: 30),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '0%',
                    style: TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w900,
                      color: _inkColor,
                      letterSpacing: -1.5,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Ready to Install',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _primaryGreen,
                    ),
                  ),
                  Text(
                    '${targetModel.formattedEstimatedSize} download',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Minimalist Bento feature row explaining why this model is great
  Widget _buildFeatureBentoCards() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildBentoCard(
                icon: Icons.image_search_rounded,
                title: 'Visual Photo Search',
                detail: 'Find pictures by scenes, colors, and objects naturally.',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildBentoCard(
                icon: Icons.document_scanner_outlined,
                title: 'Deep OCR Discovery',
                detail: 'Index text inside screenshots, receipts, and documents.',
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _buildBentoCard(
          icon: Icons.shield_outlined,
          title: '100% Private & Offline',
          detail: 'Zero bytes uploaded to servers. All AI vectors compute directly on your device NPU/GPU.',
          isFullWidth: true,
        ),
      ],
    );
  }

  Widget _buildBentoCard({
    required IconData icon,
    required String title,
    required String detail,
    bool isFullWidth = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: isFullWidth
          ? Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE2F3F0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: _primaryGreen, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _inkColor)),
                      const SizedBox(height: 2),
                      Text(detail, style: const TextStyle(fontSize: 11, color: _slateColor, height: 1.3)),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE2F3F0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: _primaryGreen, size: 20),
                ),
                const SizedBox(height: 10),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _inkColor)),
                const SizedBox(height: 3),
                Text(detail, style: const TextStyle(fontSize: 11, color: _slateColor, height: 1.3)),
              ],
            ),
    );
  }

  Widget _buildSpecsCard(ModelPreset targetModel, bool isDownloaded) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.memory_rounded, size: 16, color: _primaryGreen),
              const SizedBox(width: 8),
              Text(
                targetModel.filename,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: _inkColor),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
            decoration: BoxDecoration(
              color: isDownloaded ? const Color(0xFFD1FAE5) : Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              isDownloaded ? 'Verified' : '440 MB',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.bold,
                color: isDownloaded ? const Color(0xFF047857) : _slateColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Pinned bottom bar with prominent, responsive action buttons
  Widget _buildBottomActionBar({
    required ModelDownloaderService downloader,
    required bool isDownloaded,
    required bool isActiveInRam,
    required StoredModelInfo? existingModel,
  }) {
    final isDownloading = downloader.isDownloading;
    final isPaused = downloader.isPaused;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: const Color(0xFFE2E8F0))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        child: isDownloading
            ? Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _primaryGreen,
                        side: const BorderSide(color: _primaryGreen, width: 1.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: downloader.pauseDownload,
                      icon: const Icon(Icons.pause_rounded, size: 20),
                      label: const Text('Pause Download', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFEE2E2),
                      foregroundColor: const Color(0xFFDC2626),
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                    ),
                    onPressed: downloader.cancelDownload,
                    child: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              )
            : (isPaused
                ? Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primaryGreen,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: downloader.resumeDownload,
                          icon: const Icon(Icons.play_arrow_rounded, size: 20),
                          label: const Text('Resume Download', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFEE2E2),
                          foregroundColor: const Color(0xFFDC2626),
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                        ),
                        onPressed: downloader.cancelDownload,
                        child: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  )
                : (isDownloaded && existingModel != null
                    ? Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isActiveInRam ? const Color(0xFF059669) : _primaryGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: _isVerifying ? null : () => _verifyAndLoadToRam(existingModel),
                              icon: Icon(isActiveInRam ? Icons.refresh_rounded : Icons.memory_rounded, size: 20),
                              label: Text(
                                _isVerifying
                                    ? 'Verifying...'
                                    : (isActiveInRam ? 'Reload in RAM (${AiService.instance.activeBackend})' : 'Activate in RAM'),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFDC2626),
                              side: const BorderSide(color: Color(0xFFFECACA)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                            ),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: Colors.white,
                                  title: const Text('Delete Model File?'),
                                  content: const Text(
                                    'This will remove the downloaded AI model from device storage. You can re-download it anytime.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(ctx).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.of(ctx).pop(true),
                                      child: const Text('Delete', style: TextStyle(color: Colors.red)),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await ModelStorageService.instance.deleteModel(existingModel.path);
                                downloader.resetToIdle();
                                if (mounted) setState(() {});
                              }
                            },
                            child: const Icon(Icons.delete_outline_rounded, size: 20),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _primaryGreen,
                                foregroundColor: Colors.white,
                                elevation: 2,
                                shadowColor: _primaryGreen.withValues(alpha: 0.3),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                padding: const EdgeInsets.symmetric(vertical: 15),
                              ),
                              onPressed: _startTargetDownload,
                              icon: const Icon(Icons.download_rounded, size: 22),
                              label: const Text(
                                'Download & Activate Model (440 MB)',
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _pickLocalModelFile,
                            child: const Text(
                              'Have a local model? Tap here to select file from storage',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _primaryGreen,
                              ),
                            ),
                          ),
                        ],
                      ))),
      ),
    );
  }
}
