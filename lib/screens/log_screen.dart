import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

class _FullImagePreviewScreen extends StatelessWidget {
  final ScanEntry entry;
  final String imagePath;
  final Future<void> Function() onShare;

  const _FullImagePreviewScreen({
    required this.entry,
    required this.imagePath,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          entry.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: onShare,
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: SizedBox.expand(
                  child: Image.file(
                    File(imagePath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white70,
                        size: 64,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        DateFormat('dd MMM yyyy, HH:mm').format(entry.timestamp),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      if (entry.address != null && entry.address!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            entry.address!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
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
    );
  }
}

class LogScreen extends StatefulWidget {
  const LogScreen({Key? key}) : super(key: key);

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> with WidgetsBindingObserver {
  final _storage = StorageService();
  final _searchController = TextEditingController();

  List<ScanEntry> _filteredEntries = [];
  Timer? _debounceTimer;
  final Map<String, String?> _resolvedPathCache = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _filteredEntries = _storage.entries;
    _searchController.addListener(_onSearchChanged);
    _refreshList();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshList();
  }

  void _onSearchChanged() {
    // Rebuild immediately so the clear button appears/disappears without
    // waiting for the search debounce.
    if (mounted) setState(() {});
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _performSearch(_searchController.text);
    });
  }

  void _performSearch(String query) {
    final q = query.trim().toLowerCase();
    final source = _storage.entries;
    if (q.isEmpty) {
      if (mounted) setState(() => _filteredEntries = source);
      return;
    }

    bool contains(String? value) =>
        value != null && value.trim().toLowerCase().contains(q);

    final result = source.where((entry) {
      final date = DateFormat('dd MMM yyyy HH:mm').format(entry.timestamp);
      return contains(entry.displayTitle) ||
          contains(entry.scanResult) ||
          contains(entry.barcodeValue) ||
          contains(entry.barcodeType) ||
          contains(entry.address) ||
          contains(entry.imageFileName) ||
          contains(entry.displayImagePath) ||
          date.toLowerCase().contains(q);
    }).toList();

    if (mounted) setState(() => _filteredEntries = result);
  }

  void _refreshList() {
    _performSearch(_searchController.text);
  }

  Future<String?> _resolveImagePath(ScanEntry entry) async {
    final cached = _resolvedPathCache[entry.id];
    if (_resolvedPathCache.containsKey(entry.id)) return cached;
    final path = await _storage.resolveImagePath(entry);
    _resolvedPathCache[entry.id] = path;
    return path;
  }

  Future<void> _evictImageCache(String imagePath) async {
    try {
      await FileImage(File(imagePath)).evict();
    } catch (_) {}
  }

  Future<void> _shareEntry(ScanEntry entry) async {
    final imagePath = await _resolveImagePath(entry);
    if (!mounted) return;

    if (imagePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Foto tidak ditemukan di penyimpanan aplikasi')),
      );
      return;
    }

    try {
      // Watermark recovery can replace the same public path. Evict the
      // decoded Flutter image before sharing so an older cached frame is not
      // reused.
      await _evictImageCache(imagePath);
      await Share.shareXFiles(
        [XFile(imagePath)],
        text: 'AWB: ${entry.displayTitle}\nLocation: ${entry.address ?? "Unknown"}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    }
  }

  Future<void> _showFullPreview(ScanEntry entry) async {
    final imagePath = await _resolveImagePath(entry);
    if (!mounted) return;

    if (imagePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Foto tidak ditemukan di penyimpanan aplikasi')),
      );
      return;
    }

    // The watermark pipeline may atomically replace this exact path
    // while recovery is finishing. Evict the decoded image before opening
    // the preview so History always reflects the current file.
    await _evictImageCache(imagePath);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullImagePreviewScreen(
          entry: entry,
          imagePath: imagePath,
          onShare: () => _shareEntry(entry),
        ),
      ),
    );
  }

