import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({Key? key}) : super(key: key);

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _storage = StorageService();
  final _searchController = TextEditingController();

  List<ScanEntry> _filteredEntries = [];
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadEntries();
    _searchController.addListener(_onSearchChanged);
  }

  Future<void> _loadEntries() async {
    final all = await _storage.loadAll();
    if (mounted) setState(() => _filteredEntries = all);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _performSearch(_searchController.text);
    });
  }

  void _performSearch(String query) {
    final q = query.toLowerCase();
    setState(() {
      _filteredEntries = _storage.entries.where((entry) {
        final valueMatch = entry.value.toLowerCase().contains(q);
        final addressMatch = (entry.locationName ?? '').toLowerCase().contains(q);
        return valueMatch || addressMatch;
      }).toList();
    });
  }

  Future<bool> _checkFileExists(String? path) async {
    if (path == null || path.isEmpty) return false;
    try {
      return await File(path).exists();
    } catch (e) {
      return false;
    }
  }

  Future<void> _shareEntry(ScanEntry entry) async {
    final sharePath = entry.isPhoto ? entry.value : entry.imagePath;
    if (sharePath == null || sharePath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No image to share')),
      );
      return;
    }

    final exists = await _checkFileExists(sharePath);
    if (!exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image file not found on device')),
      );
      return;
    }

    try {
      await Share.shareXFiles(
        [XFile(sharePath)],
        text: entry.isBarcode
            ? 'Scan Result: ${entry.value}\nLocation: ${entry.locationName ?? "Unknown"}'
            : 'Photo\nLocation: ${entry.locationName ?? "Unknown"}',
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    }
  }

  void _showDetail(ScanEntry entry) {
    final previewPath = entry.isPhoto ? entry.value : entry.imagePath;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 16, right: 16, top: 16
        ),
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
            if (entry.isBarcode) _buildDetailRow('Barcode', entry.value),
            _buildDetailRow('Time', DateFormat('yyyy-MM-dd HH:mm:ss').format(entry.timestamp)),
            if (entry.isBarcode && entry.barcodeFormat != null)
              _buildDetailRow('Type', entry.barcodeFormat!),
            if (entry.locationName != null && entry.locationName!.isNotEmpty)
              _buildDetailRow('Location', entry.locationName!),
            if (entry.latitude != null)
              _buildDetailRow('Coordinates', '${entry.latitude}, ${entry.longitude}'),

            const SizedBox(height: 16),
            if (previewPath != null)
              FutureBuilder<bool>(
                future: _checkFileExists(previewPath),
                builder: (ctx, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.data == true) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(previewPath), height: 200, width: double.infinity, fit: BoxFit.cover),
                    );
                  }
                  return const Text('Image not available', style: TextStyle(color: Colors.grey));
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
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                          TextButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('Delete', style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await _storage.deleteEntry(entry.id);
                      if (mounted) {
                        setState(() {
                          _filteredEntries = _storage.entries;
                        });
                        Navigator.pop(context);
                      }
                    }
                  },
                  child: const Text('Delete', style: TextStyle(color: Colors.red)),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _shareEntry(entry);
                  },
                  icon: const Icon(Icons.share),
                  label: const Text('Share'),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 100, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan History'),
        actions: [
          if (_filteredEntries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear All',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Clear All History?'),
                    content: const Text('This action cannot be undone.'),
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
                  _storage.clear();
                  setState(() => _filteredEntries = []);
                }
              },
            )
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search barcode or location...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                filled: true,
                fillColor: Colors.grey[100],
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
                          _searchController.text.isEmpty
                              ? 'No scans yet'
                              : 'No matches found',
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
                        leading: CircleAvatar(
                          backgroundColor: Colors.blue.shade100,
                          child: Icon(
                            entry.isBarcode ? Icons.qr_code : Icons.camera_alt,
                            color: Colors.blue.shade900,
                            size: 20,
                          ),
                        ),
                        title: Text(
                          entry.isBarcode ? entry.value : 'Foto: ${entry.value.split('/').last}',
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
                            if (entry.locationName != null && entry.locationName!.isNotEmpty)
                              Text(
                                entry.locationName!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: Colors.grey[800]),
                              ),
                          ],
                        ),
                        trailing: (entry.isPhoto || (entry.imagePath?.isNotEmpty ?? false))
                            ? Icon(Icons.image, color: Colors.grey[400])
                            : null,
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
