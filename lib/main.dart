import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'router/app_router.dart';
import 'services/preferences_service.dart';
import 'services/model_downloader_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PreferencesService.instance.init();

  // 1. Initialize persistent background downloader database tracking
  await FileDownloader().start(autoCleanDatabase: true);

  // 2. Configure native Android system notification with progress bar
  FileDownloader().configureNotification(
    running: const TaskNotification(
      'Downloading AI Model',
      'Downloading {filename} • {progress}',
    ),
    complete: const TaskNotification(
      'AI Model Download Complete',
      '{filename} is ready for on-device visual search',
    ),
    paused: const TaskNotification(
      'AI Model Download Paused',
      'Tap to resume downloading {filename}',
    ),
    error: const TaskNotification(
      'Download Interrupted',
      'Tap to retry downloading AI model',
    ),
    progressBar: true,
    tapOpensFile: false,
  );

  // 3. Initialize downloader listener and reconnect to any active background downloads
  await ModelDownloaderService.instance.initBackgroundDownloader();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Pipit Vision Search',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF15786C),
      ),
      routerConfig: appRouter,
    );
  }
}
