import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class DeviceContact {
  final String id;
  final String name;
  final String number;

  const DeviceContact({
    required this.id,
    required this.name,
    required this.number,
  });

  factory DeviceContact.fromMap(Map<dynamic, dynamic> map) {
    return DeviceContact(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Unknown',
      number: map['number']?.toString() ?? '',
    );
  }
}

class DeviceCallLog {
  final String id;
  final String name;
  final String number;
  final String type; // 'Incoming', 'Outgoing', 'Missed', etc.
  final DateTime date;
  final int duration; // in seconds

  const DeviceCallLog({
    required this.id,
    required this.name,
    required this.number,
    required this.type,
    required this.date,
    required this.duration,
  });

  factory DeviceCallLog.fromMap(Map<dynamic, dynamic> map) {
    final timestamp = (map['date'] as num?)?.toInt() ?? 0;
    return DeviceCallLog(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      number: map['number']?.toString() ?? '',
      type: map['type']?.toString() ?? 'Unknown',
      date: DateTime.fromMillisecondsSinceEpoch(timestamp),
      duration: (map['duration'] as num?)?.toInt() ?? 0,
    );
  }
}

class DeviceSms {
  final String id;
  final String address;
  final String body;
  final DateTime date;
  final String type; // 'Inbox', 'Sent'
  final bool isProcessed;

  const DeviceSms({
    required this.id,
    required this.address,
    required this.body,
    required this.date,
    required this.type,
    this.isProcessed = false,
  });

  factory DeviceSms.fromMap(Map<dynamic, dynamic> map) {
    final timestamp = (map['date'] as num?)?.toInt() ?? 0;
    return DeviceSms(
      id: map['id']?.toString() ?? '',
      address: map['address']?.toString() ?? '',
      body: map['body']?.toString() ?? '',
      date: DateTime.fromMillisecondsSinceEpoch(timestamp),
      type: map['type']?.toString() ?? 'Inbox',
      isProcessed: map['is_processed'] == 1 ||
          map['is_processed'] == true ||
          map['isProcessed'] == true,
    );
  }
}

class DeviceApp {
  final String name;
  final String packageName;
  final String version;
  final bool isSystemApp;
  final String category;

  const DeviceApp({
    required this.name,
    required this.packageName,
    required this.version,
    required this.isSystemApp,
    this.category = 'Application',
  });

  factory DeviceApp.fromMap(Map<dynamic, dynamic> map) {
    return DeviceApp(
      name: map['name']?.toString() ?? 'Unknown App',
      packageName: map['packageName']?.toString() ?? '',
      version: map['version']?.toString() ?? '',
      isSystemApp: (map['isSystemApp'] as bool?) ?? false,
      category: map['category']?.toString() ?? 'Application',
    );
  }
}

/// Service that accesses device contacts, call logs, SMS, and installed/system apps.
class DeviceInfoService {
  DeviceInfoService._internal();
  static final DeviceInfoService instance = DeviceInfoService._internal();

  static const MethodChannel _channel = MethodChannel('com.example.pipit/device_data');

  /// Fetch contacts from device
  Future<List<DeviceContact>> getContacts() async {
    try {
      final status = await Permission.contacts.request();
      if (!status.isGranted) {
        debugPrint('[DeviceInfoService] Contacts permission denied.');
        return [];
      }

      final List<dynamic>? raw = await _channel.invokeMethod('getContacts');
      if (raw == null) return [];
      return raw.map((e) => DeviceContact.fromMap(Map<dynamic, dynamic>.from(e as Map))).toList();
    } catch (e) {
      debugPrint('[DeviceInfoService] Error getting contacts: $e');
      return [];
    }
  }

  /// Fetch call logs from device
  Future<List<DeviceCallLog>> getCallLogs() async {
    try {
      final status = await Permission.phone.request();
      if (!status.isGranted) {
        debugPrint('[DeviceInfoService] Phone permission denied for call logs.');
      }

      final List<dynamic>? raw = await _channel.invokeMethod('getCallLogs');
      if (raw == null) return [];
      return raw.map((e) => DeviceCallLog.fromMap(Map<dynamic, dynamic>.from(e as Map))).toList();
    } catch (e) {
      debugPrint('[DeviceInfoService] Error getting call logs: $e');
      return [];
    }
  }

  /// Fetch SMS messages from device
  Future<List<DeviceSms>> getSms() async {
    try {
      final status = await Permission.sms.request();
      if (!status.isGranted) {
        debugPrint('[DeviceInfoService] SMS permission denied.');
        return [];
      }

      final List<dynamic>? raw = await _channel.invokeMethod('getSms');
      if (raw == null) return [];
      return raw.map((e) => DeviceSms.fromMap(Map<dynamic, dynamic>.from(e as Map))).toList();
    } catch (e) {
      debugPrint('[DeviceInfoService] Error getting SMS: $e');
      return [];
    }
  }

