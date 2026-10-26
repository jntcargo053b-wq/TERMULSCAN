import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'watermark_settings.dart';
import '../theme/app_theme.dart';
import '../services/watermark_service.dart';

class WatermarkSettingsSheet extends StatefulWidget {
  const WatermarkSettingsSheet({super.key});

  @override
  State<WatermarkSettingsSheet> createState() => _WatermarkSettingsSheetState();
}

class _WatermarkSettingsSheetState extends State<WatermarkSettingsSheet> {
  final _settings = WatermarkSettings();
  final _operatorController = TextEditingController();
  final _picker = ImagePicker();
  bool _isSaving = false;
  String _selectedStyle = 'classic';
  String? _previewPath;
  String? _previewError;
  bool _isRefreshingPreview = false;
  int _previewRefreshToken = 0;

  @override
  void initState() {
    super.initState();
    _operatorController.text = _settings.operatorName;
    _selectedStyle = _settings.watermarkStyle;
    _settings.load().then((_) {
      if (!mounted) return;
      setState(() {
        _operatorController.text = _settings.operatorName;
        _selectedStyle = _settings.watermarkStyle;
      });
      _refreshPreview();
    });
  }

  @override
  void dispose() {
    _operatorController.dispose();
    super.dispose();
  }

  Future<void> _pickLogo() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (file == null) return;

