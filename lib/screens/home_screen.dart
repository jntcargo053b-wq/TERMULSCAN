import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import 'barcode_scan_screen.dart';
import 'photo_scan_screen.dart';
import 'log_screen.dart';
import 'watermark_settings.dart';
import 'watermark_settings_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _storage = StorageService();
  final _loc = LocationService();
  final _wmSettings = WatermarkSettings();

  int _totalScans = 0;
  int _barcodeCount = 0;
  int _photoCount = 0;
  List<ScanEntry> _recent = [];

  String? _locationLabel;
  bool _locLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _initPermissionsAndLocation();
    // Sebelumnya WatermarkSettings cuma di-load di BarcodeScanScreen —
    // icon setting di Home butuh datanya juga (untuk badge), jadi di-load
    // di sini tanpa menunggu user masuk ke alur scan/foto dulu.
    _wmSettings.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _initPermissionsAndLocation() async {
    try {
      await Permission.camera.request();
      final loc = await _loc.getLocation();
      if (!mounted) return;
      setState(() {
        _locationLabel = loc.address ?? (loc.lat != null
            ? '${loc.lat!.toStringAsFixed(4)}, ${loc.lng!.toStringAsFixed(4)}'
            : 'GPS tidak tersedia');
        _locLoading = false;
      });
    } catch (_) {
      // Plugin permission/location tidak selalu tersedia di test/widget
      // environment. Gagal mengakses hardware tidak boleh membuat Home crash.
      if (!mounted) return;
      setState(() {
        _locationLabel = 'GPS tidak tersedia';
        _locLoading = false;
      });
    }
  }
  Future<void> _loadStats() async {
    final all = await _storage.loadAll();
    if (mounted) {
      setState(() {
        _totalScans = all.length;
        _barcodeCount = all.where((e) => e.isBarcode).length;
        _photoCount = all.where((e) => e.isPhoto).length;
        _recent = all.take(5).toList();
      });
    }
  }

  Future<void> _openBarcode() async {
    // BarcodeScanScreen tidak selalu pop dengan nilai (tombol back bawaan
    // AppBar pop dengan null), jadi refresh statistik tanpa syarat —
    // sama seperti _openLog() di bawah — supaya Home selalu sinkron
    // dengan data terbaru setelah sesi scan.
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BarcodeScanScreen()),
    );
    _loadStats();
  }

  Future<void> _openPhoto() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PhotoScanScreen()),
    );
    _loadStats();
  }

  Future<void> _openLog() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LogScreen()),
    );
    _loadStats();
  }

  void _openWatermarkSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const WatermarkSettingsSheet(),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadStats,
          color: AppTheme.accent,
          backgroundColor: AppTheme.surface,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _buildHeader()),
              SliverToBoxAdapter(child: _buildLocationBar()),
              SliverToBoxAdapter(child: _buildStatsRow()),
              SliverToBoxAdapter(child: _buildScanButtons()),
              SliverToBoxAdapter(child: _buildRecentSection()),
              const SliverToBoxAdapter(child: Gap(32)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8, height: 8,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: const BoxDecoration(
                      color: AppTheme.accent,
                      shape: BoxShape.circle,
                    ),
                  ).animate(
                    onPlay: (c) => c.repeat(),
                  ).fade(begin: 1, end: 0.2, duration: 1000.ms),
                  const Text('TERMULSCAN',
                      style: TextStyle(
                        color: AppTheme.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      )),
                ],
              ),
              const Gap(4),
              const Text('Scanner Gudang & Ekspedisi',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  )),
            ],
          ).animate().fadeIn().slideX(begin: -0.1),
          const Spacer(),
          IconButton(
            onPressed: _openLog,
            icon: Stack(
              children: [
                const Icon(Icons.history, color: AppTheme.textSecondary, size: 26),
                if (_totalScans > 0)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                          color: AppTheme.accent, shape: BoxShape.circle),
                      child: Center(
                        child: Text(
                          _totalScans > 99 ? '99+' : '$_totalScans',
                          style: const TextStyle(
                              color: Colors.black,
                              fontSize: 7,
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ).animate().fadeIn(delay: 200.ms),
          const Gap(4),
          IconButton(
            onPressed: _openWatermarkSettings,
            icon: Stack(
              children: [
                const Icon(Icons.tune, color: AppTheme.textSecondary, size: 26),
                if (_wmSettings.operatorName.isNotEmpty || _wmSettings.hasLogo)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: AppTheme.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            tooltip: 'Pengaturan Watermark',
          ).animate().fadeIn(delay: 220.ms),
        ],
      ),
    );
  }

  Widget _buildLocationBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Icon(
            _locLoading ? Icons.location_searching : Icons.location_on,
            size: 14,
            color: _locLoading ? AppTheme.textSecondary : Colors.greenAccent.shade400,
          ),
          const Gap(8),
          Expanded(
            child: Text(
              _locLoading ? 'Mencari lokasi...' : (_locationLabel ?? 'GPS tidak tersedia'),
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 14, color: AppTheme.textSecondary),
            onPressed: _initPermissionsAndLocation,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 100.ms);
  }

  Widget _buildStatsRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          _StatCard(
            label: 'Total Scan',
            value: '$_totalScans',
            icon: Icons.analytics_outlined,
            color: AppTheme.accentBlue,
          ),
          const Gap(10),
          _StatCard(
            label: 'Barcode',
            value: '$_barcodeCount',
            icon: Icons.qr_code_scanner,
            color: AppTheme.accent,
          ),
          const Gap(10),
          _StatCard(
            label: 'Foto',
            value: '$_photoCount',
            icon: Icons.camera_alt_outlined,
            color: AppTheme.accentOrange,
          ),
        ],
      ),
    ).animate().fadeIn(delay: 150.ms);
  }

  Widget _buildScanButtons() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('MULAI SCAN',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              )),
          const Gap(12),
          _PrimaryScanButton(
            icon: Icons.qr_code_scanner,
            label: 'Scan Barcode',
            sublabel: 'Scan AWB untuk mulai proses',
            onTap: _openBarcode,
          ),
          const Gap(10),
          _SecondaryScanButton(
            icon: Icons.camera_alt_outlined,
            label: 'Ambil Foto',
            sublabel: 'Kamera atau galeri',
            onTap: _openPhoto,
          ),
        ],
      ),
    ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.05);
  }

  Widget _buildRecentSection() {
    if (_recent.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('SCAN TERAKHIR',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  )),
              GestureDetector(
                onTap: _openLog,
                child: const Text('Lihat Semua →',
                    style: TextStyle(
                        color: AppTheme.accentBlue, fontSize: 12)),
              ),
            ],
          ),
          const Gap(12),
          ...List.generate(
            _recent.length,
            (i) => _RecentItem(entry: _recent[i])
                .animate()
                .fadeIn(delay: Duration(milliseconds: 250 + i * 60))
                .slideX(begin: 0.05),
          ),
        ],
      ),
    );
  }
}

