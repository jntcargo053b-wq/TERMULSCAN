import 'dart:async';
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
  final _customTextController = TextEditingController();
  final _picker = ImagePicker();
  bool _isSaving = false;
  bool _isSavingSettings = false;
  String _selectedStyle = 'timemark';
  String _selectedPosition = 'bottomRight';
  String? _previewPath;
  String? _previewError;
  bool _isRefreshingPreview = false;
  int _previewRefreshToken = 0;
  Timer? _previewDebounce;

  @override
  void initState() {
    super.initState();
    _operatorController.text = _settings.operatorName;
    _customTextController.text = _settings.customText;
    _selectedStyle = _settings.watermarkStyle;
    _selectedPosition = _settings.watermarkPosition;
    _settings.load().then((_) {
      if (!mounted) return;
      setState(() {
        _operatorController.text = _settings.operatorName;
        _customTextController.text = _settings.customText;
        _selectedStyle = _settings.watermarkStyle;
        _selectedPosition = _settings.watermarkPosition;
      });
      _refreshPreview();
    });
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    final previewPath = _previewPath;
    if (previewPath != null) {
      // Preview bersifat sementara; jangan biarkan file terakhir tertinggal
      // setiap kali pengguna menutup lembar pengaturan.
      unawaited(() async {
        try {
          final file = File(previewPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }());
    }
    _operatorController.dispose();
    _customTextController.dispose();
    super.dispose();
  }

  /// Hindari render bitmap pada setiap ketukan saat nama operator diketik.
  /// Render terbaru tetap menggunakan token agar hasil lama tidak menimpa
  /// preview yang sesuai dengan input terakhir.
  void _schedulePreviewRefresh() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _refreshPreview();
    });
  }

  Future<void> _pickLogo() async {
    if (_isSaving || _isSavingSettings) return;

    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      );
      // Image picker dapat kembali setelah sheet ditutup.
      if (picked == null || !mounted) return;

      setState(() => _isSaving = true);
      final pickedFile = File(picked.path);
      final pickedBytes = await pickedFile.readAsBytes();
      if (pickedBytes.isEmpty || img.decodeImage(pickedBytes) == null) {
        throw const FormatException('File logo bukan gambar yang valid.');
      }
      if (pickedBytes.length > 512 * 1024) {
        throw const FormatException(
          'Ukuran logo melebihi 512 KB. Pilih logo yang lebih kecil.',
        );
      }

      final appDir = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      final dest = File('${appDir.path}/wm_logo.png');
      final temp = File('${appDir.path}/wm_logo.png.pending');
      final backup = File('${appDir.path}/wm_logo.png.backup');
      var movedOldFile = false;

      try {
        // Tulis file baru terpisah terlebih dahulu. Logo lama tetap utuh jika
        // proses salin/validasi gagal atau aplikasi terhenti di tengah proses.
        await temp.writeAsBytes(pickedBytes, flush: true);
        final stagedBytes = await temp.readAsBytes();
        if (stagedBytes.isEmpty || img.decodeImage(stagedBytes) == null) {
          throw const FormatException('Logo sementara tidak valid.');
        }

        if (await backup.exists()) await backup.delete();
        if (await dest.exists()) {
          await dest.rename(backup.path);
          movedOldFile = true;
        }
        try {
          await temp.rename(dest.path);
        } catch (_) {
          if (movedOldFile && await backup.exists() && !await dest.exists()) {
            await backup.rename(dest.path);
            movedOldFile = false;
          }
          rethrow;
        }

        await FileImage(dest).evict();
        try {
          await _settings.setLogoPath(dest.path);
        } catch (_) {
          // Jika preferensi gagal ditulis, kembalikan file lama agar path yang
          // masih tersimpan tetap menunjuk ke logo sebelumnya.
          try {
            if (await dest.exists()) await dest.delete();
            if (movedOldFile && await backup.exists()) {
              await backup.rename(dest.path);
              movedOldFile = false;
              await FileImage(dest).evict();
            }
          } catch (restoreError) {
            debugPrint('Gagal memulihkan logo watermark sebelumnya: $restoreError');
          }
          rethrow;
        }
        if (await backup.exists()) {
          try {
            await backup.delete();
          } catch (error) {
            debugPrint('Logo baru terpasang, cadangan lama belum terhapus: $error');
          }
        }
        if (mounted) await _refreshPreview();
      } finally {
        if (await temp.exists()) {
          try {
            await temp.delete();
          } catch (_) {}
        }
      }
    } catch (error, stack) {
      debugPrint('Gagal memilih logo watermark: $error');
      debugPrint('$stack');
      if (mounted) {
        final message = error is FormatException
            ? error.message
            : 'Logo gagal dipasang. Logo lama tetap dipertahankan; coba lagi.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _removeLogo() async {
    if (_isSaving || _isSavingSettings) return;

    setState(() => _isSaving = true);
    try {
      // Simpan path sebelum menghapus preferensi. Hanya hapus file logo yang
      // dikelola layar ini; jangan menyentuh path eksternal dari versi lama.
      final oldPath = _settings.logoPath;
      await _settings.setLogoPath(null);
      if (!mounted) return;

      if (oldPath != null) {
        try {
          // Cocokkan path absolut dengan file milik aplikasi. Nama basename
          // saja tidak cukup karena file eksternal bisa bernama sama.
          final appDir = await getApplicationDocumentsDirectory();
          final managedPath =
              File('${appDir.path}/wm_logo.png').absolute.path;
          final oldFile = File(oldPath).absolute;
          if (oldFile.path == managedPath) {
            await FileImage(oldFile).evict();
            if (await oldFile.exists()) await oldFile.delete();
          }
        } catch (error, stack) {
          debugPrint('Gagal membersihkan file logo watermark: $error');
          debugPrint('$stack');
        }
      }

      if (mounted) {
        setState(() {});
        await _refreshPreview();
      }
    } catch (error, stack) {
      debugPrint('Gagal menghapus logo watermark: $error');
      debugPrint('$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Logo gagal dihapus. Silakan coba lagi.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Render pratinjau menggunakan renderer bitmap yang sama dengan foto final.
  /// Dengan demikian posisi panel, font, wrapping, padding, dan logo mengikuti
  /// WatermarkService, bukan tiruan layout berbasis widget Flutter.
  Future<void> _refreshPreview() async {
    _previewDebounce?.cancel();
    _previewDebounce = null;
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
        // Ilustrasi foto sederhana, bukan bidang abu-abu polos, agar pengguna
        // dapat menilai kontras dan bentuk watermark di atas latar foto.
        img.fill(sample, color: img.ColorRgb8(172, 197, 207));
        img.fillRect(sample, x1: 0, y1: 0, x2: 1023, y2: 300,
          color: img.ColorRgb8(177, 204, 216));
        img.fillRect(sample, x1: 0, y1: 300, x2: 1023, y2: 540,
          color: img.ColorRgb8(174, 174, 160));
        img.fillRect(sample, x1: 130, y1: 190, x2: 680, y2: 500,
          color: img.ColorRgb8(111, 119, 123));
        img.fillRect(sample, x1: 175, y1: 230, x2: 635, y2: 480,
          color: img.ColorRgb8(202, 203, 194));
        img.fillRect(sample, x1: 210, y1: 270, x2: 290, y2: 370,
          color: img.ColorRgb8(54, 94, 119));
        img.fillRect(sample, x1: 320, y1: 270, x2: 400, y2: 370,
          color: img.ColorRgb8(54, 94, 119));
        img.fillRect(sample, x1: 430, y1: 270, x2: 510, y2: 370,
          color: img.ColorRgb8(54, 94, 119));
        img.fillRect(sample, x1: 0, y1: 540, x2: 1023, y2: 767,
          color: img.ColorRgb8(81, 104, 82));
        img.drawLine(sample, x1: 0, y1: 630, x2: 1023, y2: 570,
          color: img.ColorRgb8(54, 61, 58), thickness: 5);
        for (var i = 0; i < 8; i++) {
          final x = 40 + i * 125;
          img.fillRect(sample, x1: x, y1: 555 - (i % 3) * 10,
            x2: x + 35, y2: 600, color: img.ColorRgb8(68, 108, 70));
        }
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
      final customText = _customTextController.text.trim();
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
          if (customText.isNotEmpty) 'CUSTOM_TEXT: $customText',
        ],
        logoBytes: logoBytes,
        style: _selectedStyle,
        position: _selectedPosition,
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
    if (_isSavingSettings || _isSaving) return;
    // Ambil snapshot sebelum operasi async agar satu kali tekan Simpan
    // selalu menyimpan satu set nilai yang konsisten.
    final name = _operatorController.text.trim();
    final customText = _customTextController.text.trim();
    final style = _selectedStyle;
    final position = _selectedPosition;

    setState(() => _isSavingSettings = true);
    try {
      await _settings.setOperatorName(name);
      await _settings.setCustomText(customText);
      await _settings.setWatermarkStyle(style);
      await _settings.setWatermarkPosition(position);
      if (!mounted) return;
      // Ambil messenger sebelum route ditutup agar tidak melakukan lookup
      // menggunakan BuildContext dari sheet yang sudah dilepas.
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('✓ Pengaturan watermark disimpan'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (error, stack) {
      debugPrint('Gagal menyimpan pengaturan watermark: $error');
      debugPrint('$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pengaturan gagal disimpan. Silakan coba lagi.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingSettings = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight =
        media.size.height - media.viewInsets.bottom - media.padding.top - 16;
    final styleOptionWidth = media.size.width < 380
        ? (media.size.width - 48) / 2
        : (media.size.width - 64) / 3;

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
            // Jangan memaksa tinggi minimum 240 px: saat keyboard terbuka
            // ruang yang tersisa bisa lebih kecil dan menyebabkan overflow.
            maxHeight: availableHeight
                .clamp(0.0, media.size.height * 0.92),
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
          const Gap(16),
          const Text(
            'TEKS KUSTOM TIMEMARK',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const Gap(8),
          TextField(
            controller: _customTextController,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Contoh: PT Contoh Logistik - Gudang Malang',
              hintStyle: const TextStyle(color: AppTheme.textSecondary),
              helperText: 'Kosongkan untuk menghilangkan teks di bagian atas foto.',
              helperMaxLines: 2,
              counterStyle: const TextStyle(color: AppTheme.textSecondary),
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
              prefixIcon: const Icon(Icons.text_fields, color: AppTheme.textSecondary),
              suffixIcon: _customTextController.text.isNotEmpty
                  ? IconButton(
                      tooltip: 'Hapus teks kustom',
                      icon: const Icon(Icons.clear, color: AppTheme.textSecondary, size: 16),
                      onPressed: () {
                        _customTextController.clear();
                        setState(() {});
                        _schedulePreviewRefresh();
                      },
                    )
                  : null,
            ),
            onChanged: (_) {
              setState(() {});
              _schedulePreviewRefresh();
            },
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
              _schedulePreviewRefresh();
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
                        icon: _isSaving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.edit, color: Colors.amber, size: 18),
                        onPressed: _isSaving || _isSavingSettings ? null : _pickLogo,
                        tooltip: 'Ganti logo',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                        onPressed: _isSaving || _isSavingSettings ? null : _removeLogo,
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
                width: styleOptionWidth,
                child: _WatermarkStyleOption(
                  title: 'Timemark',
                  subtitle: 'Referensi: jam + garis kuning',
                  style: 'timemark',
                  selected: _selectedStyle == 'timemark',
                  onTap: () { setState(() => _selectedStyle = 'timemark'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: styleOptionWidth,
                child: _WatermarkStyleOption(
                  title: 'Classic',
                  subtitle: 'Panel bawah',
                  style: 'classic',
                  selected: _selectedStyle == 'classic',
                  onTap: () { setState(() => _selectedStyle = 'classic'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: styleOptionWidth,
                child: _WatermarkStyleOption(
                  title: 'Compact',
                  subtitle: 'Panel kanan',
                  style: 'compact',
                  selected: _selectedStyle == 'compact',
                  onTap: () { setState(() => _selectedStyle = 'compact'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: styleOptionWidth,
                child: _WatermarkStyleOption(
                  title: 'Header',
                  subtitle: 'Bagian atas',
                  style: 'top',
                  selected: _selectedStyle == 'top',
                  onTap: () { setState(() => _selectedStyle = 'top'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: styleOptionWidth,
                child: _WatermarkStyleOption(
                  title: 'Modern',
                  subtitle: 'Aksen cyan',
                  style: 'modern',
                  selected: _selectedStyle == 'modern',
                  onTap: () { setState(() => _selectedStyle = 'modern'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: styleOptionWidth,
                child: _WatermarkStyleOption(
                  title: 'Minimal',
                  subtitle: 'Ringkas kiri',
                  style: 'minimal',
                  selected: _selectedStyle == 'minimal',
                  onTap: () { setState(() => _selectedStyle = 'minimal'); _refreshPreview(); },
                ),
              ),
              SizedBox(
                width: styleOptionWidth,
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

          const Text('POSISI PANEL', style: TextStyle(
            color: AppTheme.textSecondary, fontSize: 11,
            fontWeight: FontWeight.w700, letterSpacing: 1.2,
          )),
          const Gap(8),
          Center(
            child: SizedBox(
              width: 220,
              child: Column(
                children: [
                  for (final row in const [
                    ['topLeft', 'topCenter', 'topRight'],
                    ['centerLeft', 'center', 'centerRight'],
                    ['bottomLeft', 'bottomCenter', 'bottomRight'],
                  ])
                    Row(
                      children: [
                        for (final position in row)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: _PositionOption(
                                position: position,
                                selected: _selectedPosition == position,
                                onTap: () {
                                  setState(() => _selectedPosition = position);
                                  _refreshPreview();
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const Gap(6),
          const Text(
            'Pilih salah satu dari 9 posisi. Preview mengikuti posisi yang tersimpan pada foto baru.',
            textAlign: TextAlign.center,
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
                  onPressed: _isSavingSettings || _isSaving ? null : _save,
                  icon: _isSavingSettings
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check, size: 18),
                  label: Text(
                    _isSavingSettings ? 'Menyimpan…' : 'Simpan Pengaturan',
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
    return Semantics(
      label: 'Model watermark: $title. $subtitle',
      button: true,
      selected: selected,
      child: InkWell(
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
                    if (style == 'timemark') ...[
                      const Positioned(
                        right: 4,
                        top: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('TERMULSCAN', style: TextStyle(
                              color: Color(0xFFFFC247),
                              fontSize: 6,
                              fontWeight: FontWeight.w900,
                              shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
                            )),
                            Text('Foto dengan metadata', style: TextStyle(
                              color: Colors.white,
                              fontSize: 4,
                              shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
                            )),
                          ],
                        ),
                      ),
                      Positioned(
                        left: 4,
                        bottom: 3,
                        child: SizedBox(
                          width: 94,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                height: 19,
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8F8F5),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  children: [
                                    const Text('16:45', style: TextStyle(
                                      color: Color(0xFF123B75),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                    )),
                                    const Spacer(),
                                    Container(
                                      width: 24,
                                      height: 13,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFB7B7B2),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                      child: const Center(
                                        child: Text('LOGO', style: TextStyle(
                                          fontSize: 4,
                                          color: Colors.black,
                                          fontWeight: FontWeight.w900,
                                        )),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 3),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(width: 2, height: 18, color: Colors.amber),
                                  const SizedBox(width: 3),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(height: 3, width: 54, color: Colors.white),
                                        const SizedBox(height: 3),
                                        Container(height: 2, width: 80, color: Colors.white70),
                                        const SizedBox(height: 2),
                                        Container(height: 2, width: 59, color: Colors.white70),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (style == 'classic')
                      Positioned(
                        left: 4,
                        bottom: 3,
                        child: SizedBox(
                          width: 78,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                height: 17,
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8F8F5),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  children: [
                                    const Text(
                                      '16:45',
                                      style: TextStyle(
                                        color: Color(0xFF123B75),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      width: 17,
                                      height: 11,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFB7B7B2),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                      child: const Center(
                                        child: Text('LOGO', style: TextStyle(fontSize: 3, color: Colors.black, fontWeight: FontWeight.w900)),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 3),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(width: 2, height: 19, color: Colors.amber),
                                  const SizedBox(width: 3),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(height: 3, width: 54, color: Colors.white),
                                        const SizedBox(height: 3),
                                        Container(height: 2, width: 68, color: Colors.white70),
                                        const SizedBox(height: 2),
                                        Container(height: 2, width: 44, color: Colors.white70),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (style != 'classic' && style != 'timemark')
                    Positioned(
                      left: style == 'modern' || style == 'minimal' ? 4 : null,
                      right: style == 'classic' || style == 'top' ? 0 : (style == 'compact' || style == 'badge' ? 4 : null),
                      top: style == 'top' ? 0 : (style == 'modern' ? 4 : null),
                      bottom: style == 'top' || style == 'modern' ? null : 0,
                      child: Container(
                        width: style == 'compact' ? 43 : (style == 'badge' ? 39 : (style == 'minimal' ? 48 : null)),
                        height: style == 'compact' ? 24 : (style == 'badge' ? 29 : (style == 'minimal' ? 17 : (style == 'modern' ? 25 : 14))),
                        padding: EdgeInsets.fromLTRB(
                          style == 'minimal' ? 5 : 3,
                          style == 'badge' ? 5 : 3,
                          3,
                          3,
                        ),
                        decoration: BoxDecoration(
                          color: style == 'modern'
                              ? const Color(0xDD09192A)
                              : style == 'minimal'
                                  ? Colors.black.withValues(alpha: 0.48)
                                  : style == 'badge'
                                      ? const Color(0xE61C1913)
                                      : Colors.black.withValues(alpha: 0.82),
                          borderRadius: BorderRadius.circular(
                            style == 'badge' ? 5 : (style == 'modern' ? 3 : 0),
                          ),
                          border: style == 'modern'
                              ? const Border(left: BorderSide(color: Colors.cyanAccent, width: 2))
                              : style == 'badge'
                                  ? const Border(top: BorderSide(color: Colors.amber, width: 2))
                                  : null,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              height: 2,
                              width: style == 'compact' || style == 'badge' || style == 'minimal' ? 23 : 38,
                              color: style == 'badge' ? Colors.amber : (style == 'modern' ? Colors.cyanAccent : Colors.white),
                            ),
                            const SizedBox(height: 3),
                            if (style != 'minimal')
                              Container(
                                height: 2,
                                width: style == 'compact' || style == 'badge' ? 27 : 52,
                                color: Colors.white70,
                              ),
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
      ),
    );
  }
}

class _PositionOption extends StatelessWidget {
  final String position;
  final bool selected;
  final VoidCallback onTap;

  const _PositionOption({
    required this.position,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final alignment = switch (position) {
      'topLeft' => Alignment.topLeft,
      'topCenter' => Alignment.topCenter,
      'topRight' => Alignment.topRight,
      'centerLeft' => Alignment.centerLeft,
      'center' => Alignment.center,
      'centerRight' => Alignment.centerRight,
      'bottomLeft' => Alignment.bottomLeft,
      'bottomCenter' => Alignment.bottomCenter,
      _ => Alignment.bottomRight,
    };
    const labels = {
      'topLeft': 'Kiri atas',
      'topCenter': 'Tengah atas',
      'topRight': 'Kanan atas',
      'centerLeft': 'Kiri tengah',
      'center': 'Tengah',
      'centerRight': 'Kanan tengah',
      'bottomLeft': 'Kiri bawah',
      'bottomCenter': 'Tengah bawah',
      'bottomRight': 'Kanan bawah',
    };
    return Semantics(
      label: 'Posisi watermark: ${labels[position] ?? 'Kanan bawah'}',
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 42,
        decoration: BoxDecoration(
          color: selected ? Colors.amber.withValues(alpha: 0.16) : const Color(0xFF2A2A2A),
          border: Border.all(color: selected ? Colors.amber : Colors.white24, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Align(
          alignment: alignment,
          child: Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: selected ? Colors.amber : Colors.white54,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          ),
        ),
      ),
    );
  }
}