  void _showDetail(ScanEntry entry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Scan Details', style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(),
              const SizedBox(height: 8),
              _buildDetailRow('Result', entry.displayTitle),
              _buildDetailRow(
                'Time',
                DateFormat('yyyy-MM-dd HH:mm:ss').format(entry.timestamp),
              ),
              if (!entry.isPhoto) _buildDetailRow('Type', entry.barcodeType),
              if (entry.address != null && entry.address!.isNotEmpty)
                _buildDetailRow('Location', entry.address!),
              if (entry.latitude != null)
                _buildDetailRow(
                  'Coordinates',
                  '${entry.latitude}, ${entry.longitude}',
                ),
              const SizedBox(height: 16),
              FutureBuilder<String?>(
                future: _resolveImagePath(entry),
                builder: (ctx, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const SizedBox(
                      height: 120,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final path = snapshot.data;
                  if (path == null) {
                    return const Text(
                      'Image not available',
                      style: TextStyle(color: AppTheme.textSecondary),
                    );
                  }
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(path),
                      height: 220,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(
                        height: 120,
                        child: Center(child: Icon(Icons.broken_image_outlined, size: 48)),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Delete this scan?'),
                          content: const Text('Foto dan data riwayat ini akan dihapus.'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(c, true),
                              child: const Text('Delete', style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        await _storage.deleteEntry(entry.id);
                        _resolvedPathCache.remove(entry.id);
                        _refreshList();
                        if (context.mounted) Navigator.pop(context);
                      }
                    },
                    child: const Text('Delete', style: TextStyle(color: Colors.red)),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      unawaited(_shareEntry(entry));
                    },
                    icon: const Icon(Icons.share),
                    label: const Text('Share'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(ScanEntry entry) {
    if (!entry.isPhoto && entry.imagePath == null) {
      return CircleAvatar(
        backgroundColor: Colors.blue.shade100,
        child: Icon(Icons.qr_code, color: Colors.blue.shade900, size: 20),
      );
    }

    return FutureBuilder<String?>(
      future: _resolveImagePath(entry),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            width: 64,
            height: 64,
            child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }

        final path = snapshot.data;
        if (path == null) {
          return Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.broken_image_outlined, color: AppTheme.textSecondary),
          );
        }

        return SizedBox(
          width: 64,
          height: 64,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(path),
              width: 64,
              height: 64,
              fit: BoxFit.cover,
              cacheWidth: 192,
              errorBuilder: (_, __, ___) => Container(
                color: AppTheme.surface,
                child: Icon(Icons.broken_image_outlined, color: AppTheme.textSecondary),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear All History?'),
        content: const Text('Semua riwayat dan foto yang disimpan aplikasi akan dihapus.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Clear All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _storage.clear();
      _resolvedPathCache.clear();
      if (mounted) setState(() => _filteredEntries = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan History'),
        actions: [
          if (_storage.entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear All',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(
                color: Color(0xFFE6EDF3),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              cursorColor: Color(0xFF00E676),
              decoration: InputDecoration(
                hintText: 'Search barcode, foto, lokasi, nama file, tanggal...',
                hintStyle: const TextStyle(
                  color: Color(0xFF8B949E),
                  fontSize: 14,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  color: Color(0xFF8B949E),
                ),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _searchController.clear(),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF30363D)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF30363D)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF00E676), width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                filled: true,
                fillColor: Color(0xFF21262D),
              ),
            ),
          ),
          Expanded(
            child: _filteredEntries.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.inbox, size: 64, color: AppTheme.textSecondary),
                        const SizedBox(height: 16),
                        Text(
                          _searchController.text.trim().isEmpty ? 'No scans yet' : 'No matches found',
                          style: TextStyle(color: AppTheme.textSecondary, fontSize: 16),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _filteredEntries.length,
                    itemBuilder: (ctx, i) {
                      final entry = _filteredEntries[i];
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          minVerticalPadding: 4,
                          leading: _buildThumbnail(entry),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  entry.displayTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                entry.isPhoto ? Icons.photo_camera_outlined : Icons.qr_code_2,
                                size: 16,
                                color: entry.isPhoto ? AppTheme.accentOrange : AppTheme.accent,
                              ),
                            ],
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  DateFormat('dd MMM yyyy, HH:mm').format(entry.timestamp),
                                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                                ),
                                if (entry.address != null && entry.address!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.location_on_outlined, size: 13, color: AppTheme.textSecondary),
                                        const SizedBox(width: 3),
                                        Expanded(
                                          child: Text(
                                            entry.address!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: 'Share',
                            icon: const Icon(Icons.share_outlined, size: 21),
                            onPressed: () => unawaited(_shareEntry(entry)),
                          ),
                          onTap: () => entry.isPhoto
                              ? unawaited(_showFullPreview(entry))
                              : _showDetail(entry),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