// ── Stat card ─────────────────────────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const Gap(8),
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            Text(label,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ── Primary / secondary scan actions ──────────────────────────────────────
class _PrimaryScanButton extends StatelessWidget {
  final IconData icon;
  final String label, sublabel;
  final VoidCallback onTap;

  const _PrimaryScanButton({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.accent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: Colors.black, size: 25),
              ),
              const Gap(13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(color: Colors.black, fontSize: 16, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(sublabel, style: const TextStyle(color: Colors.black87, fontSize: 11)),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_rounded, color: Colors.black, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecondaryScanButton extends StatelessWidget {
  final IconData icon;
  final String label, sublabel;
  final VoidCallback onTap;

  const _SecondaryScanButton({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Icon(icon, color: AppTheme.accentOrange, size: 24),
              const Gap(13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(sublabel, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Recent item ────────────────────────────────────────────────────────────
class _RecentItem extends StatelessWidget {
  final ScanEntry entry;
  const _RecentItem({required this.entry});

  @override
  Widget build(BuildContext context) {
    final color = entry.isBarcode ? AppTheme.accent : AppTheme.accentOrange;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          _RecentThumbnail(entry: entry, color: color),
          const Gap(10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.isBarcode
                      ? entry.value
                      : (entry.scanResult?.trim().isNotEmpty == true
                          ? entry.scanResult!
                          : 'Foto tanpa barcode'),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${entry.timestampShort}  •  ${entry.locationName ?? entry.coordinatesString}',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 10,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Gap(6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entry.isBarcode ? (entry.barcodeFormat ?? 'BC') : 'IMG',
              style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentThumbnail extends StatelessWidget {
  final ScanEntry entry;
  final Color color;

  const _RecentThumbnail({required this.entry, required this.color});

  @override
  Widget build(BuildContext context) {
    if (!entry.isPhoto) {
      return _placeholder(Icons.qr_code_scanner);
    }

    return FutureBuilder<String?>(
      future: StorageService().resolveImagePath(entry),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _placeholder(Icons.image_outlined, loading: true);
        }
        final path = snapshot.data;
        if (path == null || path.isEmpty) {
          return _placeholder(Icons.broken_image_outlined);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(path),
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            cacheWidth: 144,
            errorBuilder: (_, __, ___) => _placeholder(Icons.broken_image_outlined),
          ),
        );
      },
    );
  }

  Widget _placeholder(IconData icon, {bool loading = false}) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: loading
          ? const Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Icon(icon, color: color, size: 20),
    );
  }
}
