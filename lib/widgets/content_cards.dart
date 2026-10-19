import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/media_collector_service.dart';
import '../services/device_info_service.dart';

/// Reusable distinct Text Content Card (Used for SMS cards, Text documents, and PDF cards)
/// Single square card (aspect ratio 1.0) with borderRadius: 23, elevation: 0.
/// Top row contains the type icon on left, and title + subtitle right next to the icon.
/// Bottom 50% has a smooth white gradient fader.
class TextContentCard extends StatelessWidget {
  final String title;
  final String textContent;
  final String typeLabel;
  final Color typeColor;
  final IconData typeIcon;
  final String? subtitle;
  final DateTime? timestamp;
  final VoidCallback? onTap;
  final Widget? topTrailing;

  const TextContentCard({
    super.key,
    required this.title,
    required this.textContent,
    required this.typeLabel,
    required this.typeColor,
    required this.typeIcon,
    this.subtitle,
    this.timestamp,
    this.onTap,
    this.topTrailing,
  });

  String _formatDate(DateTime dt) {
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

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(23),
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
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top Row: Icon on left, title & subtitle right next to it, timestamp on right
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(5.5),
                          decoration: BoxDecoration(
                            color: typeColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(typeIcon, size: 15, color: typeColor),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12.5,
                                  color: Color(0xFF1E293B),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (subtitle != null && subtitle!.isNotEmpty) ...[
                                const SizedBox(height: 1.5),
                                Text(
                                  subtitle!,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.grey.shade600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (topTrailing != null) ...[
                          const SizedBox(width: 4),
                          topTrailing!,
                        ],
                        if (timestamp != null && timestamp!.millisecondsSinceEpoch > 0) ...[
                          const SizedBox(width: 4),
                          Text(
                            _formatDate(timestamp!),
                            style: TextStyle(
                              fontSize: 9.0,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Text Content directly on the card
                    Expanded(
                      child: Text(
                        textContent.trim().isNotEmpty
                            ? textContent.trim()
                            : 'No text content available',
                        style: TextStyle(
                          fontSize: 11.5,
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
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(23),
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

            // 3. Ripple InkWell
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(23),
                  onTap: onTap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Separate Contact Card Widget
/// 100% identical styling to the SMS/messages and document card.
class ContactCardWidget extends StatelessWidget {
  final DeviceContact contact;
  final VoidCallback? onTap;
  final VoidCallback? onCopy;

  const ContactCardWidget({
    super.key,
    required this.contact,
    this.onTap,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return TextContentCard(
      title: contact.name.trim().isNotEmpty ? contact.name : 'Unknown Contact',
      subtitle: contact.number.trim().isNotEmpty ? contact.number : 'No number',
      textContent: contact.name,
      typeLabel: 'CONTACT',
      typeColor: const Color(0xFF15786C),
      typeIcon: Icons.person,
      topTrailing: IconButton(
        icon: const Icon(
          Icons.copy,
          size: 13,
          color: Color(0xFF15786C),
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        tooltip: 'Copy Number',
        onPressed: onCopy ??
            () {
              Clipboard.setData(ClipboardData(text: contact.number));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Copied ${contact.number}')),
              );
            },
      ),
      onTap: onTap,
    );
  }
}

/// Separate SMS Card Widget
class SmsCardWidget extends StatelessWidget {
  final DeviceSms sms;
  final VoidCallback? onTap;

  const SmsCardWidget({
    super.key,
    required this.sms,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSent = sms.type == 'Sent';
    return TextContentCard(
      title: sms.address,
      subtitle: '${sms.type} Message',
      textContent: sms.body,
      typeLabel: sms.type,
      typeColor: isSent ? const Color(0xFF1E88E5) : const Color(0xFF15786C),
      typeIcon: isSent ? Icons.outbox : Icons.inbox,
      timestamp: sms.date,
      onTap: onTap,
    );
  }
}

/// Separate Video Card Widget
class VideoCardWidget extends StatelessWidget {
  final DeviceVideo video;
  final int? rank;
  final VoidCallback? onTap;

  const VideoCardWidget({
    super.key,
    required this.video,
    this.rank,
    this.onTap,
  });

  String _formatDate(DateTime dt) {
    if (dt.millisecondsSinceEpoch <= 0) return '';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(23),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(23),
            onTap: onTap,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(5.5),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.videocam,
                                size: 15,
                                color: Colors.red.shade700,
                              ),
                            ),
                            const Spacer(),
                            if (video.modifiedDate.millisecondsSinceEpoch > 0)
                              Text(
                                _formatDate(video.modifiedDate),
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          video.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Color(0xFF1E293B),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${(video.fileSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                ),

                // 50% bottom fader
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 0.50,
                    widthFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(23),
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
}

/// Separate Audio Card Widget
class AudioCardWidget extends StatelessWidget {
  final DeviceAudio audio;
  final int? rank;
  final VoidCallback? onTap;

  const AudioCardWidget({
    super.key,
    required this.audio,
    this.rank,
    this.onTap,
  });

  String _formatDate(DateTime dt) {
    if (dt.millisecondsSinceEpoch <= 0) return '';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(23),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(23),
            onTap: onTap,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(5.5),
                              decoration: BoxDecoration(
                                color: Colors.deepPurple.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.audiotrack,
                                size: 15,
                                color: Colors.deepPurple.shade700,
                              ),
                            ),
                            const Spacer(),
                            if (audio.modifiedDate.millisecondsSinceEpoch > 0)
                              Text(
                                _formatDate(audio.modifiedDate),
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          audio.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Color(0xFF1E293B),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${(audio.fileSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                ),

                // 50% bottom fader
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 0.50,
                    widthFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(23),
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
}

/// Separate Image / Photo Card Widget
class PhotoCardWidget extends StatelessWidget {
  final String imagePath;
  final double? score;
  final int? rank;
  final VoidCallback? onTap;

  const PhotoCardWidget({
    super.key,
    required this.imagePath,
    this.score,
    this.rank,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(23),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(23),
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(imagePath),
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                  cacheWidth: 400,
                  filterQuality: FilterQuality.low,
                  frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                    if (wasSynchronouslyLoaded) return child;
                    return AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      child: child,
                    );
                  },
                  errorBuilder: (context, error, stackTrace) => Container(
                    color: Colors.grey.shade200,
                    child: Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.grey.shade400,
                        size: 36,
                      ),
                    ),
                  ),
                ),

                // Top left photo icon
                Positioned(
                  top: 12,
                  left: 14,
                  child: Container(
                    padding: const EdgeInsets.all(5.5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.photo_library_outlined,
                      size: 14,
                      color: Colors.white,
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
}
