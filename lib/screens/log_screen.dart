import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_entry.dart';
import '../services/storage_service.dart';

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
      final date = DateFormat('dd MMM yyyy HH:mm yyyy-MM-dd').format(entry.timestamp);
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
                      style: TextStyle(color: Colors.grey),
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
            width: 52,
            height: 52,
            child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }

        final path = snapshot.data;
        if (path == null) {
          return Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.broken_image_outlined, color: Colors.grey.shade500),
          );
        }

        return SizedBox(
          width: 52,
          height: 52,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(path),
              width: 52,
              height: 52,
              fit: BoxFit.cover,
              cacheWidth: 156,
              errorBuilder: (_, __, ___) => Container(
                color: Colors.grey.shade200,
                child: Icon(Icons.broken_image_outlined, color: Colors.grey.shade500),
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
                        Icon(Icons.inbox, size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          _searchController.text.trim().isEmpty ? 'No scans yet' : 'No matches found',
                          style: TextStyle(color: Colors.grey[600], fontSize: 16),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _filteredEntries.length,
                    itemBuilder: (ctx, i) {
                      final entry = _filteredEntries[i];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        leading: _buildThumbnail(entry),
                        title: Text(
                          entry.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text(
                              DateFormat('dd MMM yyyy, HH:mm').format(entry.timestamp),
                              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                            ),
                            if (entry.address != null && entry.address!.isNotEmpty)
                              Text(
                                entry.address!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: Colors.grey[800]),
                              ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Share',
                              icon: const Icon(Icons.share_outlined),
                              onPressed: () => unawaited(_shareEntry(entry)),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: () => _showDetail(entry),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
