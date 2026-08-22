import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'services/storage_service.dart';
import 'services/photo_task_recovery_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Tanpa ini, riwayat scan yang tersimpan tidak pernah dimuat balik dari
  // disk — StorageService akan selalu tampak kosong setiap app dibuka ulang.
  await StorageService().init();
  // Lanjutkan foto yang tertinggal saat Android menghentikan proses ketika
  // GPS/reverse-geocode/watermark masih berjalan. Tidak memblokir UI startup.
  unawaited(PhotoTaskRecoveryService.instance.recoverPending());
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.bg,
  ));
  runApp(const WHScannerApp());
}

class WHScannerApp extends StatefulWidget {
  const WHScannerApp({super.key});

  @override
  State<WHScannerApp> createState() => _WHScannerAppState();
}

class _WHScannerAppState extends State<WHScannerApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pastikan perubahan log yang masih menunggu debounce tetap tersimpan
    // saat app pindah ke background / ditutup.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      StorageService().flush();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WH Scanner',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const HomeScreen(),
    );
  }
}
