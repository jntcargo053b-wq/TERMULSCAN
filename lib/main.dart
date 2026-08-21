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
  Timer? _recoveryRetryTimer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startRecoveryRetryTimer();
  }

  void _startRecoveryRetryTimer() {
    _recoveryRetryTimer?.cancel();
    _recoveryRetryTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => unawaited(
        PhotoTaskRecoveryService.instance.recoverPending(),
      ),
    );
  }

  void _stopRecoveryRetryTimer() {
    _recoveryRetryTimer?.cancel();
    _recoveryRetryTimer = null;
  }

  @override
  void dispose() {
    _stopRecoveryRetryTimer();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startRecoveryRetryTimer();
      unawaited(PhotoTaskRecoveryService.instance.recoverPending());
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _stopRecoveryRetryTimer();
      // Pastikan perubahan log yang masih menunggu debounce tetap tersimpan
      // saat app pindah ke background / ditutup.
      unawaited(StorageService().flush());
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
