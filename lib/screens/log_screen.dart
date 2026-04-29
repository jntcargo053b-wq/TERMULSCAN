import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:share_plus/share_plus.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});
  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _storage = StorageService();
  List<ScanEntry> _entries = [];
  List<ScanEntry> _filtered = [];
  bool _loading = true;
  String _search = '';
  String _filter = 'all';
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final data = await _storage.loadAll();
    if (!mounted) return;
    setState(() {
      _entries = data;
      _loading = false;
      _applyFilter();
    });
  }

  void _applyFilter() {
    var list = _entries;
    if (_filter == 'barcode') list = list.where((e) => e.isBarcode).toList();
    if (_filter == 'photo') list = list.where((e) => e.isPhoto).toList();
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list.where((e) =>
          e.value.toLowerCase().contains(q) ||
          (e.locationName?.toLowerCase().contains(q) ?? false) ||
          (e.note?.toLowerCase().contains(q) ?? false)).toList();
    }
    setState(() => _filtered = list);
  }

  Future<void> _delete(ScanEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Hapus Entri?'),
        content: Text(
          entry.isBarcode
              ? 'Hapus barcode "${entry.value.length > 30 ? entry.value.substring(0, 30) + "..." : entry.value}"?'
              : 'Hapus foto ini?',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: AppTheme.error),
              child: const Text('Hapus')),
        ],
      ),
    );
    if (ok == true) {
      await _storage.delete(entry.id);
      _load();
    }
  }

  Future<void> _exportTxt() async {
    if (_entries.isEmpty) return;
    setState(() => _exporting = true);
    try {
      final path = await _storage.exportTxt(_entries);
      await _storage.shareTxt(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              backgroundColor: AppTheme.error,
              content: Text('Gagal export: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Hapus Semua?'),
        content: Text(
          'Semua ${_entries.length} entri akan dihapus permanen.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: AppTheme.error),
              child: const Text('Hapus Semua')),
        ],
      ),
    );
    if (ok == true) {
      await _storage.deleteAll();
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text('Log Scan (${_entries.length})'),
        actions: [
          if (_entries.isNotEmpty) ...[
            IconButton(
              icon: _exporting
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          color: AppTheme.accent, strokeWidth: 2))
                  : const Icon(Icons.share_outlined),
              tooltip: 'Export & Share TXT',
              onPressed: _exporting ? null : _exportTxt,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppTheme.error),
              tooltip: 'Hapus Semua',
              onPressed: _deleteAll,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          _buildSearchAndFilter(),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilter() {
    return Container(
      color: AppTheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        children: [
          TextField(
            onChanged: (v) {
              _search = v;
              _applyFilter();
            },
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            decoration: const InputDecoration(
              hintText: 'Cari barcode, lokasi, catatan...',
              prefixIcon:
                  Icon(Icons.search, color: AppTheme.textSecondary, size: 18),
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const Gap(10),
          Row(
            children: [
              _FilterChip(
                  label: 'Semua',
                  count: _entries.length,
                  selected: _filter == 'all',
                  onTap: () { _filter = 'all'; _applyFilter(); }),
              const Gap(8),
              _FilterChip(
                  label: 'Barcode',
                  count: _entries.where((e) => e.isBarcode).length,
                  selected: _filter == 'barcode',
                  color: AppTheme.accent,
                  onTap: () { _filter = 'barcode'; _applyFilter(); }),
              const Gap(8),
              _FilterChip(
                  label: 'Foto',
                  count: _entries.where((e) => e.isPhoto).length,
                  selected: _filter == 'photo',
                  color: AppTheme.accentOrange,
                  onTap: () { _filter = 'photo'; _applyFilter(); }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppTheme.accent));
    }
    if (_filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.inbox_outlined,
                size: 64, color: AppTheme.textSecondary),
            const Gap(16),
            Text(
              _entries.isEmpty ? 'Belum ada scan' : 'Tidak ada hasil',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Gap(8),
            Text(
              _entries.isEmpty
                  ? 'Mulai scan barcode atau ambil foto'
                  : 'Coba kata kunci lain',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.accent,
      backgroundColor: AppTheme.surface,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _filtered.length,
        itemBuilder: (ctx, i) => _EntryCard(
          entry: _filtered[i],
          onDelete: () => _delete(_filtered[i]),
        ).animate().fadeIn(
              delay: Duration(milliseconds: i * 40),
              duration: 250.ms,
            ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    this.color = AppTheme.accentBlue,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.2) : AppTheme.surfaceLight,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? color : AppTheme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                  color: selected ? color : AppTheme.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                )),
            const Gap(5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: selected ? color : AppTheme.border,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$count',
                  style: TextStyle(
                    color: selected ? Colors.black : AppTheme.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  )),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  final ScanEntry entry;
  final VoidCallback onDelete;

  const _EntryCard({required this.entry, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final isBarcode = entry.isBarcode;
    final color = isBarcode ? AppTheme.accent : AppTheme.accentOrange;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetail(context),
        onLongPress: onDelete,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: isBarcode
                    ? Icon(Icons.qr_code_scanner, color: color, size: 22)
                    : (File(entry.value).existsSync()
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(File(entry.value),
                                width: 44, height: 44, fit: BoxFit.cover))
                        : Icon(Icons.broken_image, color: color, size: 22)),
              ),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            isBarcode
                                ? (entry.barcodeFormat ?? 'BARCODE')
                                : 'FOTO',
                            style: TextStyle(
                                color: color,
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5),
                          ),
                        ),
                        const Gap(8),
                        Text(entry.timestampShort,
                            style: const TextStyle(
                                color: AppTheme.textSecondary, fontSize: 11)),
                      ],
                    ),
                    const Gap(4),
                    Text(
                      isBarcode
                          ? entry.value
                          : 'Foto: ${entry.value.split('/').last}',
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Gap(2),
                    Text(
                      entry.locationName ?? entry.coordinatesString,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // Tombol share cepat di card
              IconButton(
                icon: const Icon(Icons.share,
                    size: 18, color: AppTheme.textSecondary),
                onPressed: () => _shareEntry(context),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: AppTheme.textSecondary),
                onPressed: onDelete,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _shareEntry(BuildContext context) {
    if (entry.isBarcode) {
      final text = 'Barcode: ${entry.value}\n'
          'Format: ${entry.barcodeFormat ?? "-"}\n'
          'Waktu: ${entry.timestampFormatted}\n'
          'GPS: ${entry.coordinatesString}';
      Share.share(text, subject: 'Hasil Scan WH Scanner');
    } else if (entry.isPhoto && File(entry.value).existsSync()) {
      Share.shareXFiles(
        [XFile(entry.value)],
        subject: 'Foto WH Scanner',
        text: 'Waktu: ${entry.timestampFormatted}\n'
            'GPS: ${entry.coordinatesString}',
      );
    }
  }

  void _showDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _DetailSheet(entry: entry),
    );
  }
}

class _DetailSheet extends StatelessWidget {
  final ScanEntry entry;
  const _DetailSheet({required this.entry});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                    color: AppTheme.border,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),

            if (entry.isPhoto && File(entry.value).existsSync()) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(File(entry.value),
                    width: double.infinity, height: 220, fit: BoxFit.cover),
              ),
              const Gap(20),
            ],

            Text(
              entry.isBarcode ? 'Detail Barcode' : 'Detail Foto',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Gap(16),

            _Row(icon: Icons.schedule, label: 'Timestamp',
                value: entry.timestampFormatted),
            const Gap(10),
            if (entry.isBarcode) ...[
              _Row(icon: Icons.qr_code, label: 'Format',
                  value: entry.barcodeFormat ?? '-'),
              const Gap(10),
              _Row(icon: Icons.data_object, label: 'Nilai Barcode',
                  value: entry.value, canCopy: true),
              const Gap(10),
            ],
            _Row(icon: Icons.location_on, label: 'Koordinat GPS',
                value: entry.coordinatesString),
            if (entry.locationName != null) ...[
              const Gap(10),
              _Row(icon: Icons.place, label: 'Nama Lokasi',
                  value: entry.locationName!),
            ],
            if (entry.note != null && entry.note!.isNotEmpty) ...[
              const Gap(10),
              _Row(icon: Icons.note, label: 'Catatan', value: entry.note!),
            ],
            const Gap(24),

            // Tombol untuk barcode
            if (entry.isBarcode) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: entry.value));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Barcode disalin ke clipboard'),
                          duration: Duration(seconds: 1)),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Salin Barcode'),
                ),
              ),
              const Gap(10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    final text = 'Barcode: ${entry.value}\n'
                        'Format: ${entry.barcodeFormat ?? "-"}\n'
                        'Waktu: ${entry.timestampFormatted}\n'
                        'GPS: ${entry.coordinatesString}';
                    Share.share(text, subject: 'Hasil Scan WH Scanner');
                  },
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('Share Barcode'),
                ),
              ),
            ],

            // Tombol untuk foto
            if (entry.isPhoto && File(entry.value).existsSync()) ...[
              const Gap(10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Share.shareXFiles(
                      [XFile(entry.value)],
                      subject: 'Foto WH Scanner',
                      text: 'Waktu: ${entry.timestampFormatted}\n'
                          'GPS: ${entry.coordinatesString}',
                    );
                  },
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('Share Foto'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool canCopy;

  const _Row({
    required this.icon,
    required this.label,
    required this.value,
    this.canCopy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppTheme.accentBlue),
        const Gap(10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11)),
              const Gap(2),
              Text(value,
                  style: const TextStyle(
                      color: AppTheme.textPrimary, fontSize: 13)),
            ],
          ),
        ),
        if (canCopy)
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Disalin'),
                    duration: Duration(seconds: 1)),
              );
            },
            child: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.copy,
                  size: 16, color: AppTheme.textSecondary),
            ),
          ),
      ],
    );
  }
}
