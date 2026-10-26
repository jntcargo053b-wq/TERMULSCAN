import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'watermark_settings.dart';
import '../theme/app_theme.dart';

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
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _removeLogo() async {
    await _settings.setLogoPath(null);
    setState(() {});
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
    // Foto kamera/galeri dibatasi maxWidth 1024 px. Samakan preview dengan
    // skala watermark yang akan terlihat saat foto ditampilkan di layar.
    final previewScale = ((media.size.width - 64) / 1024).clamp(0.2, 0.5).toDouble();
    final previewFontSize = 24 * previewScale;
    final previewPadding =
        (16 * (1024 / 1080) * previewScale).round().clamp(3, 8);
    final previewLineGap =
        (5 * (1024 / 1080) * previewScale).round().clamp(1, 3);
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
            onChanged: (_) => setState(() {}),
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
          Row(
            children: [
              Expanded(
                child: _WatermarkStyleOption(
                  title: 'Classic',
                  subtitle: 'Panel bawah',
                  style: 'classic',
                  selected: _selectedStyle == 'classic',
                  onTap: () => setState(() => _selectedStyle = 'classic'),
                ),
              ),
              const Gap(8),
              Expanded(
                child: _WatermarkStyleOption(
                  title: 'Compact',
                  subtitle: 'Sudut kanan',
                  style: 'compact',
                  selected: _selectedStyle == 'compact',
                  onTap: () => setState(() => _selectedStyle = 'compact'),
                ),
              ),
              const Gap(8),
              Expanded(
                child: _WatermarkStyleOption(
                  title: 'Header',
                  subtitle: 'Bagian atas',
                  style: 'top',
                  selected: _selectedStyle == 'top',
                  onTap: () => setState(() => _selectedStyle = 'top'),
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

          // Pratinjau mengikuti model yang dipilih; sebelumnya selalu panel bawah.
          Container(
            width: double.infinity,
            height: 218,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF667786), Color(0xFF39434D), Color(0xFF22282D)],
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'CONTOH HASIL FOTO',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: _selectedStyle == 'compact' ? null : 0,
                  right: 0,
                  top: _selectedStyle == 'top' ? 0 : null,
                  bottom: _selectedStyle == 'top' ? null : 0,
                  // Panel compact mengikuti lebar isi watermark, bukan
                  // lebar tetap yang membuat pratinjau tampak terlalu besar.
                  width: _selectedStyle == 'compact' ? null : null,
                  child: Container(
                    padding: EdgeInsets.all(previewPadding.toDouble()),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_settings.hasLogo) ...[
                          Align(
                            alignment: Alignment.centerRight,
                            child: Image.file(
                              File(_settings.logoPath!),
                              width: 26,
                              height: 18,
                              fit: BoxFit.contain,
                              cacheWidth: (44 * MediaQuery.of(context).devicePixelRatio).round(),
                              cacheHeight: (30 * MediaQuery.of(context).devicePixelRatio).round(),
                            ),
                          ),
                          SizedBox(height: previewLineGap.toDouble()),
                        ],
                        _PreviewLine(
                          text: 'WAKTU: 2026-10-26 08:30:00',
                          color: Colors.white,
                          icon: Icons.access_time,
                          fontSize: previewFontSize,
                        ),
                        SizedBox(height: previewLineGap.toDouble()),
                        _PreviewLine(
                          text: 'GPS: -7.966620, 112.632630',
                          color: Colors.white,
                          icon: Icons.my_location,
                          fontSize: previewFontSize,
                        ),
                        SizedBox(height: previewLineGap.toDouble()),
                        _PreviewLine(
                          text: 'ALAMAT: Jl. Contoh Gudang, Malang',
                          color: Colors.white70,
                          icon: Icons.location_on,
                          fontSize: previewFontSize,
                        ),
                        SizedBox(height: previewLineGap.toDouble()),
                        _PreviewLine(
                          text: 'AWB: 8991234567890',
                          color: Colors.white,
                          icon: Icons.qr_code,
                          fontSize: previewFontSize,
                        ),
                        if (_operatorController.text.trim().isNotEmpty) ...[
                          const Gap(3),
                          _PreviewLine(
                            text: 'Operator: ${_operatorController.text.trim()}',
                            color: Colors.white70,
                            icon: Icons.person,
                            fontSize: previewFontSize,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
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

// Widget preview line kecil
class _PreviewLine extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;
  final double fontSize;

  const _PreviewLine({
    required this.text,
    required this.color,
    required this.icon,
    this.fontSize = 10,
  });

  @override
  Widget build(BuildContext context) {
    // WatermarkService menggambar teks langsung ke bitmap tanpa ikon.
    // Preview juga memakai teks polos agar tidak terlihat lebih padat/besar
    // dibanding hasil foto yang benar-benar disimpan.
    return Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: FontWeight.normal,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
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
                      left: style == 'compact' ? null : 0,
                      right: 0,
                      top: style == 'top' ? 0 : null,
                      bottom: style == 'top' ? null : 0,
                      child: Container(
                        width: style == 'compact' ? 35 : null,
                        height: style == 'compact' ? 30 : 14,
                        padding: const EdgeInsets.all(3),
                        color: Colors.black.withValues(alpha: 0.78),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(height: 2, width: style == 'compact' ? 23 : 38, color: Colors.white),
                            const SizedBox(height: 3),
                            Container(height: 2, width: style == 'compact' ? 27 : 52, color: Colors.white70),
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