  /// Fetch installed and system applications
  Future<List<DeviceApp>> getInstalledApps() async {
    try {
      final List<dynamic>? raw = await _channel.invokeMethod('getInstalledApps');
      if (raw == null) return [];
      return raw.map((e) => DeviceApp.fromMap(Map<dynamic, dynamic>.from(e as Map))).toList();
    } catch (e) {
      debugPrint('[DeviceInfoService] Error getting installed apps: $e');
      return [];
    }
  }

  /// Open a file in the default system viewer app
  Future<bool> openFile(String path, {String? mimeType}) async {
    try {
      final res = await _channel.invokeMethod<bool>('openFile', {
        'path': path,
        if (mimeType != null) 'mimeType': mimeType,
      });
      return res ?? false;
    } catch (e) {
      debugPrint('[DeviceInfoService] Error opening file: $e');
      return false;
    }
  }

  /// Launch an installed application by its package name
  Future<bool> openApp(String packageName) async {
    try {
      final res = await _channel.invokeMethod<bool>('openApp', {
        'packageName': packageName,
      });
      return res ?? false;
    } catch (e) {
      debugPrint('[DeviceInfoService] Error opening app: $e');
      return false;
    }
  }

  /// Open an SMS message or thread in the default SMS app
  Future<bool> openSms({required String address, String? body}) async {
    try {
      final res = await _channel.invokeMethod<bool>('openSms', {
        'address': address,
        if (body != null) 'body': body,
      });
      return res ?? false;
    } catch (e) {
      debugPrint('[DeviceInfoService] Error opening SMS: $e');
      return false;
    }
  }

  /// Open a contact in the default dialer or contacts app
  Future<bool> openContact({required String number}) async {
    try {
      final res = await _channel.invokeMethod<bool>('openContact', {
        'number': number,
      });
      return res ?? false;
    } catch (e) {
      debugPrint('[DeviceInfoService] Error opening contact: $e');
      return false;
    }
  }

  /// Fetch real app icon PNG bytes
  Future<Uint8List?> getAppIcon(String packageName) async {
    try {
      final res = await _channel.invokeMethod<Uint8List>('getAppIcon', {
        'packageName': packageName,
      });
      return res;
    } catch (e) {
      debugPrint('[DeviceInfoService] Error getting app icon: $e');
      return null;
    }
  }
}

/// Global In-Memory App Icon Cache
class AppIconService {
  AppIconService._internal();
  static final AppIconService instance = AppIconService._internal();

  final Map<String, Uint8List?> _cache = {};
  final Map<String, Future<Uint8List?>> _inFlight = {};

  Future<Uint8List?> getIcon(String packageName) async {
    if (_cache.containsKey(packageName)) {
      return _cache[packageName];
    }
    if (_inFlight.containsKey(packageName)) {
      return _inFlight[packageName]!;
    }
    final future = DeviceInfoService.instance.getAppIcon(packageName).then((bytes) {
      _cache[packageName] = bytes;
      _inFlight.remove(packageName);
      return bytes;
    });
    _inFlight[packageName] = future;
    return future;
  }

  Uint8List? getCachedIcon(String packageName) => _cache[packageName];
}

/// Widget that displays the real app icon with fallback
class AppIconWidget extends StatefulWidget {
  final String packageName;
  final double size;
  final Color fallbackColor;
  final Color fallbackBg;

  const AppIconWidget({
    super.key,
    required this.packageName,
    this.size = 40,
    this.fallbackColor = const Color(0xFF15786C),
    this.fallbackBg = const Color(0xFFE6F4F1),
  });

  @override
  State<AppIconWidget> createState() => _AppIconWidgetState();
}

class _AppIconWidgetState extends State<AppIconWidget> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  @override
  void didUpdateWidget(covariant AppIconWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packageName != widget.packageName) {
      _loadIcon();
    }
  }

  void _loadIcon() {
    final cached = AppIconService.instance.getCachedIcon(widget.packageName);
    if (cached != null) {
      _bytes = cached;
      return;
    }
    AppIconService.instance.getIcon(widget.packageName).then((bytes) {
      if (mounted) {
        setState(() {
          _bytes = bytes;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null && _bytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.size * 0.24),
        child: Image.memory(
          _bytes!,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.fallbackBg,
        borderRadius: BorderRadius.circular(widget.size * 0.24),
      ),
      child: Center(
        child: Icon(
          Icons.apps,
          size: widget.size * 0.55,
          color: widget.fallbackColor,
        ),
      ),
    );
  }
}
