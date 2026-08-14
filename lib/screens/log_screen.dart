import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/location_service.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({Key? key}) : super(key: key);

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _storage = StorageService();
  final _searchController = TextEditingController();
  final _locationService = LocationService();
  
  List<ScanEntry> _filteredEntries = [];
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _filteredEntries = _storage.entries;
    // Listener untuk search debounce
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  // Debounce Search Logic
  void _onSearchChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _performSearch(_searchController.text);
    });
  }

  void _performSearch(String query) {
    setState(() {
      _filteredEntries = _storage.entries.where((entry) {
        return entry.barcodeValue.toLowerCase().contains(query.toLowerCase()) ||
               (entry.address != null && entry.address!.toLowerCase().contains(query.toLowerCase()));
      }).toList();
    });
  }

  // Async File Check (Non-blocking)
  Future<bool> _checkFileExists(String? path) async {
    if (path == null || path.isEmpty) return false;
    try {
      final file = File(path);
      return await file.exists();
    } catch (e) {
      return false;
    }
  }

  Future<void> _shareEntry(ScanEntry entry) async {
    if (entry.imagePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No image to share')),
      );
      return;
    }

    // Gunakan async check
    final exists = await _checkFileExists(entry.imagePath);
    if (!exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image file not found')),
      );
      return;
    }

    final result = await Share.shareXFiles(
      [XFile(entry.imagePath!)],
      text: 'Scan Result: ${entry.barcodeValue}\nLocation: ${entry.address ?? "Unknown"}',
    );
    
    if (result.status == ShareResultStatus.success) {
      // Optional: Track share event
    }
  }

  void _showDetail(ScanEntry entry) {
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
            Text('Details', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),
            Text('Barcode: ${entry.barcodeValue}'),
            Text('Time: ${DateFormat('yyyy-MM-dd HH:mm').format(entry.timestamp)}'),
            Text('Location: ${entry.address ?? "Loading..."}'),
            if (entry.latitude != null)
              Text('Coords: ${entry.latitude}, ${entry.longitude}'),
            const SizedBox(height: 16),
            if (entry.imagePath != null)
              FutureBuilder<bool>(
                future: _checkFileExists(entry.imagePath),
                builder: (ctx, snapshot) {
                  if (snapshot.data == true) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(entry.imagePath!), height: 200, fit: BoxFit.cover),
                    );
                  }
                  return const Text('Image not available');
                },
              ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
                const SizedBox(width: 8),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Clear All?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear', style: TextStyle(color: Colors.red))),
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
              ),
            ),
          ),
          Expanded(
            child: _filteredEntries.isEmpty
                ? const Center(child: Text('No scans found'))
                : ListView.builder(
                    itemCount: _filteredEntries.length,
                    itemBuilder: (ctx, i) {
                      final entry = _filteredEntries[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.blue.shade100,
                          child: Icon(Icons.qr_code, color: Colors.blue.shade900),
                        ),
                        title: Text(entry.barcodeValue, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${DateFormat('dd MMM yyyy, HH:mm').format(entry.timestamp)}\n${entry.address ?? "No location"}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: entry.imagePath != null 
                            ? const Icon(Icons.image, color: Colors.grey) 
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
