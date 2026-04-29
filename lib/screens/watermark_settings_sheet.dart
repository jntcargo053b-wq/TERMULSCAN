import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'watermark_settings.dart';

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

  @override
  void initState() {
    super.initState();
    _operatorController.text = _settings.operatorName;
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
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
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
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const Gap(20),

          // ── NAMA OPERATOR ──────────────────────────────────────────────
          const Text('NAMA OPERATOR',
              style: TextStyle(
                color: Colors.grey,
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
              hintStyle: const TextStyle(color: Colors.grey),
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
              prefixIcon: const Icon(Icons.person_outline, color: Colors.grey),
              suffixIcon: _operatorController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.grey, size: 16),
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
                color: Colors.grey,
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
                        Text('Posisi: kanan bawah foto',
                            style: TextStyle(color: Colors.grey, fontSize: 11)),
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
                    color: Colors.amber.withOpacity(0.3),
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
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const Gap(20),

          // Preview watermark
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.withOpacity(0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('PREVIEW WATERMARK',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    )),
                const Gap(8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _PreviewLine(
                            text: _operatorController.text.isNotEmpty
                                ? _operatorController.text
                                : 'Nama Operator',
                            color: Colors.amber,
                            icon: Icons.person,
                          ),
                          const Gap(3),
                          const _PreviewLine(
                            text: '8991234567890',
                            color: Colors.white,
                            icon: Icons.qr_code,
                          ),
                          const Gap(3),
                          const _PreviewLine(
                            text: '28/04/2026 08:30:00',
                            color: Colors.white70,
                            icon: Icons.access_time,
                          ),
                          const Gap(3),
                          const _PreviewLine(
                            text: '-7.9797, 112.6304',
                            color: Colors.white70,
                            icon: Icons.location_on,
                          ),
                        ],
                      ),
                    ),
                    if (_settings.hasLogo) ...[
                      const Gap(8),
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Image.file(
                          File(_settings.logoPath!),
                          width: 40,
                          height: 40,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ] else ...[
                      const Gap(8),
                      Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.white24,
                            style: BorderStyle.solid,
                          ),
                        ),
                        child: const Icon(Icons.business, color: Colors.white24, size: 20),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          const Gap(20),

          // Tombol simpan
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
              label: const Text('Simpan Pengaturan',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ),
        ],
      ),
    );
  }
}

// Widget preview line kecil
class _PreviewLine extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;

  const _PreviewLine({
    required this.text,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 10, color: color.withOpacity(0.7)),
        const Gap(4),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