    setState(() => _isSaving = true);
    try {
      // Salin logo ke direktori permanen app
      final appDir = await getApplicationDocumentsDirectory();
      final dest = '${appDir.path}/wm_logo.png';
      await File(file.path).copy(dest);

      // Path tujuan selalu sama (wm_logo.png) supaya "ganti logo" langsung
      // menimpa file lama. Tapi Flutter's ImageCache mengunci gambar
      // berdasarkan path saja, bukan isinya — kalau tidak di-evict, preview
      // & watermark bisa terus menampilkan logo LAMA walau file sudah
      // diganti. Evict dulu supaya widget berikutnya baca ulang dari disk.
      await FileImage(File(dest)).evict();

      await _settings.setLogoPath(dest);
      await _refreshPreview();
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _removeLogo() async {
    await _settings.setLogoPath(null);
    setState(() {});
    await _refreshPreview();
  }

  /// Render pratinjau menggunakan renderer bitmap yang sama dengan foto final.
  /// Dengan demikian posisi panel, font, wrapping, padding, dan logo mengikuti
  /// WatermarkService, bukan tiruan layout berbasis widget Flutter.
  Future<void> _refreshPreview() async {
    final token = ++_previewRefreshToken;
    if (mounted) {
      setState(() {
        _isRefreshingPreview = true;
        _previewError = null;
      });
    }

    File? destination;
    try {
      final tempDir = await getTemporaryDirectory();
      final source = File('${tempDir.path}/termulscan_watermark_preview_source.jpg');

      // Regenerasi sumber contoh jika file lama kosong/rusak. Sebelumnya file
      // yang sudah ada hanya diperiksa keberadaannya, sehingga file rusak dapat
      // membuat preview gagal selamanya dan spinner terus tampil.
      var sourceValid = false;
      if (await source.exists()) {
        try {
          final bytes = await source.readAsBytes();
          sourceValid = bytes.isNotEmpty && img.decodeImage(bytes) != null;
        } catch (_) {
          sourceValid = false;
        }
      }
      if (!sourceValid) {
        final sample = img.Image(width: 1024, height: 768);
        img.fill(sample, color: img.ColorRgb8(88, 108, 122));
        await source.writeAsBytes(img.encodeJpg(sample, quality: 85), flush: true);
      }

      Uint8List? logoBytes;
      if (_settings.hasLogo) {
        final logoFile = File(_settings.logoPath!);
        if (await logoFile.exists() && await logoFile.length() <= 512 * 1024) {
          logoBytes = await logoFile.readAsBytes();
        }
      }

      final operator = _operatorController.text.trim();
      final outputFile = File(
        '${tempDir.path}/termulscan_watermark_preview_${token}.jpg',
      );
      destination = outputFile;
      await WatermarkService.burn(
        sourcePath: source.path,
        destPath: outputFile.path,
        lines: [
          'WAKTU: 2026-10-26 08:30:00',
          'GPS: -7.966620, 112.632630',
          'ALAMAT: Jl. Contoh Gudang, Malang',
          'AWB: 8991234567890',
          if (operator.isNotEmpty) 'Operator: $operator',
        ],
        logoBytes: logoBytes,
        style: _selectedStyle,
      );

      // Pastikan hasil benar-benar bisa didekode sebelum menampilkannya.
      final outputBytes = await outputFile.readAsBytes();
      if (outputBytes.isEmpty || img.decodeImage(outputBytes) == null) {
        throw StateError('Hasil render preview kosong atau tidak valid.');
      }
      if (!mounted || token != _previewRefreshToken) {
        if (await outputFile.exists()) await outputFile.delete();
        return;
      }

      final previous = _previewPath;
      await FileImage(outputFile).evict();
      setState(() {
        _previewPath = outputFile.path;
        _previewError = null;
      });
      if (previous != null && previous != outputFile.path) {
        try {
          final previousFile = File(previous);
          if (await previousFile.exists()) await previousFile.delete();
        } catch (_) {}
      }
    } catch (e, stack) {
      debugPrint('Gagal membuat pratinjau watermark: $e');
      debugPrint('$stack');
      if (mounted && token == _previewRefreshToken) {
        setState(() {
          _previewError = 'Preview gagal dibuat. Tekan untuk mencoba lagi.';
        });
      }
      if (destination != null) {
        try {
          if (await destination.exists()) await destination.delete();
        } catch (_) {}
      }
    } finally {
      if (mounted && token == _previewRefreshToken) {
        setState(() => _isRefreshingPreview = false);
      }
    }
  }

  Future<void> _save() async {
    final name = _operatorController.text.trim();
    await _settings.setOperatorName(name);
    await _settings.setWatermarkStyle(_selectedStyle);
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✓ Pengaturan watermark disimpan'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight =
        media.size.height - media.viewInsets.bottom - media.padding.top - 16;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: media.viewInsets.bottom > 0 ? 8 : 12,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: availableHeight.clamp(240.0, media.size.height * 0.92),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
          // Handle bar
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textSecondary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Gap(16),

          // Header
          const Row(
            children: [
              Icon(Icons.tune, color: Colors.amber, size: 20),
              Gap(8),
              Text('Pengaturan Watermark',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  )),
            ],
          ),
          const Gap(4),
          const Text(
            'Tampil di setiap foto yang disimpan',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const Gap(20),

          // ── NAMA OPERATOR ──────────────────────────────────────────────
          const Text('NAMA OPERATOR',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              )),
          const Gap(8),
          TextField(
            controller: _operatorController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Contoh: Budi Santoso',
              hintStyle: const TextStyle(color: AppTheme.textSecondary),
              filled: true,
              fillColor: const Color(0xFF2A2A2A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.amber, width: 1.5),
              ),
              prefixIcon: const Icon(Icons.person_outline, color: AppTheme.textSecondary),
              suffixIcon: _operatorController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: AppTheme.textSecondary, size: 16),
                      onPressed: () {
                        _operatorController.clear();
                        setState(() {});
                      },
                    )
                  : null,
            ),
            onChanged: (_) {
              setState(() {});
              _refreshPreview();
            },
          ),
          const Gap(20),

          // ── LOGO PERUSAHAAN ────────────────────────────────────────────
          const Text('LOGO PERUSAHAAN',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              )),
          const Gap(8),

          if (_settings.hasLogo) ...[
            // Preview logo
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(
                      File(_settings.logoPath!),
                      width: 56,
                      height: 56,
                      fit: BoxFit.contain,
                      cacheWidth:
                          (56 * MediaQuery.of(context).devicePixelRatio)
                              .round(),
                      cacheHeight:
                          (56 * MediaQuery.of(context).devicePixelRatio)
                              .round(),
                    ),
                  ),
                  const Gap(12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Logo terpasang',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            )),
                        Gap(2),
                        Text('Logo berada di panel watermark',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                      ],
                    ),
                  ),
                  Column(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.amber, size: 18),
                        onPressed: _pickLogo,
                        tooltip: 'Ganti logo',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                        onPressed: _removeLogo,
                        tooltip: 'Hapus logo',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            // Tombol pilih logo
            GestureDetector(
              onTap: _isSaving ? null : _pickLogo,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 20),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.amber.withValues(alpha: 0.3),
                    style: BorderStyle.solid,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      _isSaving ? Icons.hourglass_empty : Icons.add_photo_alternate_outlined,
                      color: Colors.amber,
                      size: 32,
                    ),
                    const Gap(8),
                    Text(
                      _isSaving ? 'Memproses...' : 'Pilih dari Galeri',
                      style: const TextStyle(
                        color: Colors.amber,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Gap(2),
                    const Text(
                      'PNG/JPG · Disarankan background transparan',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const Gap(20),

          const Text('MODEL WATERMARK',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              )),
          const Gap(8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: (MediaQuery.of(context).size.width - 64) / 3,
                child: _WatermarkStyleOption(
                  title: 'Classic',
                  subtitle: 'Panel bawah',
                  style: 'classic',
                  selected: _selectedStyle == 'classic',
                  onTap: () { setState(() => _selectedStyle = 'classic'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: (MediaQuery.of(context).size.width - 64) / 3,
                child: _WatermarkStyleOption(
                  title: 'Compact',
                  subtitle: 'Panel kanan',
                  style: 'compact',
                  selected: _selectedStyle == 'compact',
                  onTap: () { setState(() => _selectedStyle = 'compact'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: (MediaQuery.of(context).size.width - 64) / 3,
                child: _WatermarkStyleOption(
                  title: 'Header',
                  subtitle: 'Bagian atas',
                  style: 'top',
                  selected: _selectedStyle == 'top',
                  onTap: () { setState(() => _selectedStyle = 'top'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: (MediaQuery.of(context).size.width - 64) / 3,
                child: _WatermarkStyleOption(
                  title: 'Modern',
                  subtitle: 'Aksen cyan',
                  style: 'modern',
                  selected: _selectedStyle == 'modern',
                  onTap: () { setState(() => _selectedStyle = 'modern'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: (MediaQuery.of(context).size.width - 64) / 3,
                child: _WatermarkStyleOption(
                  title: 'Minimal',
                  subtitle: 'Ringkas kiri',
                  style: 'minimal',
                  selected: _selectedStyle == 'minimal',
                  onTap: () { setState(() => _selectedStyle = 'minimal'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: (MediaQuery.of(context).size.width - 64) / 3,
                child: _WatermarkStyleOption(
                  title: 'Badge',
                  subtitle: 'Aksen amber',
                  style: 'badge',
                  selected: _selectedStyle == 'badge',
                  onTap: () { setState(() => _selectedStyle = 'badge'); _refreshPreview(); },
                ),
              ),
            ],
          ),
          const Gap(8),
          const Text(
            'Model berlaku untuk foto baru dan pemulihan watermark yang tertunda.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
          ),
          const Gap(20),

          // Gambar pratinjau dihasilkan oleh WatermarkService yang sama dengan foto final.
          Container(
            width: double.infinity,
            height: 218,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            child: _previewPath != null
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(_previewPath!),
                        key: ValueKey(_previewPath),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Center(
                          child: TextButton.icon(
                            onPressed: _refreshPreview,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Muat ulang preview'),
                          ),
                        ),
                      ),
                      if (_isRefreshingPreview)
                        const Positioned(
                          right: 8,
                          top: 8,
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.amber,
                            ),
                          ),
                        ),
                    ],
                  )
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _previewError == null
                                ? Icons.image_search_outlined
                                : Icons.warning_amber_rounded,
                            color: Colors.amber,
                            size: 30,
                          ),
                          const Gap(8),
                          Text(
                            _previewError ?? 'Sedang membuat preview watermark…',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const Gap(8),
                          if (_previewError != null)
                            TextButton.icon(
                              onPressed: _refreshPreview,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Coba lagi'),
                            )
                          else
                            const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.amber,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
          ),

                    ],
                  ),
                ),
              ),
              const Gap(12),

              // Tombol simpan tetap terlihat; konten di atas dapat digulir.
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _save,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text(
                    'Simpan Pengaturan',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WatermarkStyleOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final String style;
  final bool selected;
  final VoidCallback onTap;

  const _WatermarkStyleOption({
    required this.title,
    required this.subtitle,
    required this.style,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: selected ? Colors.amber.withValues(alpha: 0.12) : const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? Colors.amber : Colors.white12,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 48,
              width: double.infinity,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF71818B), Color(0xFF303941)],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: style == 'compact' || style == 'badge' ? null : (style == 'modern' ? 3 : 0),
                      right: style == 'modern' ? 3 : 0,
                      top: style == 'top' ? 0 : null,
                      bottom: style == 'top' ? null : 0,
                      child: Container(
                        width: style == 'compact' || style == 'badge' || style == 'minimal' ? 35 : null,
                        height: style == 'compact' || style == 'badge' || style == 'minimal' ? 30 : 14,
                        padding: const EdgeInsets.all(3),
                        color: Colors.black.withValues(alpha: 0.78),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(height: 2, width: style == 'compact' || style == 'badge' || style == 'minimal' ? 23 : 38, color: style == 'badge' ? Colors.amber : Colors.white),
                            const SizedBox(height: 3),
                            Container(height: 2, width: style == 'compact' || style == 'badge' || style == 'minimal' ? 27 : 52, color: Colors.white70),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Gap(6),
            Text(title, style: TextStyle(color: selected ? Colors.amber : Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
            const Gap(2),
            Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 9)),
          ],
        ),
      ),
    );
  }
}