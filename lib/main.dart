import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Dakar301App());
}

class Dakar301App extends StatelessWidget {
  const Dakar301App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DAKAR 301',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF1a1a2e),
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final String serverUrl = 'http://srv1028486.hstgr.cloud:3000';
  final ImagePicker _picker = ImagePicker();
  final List<SelectedFile> _selectedFiles = [];
  final UploadQueue _uploadQueue = UploadQueue();

  bool _isUploading = false;
  String _statusText = '';
  double _uploadProgress = 0;
  int _currentTab = 0;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      await _uploadQueue.init();
      await _checkPendingUploads();
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      print('Init error: $e');
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _statusText = 'Initialization error';
        });
      }
    }
  }

  Future<void> _checkPendingUploads() async {
    final pending = await _uploadQueue.getPendingCount();
    if (pending > 0) {
      setState(() {
        _statusText = '$pending file(s) pending upload';
      });
      _processQueue();
    }
  }

  Future<void> _captureVideo() async {
    final XFile? video = await _picker.pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(minutes: 10),
    );
    if (video != null) {
      _addFile(video);
    }
  }

  Future<void> _capturePhoto() async {
    final XFile? photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 90,
    );
    if (photo != null) {
      _addFile(photo);
    }
  }

  Future<void> _selectFromGallery() async {
    final List<XFile> files = await _picker.pickMultipleMedia();
    for (var file in files) {
      _addFile(file);
    }
  }

  void _addFile(XFile file) {
    final selectedFile = SelectedFile(
      path: file.path,
      name: file.name,
    );

    setState(() {
      _selectedFiles.add(selectedFile);
    });

    _showCaptureDialog(selectedFile);
  }

  void _showCaptureDialog(SelectedFile file) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF252540),
        title: const Text('File captured!', style: TextStyle(color: Colors.white)),
        content: Text(
          '${file.name}\n\nWhat do you want to do?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _uploadNow(file);
            },
            child: const Text('Upload now'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _showSnackBar('Added to list (${_selectedFiles.length} file(s))');
            },
            child: const Text('Keep in list'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _selectedFiles.remove(file);
              });
              Navigator.pop(context);
              _showSnackBar('File deleted');
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _uploadNow(SelectedFile file) async {
    await _uploadQueue.addToQueue(file);
    setState(() {
      _selectedFiles.remove(file);
    });
    _showSnackBar('Added to upload queue');
    _processQueue();
  }

  Future<void> _uploadAllSelected() async {
    if (_selectedFiles.isEmpty) return;

    for (var file in _selectedFiles) {
      await _uploadQueue.addToQueue(file);
    }

    final count = _selectedFiles.length;
    setState(() {
      _selectedFiles.clear();
      _statusText = '$count file(s) queued - Uploading...';
    });

    _showSnackBar('$count file(s) added to queue');
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isUploading) return;

    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity == ConnectivityResult.none) {
      setState(() {
        _statusText = 'No connection - Will upload when online';
      });
      return;
    }

    final pending = await _uploadQueue.getPending();
    if (pending.isEmpty) return;

    setState(() {
      _isUploading = true;
    });

    int successCount = 0;

    for (var item in pending) {
      setState(() {
        _statusText = 'Uploading: ${item.name}';
        _uploadProgress = 0;
      });

      try {
        final success = await _uploadFile(item, (progress) {
          setState(() {
            _uploadProgress = progress;
          });
        });

        if (success) {
          await _uploadQueue.markCompleted(item.id);
          successCount++;
        } else {
          await _uploadQueue.markFailed(item.id);
        }
      } catch (e) {
        await _uploadQueue.markFailed(item.id);
      }
    }

    setState(() {
      _isUploading = false;
      _uploadProgress = 0;
      _statusText = '$successCount file(s) uploaded successfully!';
    });

    _showSnackBar('$successCount file(s) uploaded!');
  }

  Future<bool> _uploadFile(QueueItem item, Function(double) onProgress) async {
    try {
      final file = File(item.path);
      if (!await file.exists()) return false;

      final fileSize = await file.length();
      final chunkSize = 5 * 1024 * 1024; // 5MB
      final totalChunks = (fileSize / chunkSize).ceil();

      // 1. Init upload
      final initResponse = await http.post(
        Uri.parse('$serverUrl/api/upload/init'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'filename': item.name,
          'fileSize': fileSize,
          'totalChunks': totalChunks,
          'mimeType': item.mimeType,
        }),
      );

      if (initResponse.statusCode != 200) return false;

      final initData = jsonDecode(initResponse.body);
      final uploadId = initData['uploadId'];

      // 2. Upload chunks
      final fileStream = file.openRead();
      int chunkIndex = 0;
      List<int> buffer = [];

      await for (var data in fileStream) {
        buffer.addAll(data);

        while (buffer.length >= chunkSize) {
          final chunk = buffer.sublist(0, chunkSize);
          buffer = buffer.sublist(chunkSize);

          final request = http.MultipartRequest(
            'POST',
            Uri.parse('$serverUrl/api/upload/chunk'),
          );
          request.fields['uploadId'] = uploadId;
          request.fields['chunkIndex'] = chunkIndex.toString();
          request.files.add(http.MultipartFile.fromBytes(
            'chunk',
            chunk,
            filename: 'chunk_$chunkIndex',
          ));

          final response = await request.send();
          if (response.statusCode != 200) return false;

          chunkIndex++;
          onProgress(chunkIndex / totalChunks);
        }
      }

      // Upload remaining data
      if (buffer.isNotEmpty) {
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('$serverUrl/api/upload/chunk'),
        );
        request.fields['uploadId'] = uploadId;
        request.fields['chunkIndex'] = chunkIndex.toString();
        request.files.add(http.MultipartFile.fromBytes(
          'chunk',
          buffer,
          filename: 'chunk_$chunkIndex',
        ));

        final response = await request.send();
        if (response.statusCode != 200) return false;

        onProgress(1.0);
      }

      // 3. Complete upload
      final completeResponse = await http.post(
        Uri.parse('$serverUrl/api/upload/complete'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uploadId': uploadId}),
      );

      return completeResponse.statusCode == 200;
    } catch (e) {
      print('Upload error: $e');
      return false;
    }
  }

  void _shareServerLink() {
    const text = '''DAKAR 301 - Video Share

To view videos, open this link in your browser:

http://srv1028486.hstgr.cloud:3000

IMPORTANT: Use http:// (not https)''';

    Share.share(text, subject: 'DAKAR 301 - Video share link');
  }

  void _clearSelection() {
    setState(() {
      _selectedFiles.clear();
      _statusText = '';
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF333355),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Scaffold(
        backgroundColor: const Color(0xFF1a1a2e),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Text('🎬', style: TextStyle(fontSize: 60)),
              SizedBox(height: 20),
              Text('DAKAR 301', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              SizedBox(height: 20),
              CircularProgressIndicator(color: Color(0xFF4361ee)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: _currentTab == 0 ? _buildUploadPage() : _buildVideosPage(),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTab,
        onTap: (index) => setState(() => _currentTab = index),
        backgroundColor: const Color(0xFF252540),
        selectedItemColor: const Color(0xFF4361ee),
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.upload), label: 'Upload'),
          BottomNavigationBarItem(icon: Icon(Icons.video_library), label: 'Videos'),
        ],
      ),
    );
  }

  Widget _buildUploadPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Header
          const SizedBox(height: 20),
          const Text('🎬', style: TextStyle(fontSize: 50)),
          const SizedBox(height: 10),
          const Text(
            'DAKAR 301',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const Text(
            'Capture and share your moments',
            style: TextStyle(color: Colors.grey, fontSize: 14),
          ),
          const SizedBox(height: 30),

          // Capture buttons
          Row(
            children: [
              Expanded(
                child: _buildButton('🎥 Video', const Color(0xFFe63946), _captureVideo),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildButton('📷 Photo', const Color(0xFFf4a261), _capturePhoto),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Gallery button
          _buildButton('📁 Gallery', const Color(0xFF4361ee), _selectFromGallery),
          const SizedBox(height: 16),

          // Selected files
          if (_selectedFiles.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF252540),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_selectedFiles.length} file(s) selected:',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  ..._selectedFiles.map((f) => Text(
                    '• ${f.name}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  )),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Action buttons
          Row(
            children: [
              Expanded(
                child: _buildOutlineButton('Clear', _clearSelection, _selectedFiles.isEmpty),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _buildButton(
                  '⬆️ Upload',
                  const Color(0xFF22c55e),
                  _selectedFiles.isEmpty ? null : _uploadAllSelected,
                ),
              ),
            ],
          ),

          // Progress
          if (_isUploading) ...[
            const SizedBox(height: 20),
            LinearProgressIndicator(
              value: _uploadProgress,
              backgroundColor: const Color(0xFF333355),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF4361ee)),
            ),
            const SizedBox(height: 8),
            Text(
              '${(_uploadProgress * 100).toInt()}%',
              style: const TextStyle(color: Color(0xFF4361ee), fontWeight: FontWeight.bold),
            ),
          ],

          // Status
          if (_statusText.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _statusText,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],

          // Share server link
          const SizedBox(height: 24),
          _buildButton('🌐 Share server link', const Color(0xFF9333ea), _shareServerLink),

          const SizedBox(height: 16),
          const Text(
            'Server: srv1028486.hstgr.cloud:3000',
            style: TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildVideosPage() {
    return FutureBuilder<List<dynamic>>(
      future: _fetchVideos(),
      builder: (context, snapshot) {
        return RefreshIndicator(
          onRefresh: () async => setState(() {}),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const SizedBox(height: 20),
                const Text('📹', style: TextStyle(fontSize: 50)),
                const SizedBox(height: 10),
                const Text(
                  'Videos',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const Text(
                  'Available for download',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 30),

                if (snapshot.connectionState == ConnectionState.waiting)
                  const CircularProgressIndicator()
                else if (snapshot.hasError)
                  const Text('Connection error', style: TextStyle(color: Colors.red))
                else if (!snapshot.hasData || snapshot.data!.isEmpty)
                  const Text('No videos yet', style: TextStyle(color: Colors.grey))
                else
                  ...snapshot.data!.map((video) => _buildVideoCard(video)),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<List<dynamic>> _fetchVideos() async {
    try {
      final response = await http.get(Uri.parse('$serverUrl/api/videos'));
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      print('Fetch error: $e');
    }
    return [];
  }

  Widget _buildVideoCard(dynamic video) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF252540),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: const Color(0xFF4361ee),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(child: Text('🎬', style: TextStyle(fontSize: 24))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video['name'] ?? 'Unknown',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${_formatSize(video['size'] ?? 0)} • ${video['downloads'] ?? 0} downloads',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.download, color: Color(0xFF4361ee)),
            onPressed: () {
              // Open download link
              _showSnackBar('Open: $serverUrl/api/download/${video['id']}');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildButton(String text, Color color, VoidCallback? onPressed) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          disabledBackgroundColor: color.withOpacity(0.5),
        ),
        child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _buildOutlineButton(String text, VoidCallback onPressed, bool disabled) {
    return SizedBox(
      height: 56,
      child: OutlinedButton(
        onPressed: disabled ? null : onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: disabled ? Colors.grey : Colors.white54),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(text),
      ),
    );
  }
}

// Models and Queue
class SelectedFile {
  final String path;
  final String name;

  SelectedFile({required this.path, required this.name});
}

class QueueItem {
  final String id;
  final String path;
  final String name;
  final String mimeType;
  String status;

  QueueItem({
    required this.id,
    required this.path,
    required this.name,
    required this.mimeType,
    this.status = 'pending',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'name': name,
    'mimeType': mimeType,
    'status': status,
  };

  factory QueueItem.fromJson(Map<String, dynamic> json) => QueueItem(
    id: json['id'],
    path: json['path'],
    name: json['name'],
    mimeType: json['mimeType'],
    status: json['status'],
  );
}

class UploadQueue {
  late SharedPreferences _prefs;
  final String _key = 'upload_queue';
  final Uuid _uuid = const Uuid();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<List<QueueItem>> _getQueue() async {
    final json = _prefs.getString(_key);
    if (json == null) return [];
    final list = jsonDecode(json) as List;
    return list.map((e) => QueueItem.fromJson(e)).toList();
  }

  Future<void> _saveQueue(List<QueueItem> queue) async {
    await _prefs.setString(_key, jsonEncode(queue.map((e) => e.toJson()).toList()));
  }

  Future<void> addToQueue(SelectedFile file) async {
    final queue = await _getQueue();

    // Copy file to app directory for persistence
    final appDir = await getApplicationDocumentsDirectory();
    final newPath = '${appDir.path}/${_uuid.v4()}_${file.name}';
    await File(file.path).copy(newPath);

    String mimeType = 'application/octet-stream';
    if (file.name.toLowerCase().endsWith('.mp4') || file.name.toLowerCase().endsWith('.mov')) {
      mimeType = 'video/mp4';
    } else if (file.name.toLowerCase().endsWith('.jpg') || file.name.toLowerCase().endsWith('.jpeg')) {
      mimeType = 'image/jpeg';
    } else if (file.name.toLowerCase().endsWith('.png')) {
      mimeType = 'image/png';
    }

    queue.add(QueueItem(
      id: _uuid.v4(),
      path: newPath,
      name: file.name,
      mimeType: mimeType,
    ));

    await _saveQueue(queue);
  }

  Future<List<QueueItem>> getPending() async {
    final queue = await _getQueue();
    return queue.where((e) => e.status == 'pending' || e.status == 'failed').toList();
  }

  Future<int> getPendingCount() async {
    final pending = await getPending();
    return pending.length;
  }

  Future<void> markCompleted(String id) async {
    final queue = await _getQueue();
    final item = queue.firstWhere((e) => e.id == id);

    // Delete local file
    try {
      await File(item.path).delete();
    } catch (_) {}

    queue.removeWhere((e) => e.id == id);
    await _saveQueue(queue);
  }

  Future<void> markFailed(String id) async {
    final queue = await _getQueue();
    final index = queue.indexWhere((e) => e.id == id);
    if (index >= 0) {
      queue[index].status = 'failed';
      await _saveQueue(queue);
    }
  }
}
