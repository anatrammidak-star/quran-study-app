import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' show join;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:just_audio/just_audio.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await initDatabase();
  runApp(QuranStudyApp(database: db));
}

Future<Database> initDatabase() async {
  final dbPath = await getDatabasesPath();
  final path = join(dbPath, "quran_study.db");

  if (!await databaseExists(path)) {
    ByteData data = await rootBundle.load("assets/db/quran_study.db");
    List<int> bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return await openDatabase(path);
}

class QuranStudyApp extends StatelessWidget {
  final Database database;
  const QuranStudyApp({super.key, required this.database});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Quran Study',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0B1B2B),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFD4AF37),
          surface: Color(0xFF16384C),
        ),
      ),
      home: StudyScreen(db: database),
    );
  }
}

class StudyScreen extends StatefulWidget {
  final Database db;
  const StudyScreen({super.key, required this.db});

  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  List<Map<String, dynamic>> _words = [];
  List<Map<String, dynamic>> _timestamps = [];
  
  int _activeWordPosition = -1;
  int _currentSurah = 1;
  int _currentVerse = 1;
  int _maxVerseInSurah = 7;
  
  String _selectedReciter = 'al_husary'; // 'al_husary' atau 'alafasy'
  bool _isPlaying = false;
  bool _isDownloading = false;
  bool _isAudioOffline = false;

  @override
  void initState() {
    super.initState();
    _loadProgressAndVerse();

    // Listener sinkronisasi kata saat audio berjalan
    _audioPlayer.positionStream.listen((position) {
      final currentMs = position.inMilliseconds;
      for (var ts in _timestamps) {
        if (currentMs >= ts['start_time_ms'] && currentMs <= ts['end_time_ms']) {
          if (_activeWordPosition != ts['word_position']) {
            setState(() {
              _activeWordPosition = ts['word_position'] as int;
            });
          }
          break;
        }
      }
    });

    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
        });
      }
    });
  }

  Future<void> _loadProgressAndVerse() async {
    final progress = await widget.db.query('user_progress', where: 'id = 1');
    if (progress.isNotEmpty) {
      _currentSurah = progress.first['surah_number'] as int;
      _currentVerse = progress.first['verse_number'] as int;
    }
    await _loadVerseData();
  }

  Future<void> _loadVerseData() async {
    // Ambil kata beserta info frekuensinya
    final res = await widget.db.rawQuery('''
      SELECT w.*, COALESCE(f.total_occurrences, 1) as freq, COALESCE(f.frequency_rank, 999) as rank
      FROM words w
      LEFT JOIN word_frequencies f ON w.lemma = f.lemma
      WHERE w.surah_number = ? AND w.verse_number = ?
      ORDER BY w.word_position ASC
    ''', [_currentSurah, _currentVerse]);

    // Hitung total ayat di surah ini
    final maxV = await widget.db.rawQuery(
      'SELECT MAX(verse_number) as total FROM verses WHERE surah_number = ?',
      [_currentSurah]
    );

    // Ambil timestamp kata per audio
    final tsRes = await widget.db.query(
      'word_audio_timestamps',
      where: 'reciter_key = ? AND surah_number = ? AND verse_number = ?',
      whereArgs: [_selectedReciter, _currentSurah, _currentVerse],
    );

    await _checkAudioStatus();

    setState(() {
      _words = res;
      _timestamps = tsRes;
      _maxVerseInSurah = (maxV.first['total'] as int?) ?? 7;
      _activeWordPosition = -1;
    });
  }

  Future<String> _getLocalAudioPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return join(dir.path, 'audio_${_selectedReciter}_$_currentSurah.mp3');
  }

  Future<void> _checkAudioStatus() async {
    final filePath = await _getLocalAudioPath();
    final exists = await File(filePath).exists();
    setState(() {
      _isAudioOffline = exists;
    });
  }

  Future<void> _downloadSurahAudio() async {
    setState(() => _isDownloading = true);
    try {
      final audioMeta = await widget.db.query(
        'surah_audios',
        where: 'reciter_key = ? AND surah_number = ?',
        whereArgs: [_selectedReciter, _currentSurah],
      );

      if (audioMeta.isEmpty) {
        throw Exception("URL audio tidak ditemukan");
      }

      final url = audioMeta.first['audio_url'] as String;
      final response = await http.get(Uri.parse(url));
      final path = await _getLocalAudioPath();
      await File(path).writeAsBytes(response.bodyBytes);

      await _checkAudioStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Audio surah berhasil diunduh untuk penggunaan offline!")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Gagal mengunduh audio: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  Future<void> _toggleAudioPlay() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
      return;
    }

    final localPath = await _getLocalAudioPath();
    if (await File(localPath).exists()) {
      await _audioPlayer.setFilePath(localPath);
    } else {
      // Putar via stream jika belum diunduh
      final audioMeta = await widget.db.query(
        'surah_audios',
        where: 'reciter_key = ? AND surah_number = ?',
        whereArgs: [_selectedReciter, _currentSurah],
      );
      if (audioMeta.isNotEmpty) {
        await _audioPlayer.setUrl(audioMeta.first['audio_url'] as String);
      } else {
        return;
      }
    }
    await _audioPlayer.play();
  }

  void _showWordDetail(Map<String, dynamic> word) {
    String negasiDesc = "";
    if (word['particle_type'] == 'harf_nafy_general') {
      negasiDesc = "Partikel لَا (La): Negasi umum/sekarang (Not / No).";
    } else if (word['particle_type'] == 'harf_nafy_past') {
      negasiDesc = "Partikel لَمْ (Lam): Negasi masa lampau (Did not / Belum). Membalik makna mudhari' ke lampau.";
    } else if (word['particle_type'] == 'harf_nafy_future') {
      negasiDesc = "Partikel لَنْ (Lan): Negasi masa depan yang tegas (Never / Will not).";
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16384C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(
                  word['text_uthmani'],
                  style: const TextStyle(fontSize: 34, color: Color(0xFFD4AF37), fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 12),
              Text("Arti Harfiah: ${word['translation_literal']}", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Divider(color: Colors.white24, height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("Total Muncul di Quran: ${word['freq']}x", style: const TextStyle(color: Colors.white70)),
                  Text("Peringkat Frekuensi: #${word['rank']}", style: const TextStyle(color: Color(0xFFD4AF37))),
                ],
              ),
              if (negasiDesc.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFD4AF37), width: 0.8),
                  ),
                  child: Text(negasiDesc, style: const TextStyle(color: Color(0xFFFCE082), fontSize: 13)),
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Future<void> _saveProgress() async {
    await widget.db.insert(
      'user_progress',
      {
        'id': 1,
        'surah_number': _currentSurah,
        'verse_number': _currentVerse,
        'word_position': _activeWordPosition > 0 ? _activeWordPosition : 1,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  void _confirmExit() {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF16384C),
        title: const Text("Keluar Sesi", style: TextStyle(color: Color(0xFFD4AF37))),
        content: const Text("Simpan batas belajar ayat saat ini dan keluar?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("Batal", style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD4AF37)),
            onPressed: () async {
              await _saveProgress();
              await _audioPlayer.dispose();
              SystemNavigator.pop();
            },
            child: const Text("Simpan & Keluar", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text("Surah $_currentSurah : Ayat $_currentVerse"),
          backgroundColor: const Color(0xFF0B1B2B),
          actions: [
            // Pilihan Qari
            DropdownButton<String>(
              value: _selectedReciter,
              dropdownColor: const Color(0xFF16384C),
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 'al_husary', child: Text("Al-Hushari", style: TextStyle(fontSize: 12))),
                DropdownMenuItem(value: 'alafasy', child: Text("Alafasy", style: TextStyle(fontSize: 12))),
              ],
              onChanged: (val) {
                if (val != null) {
                  setState(() => _selectedReciter = val);
                  _loadVerseData();
                }
              },
            ),
            // Tombol Unduh Audio
            IconButton(
              icon: _isDownloading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)))
                  : Icon(_isAudioOffline ? Icons.download_done : Icons.download, color: _isAudioOffline ? Colors.greenAccent : const Color(0xFFD4AF37)),
              tooltip: _isAudioOffline ? "Audio Tersimpan Offline" : "Unduh Audio Surah",
              onPressed: _isDownloading ? null : _downloadSurahAudio,
            ),
            IconButton(
              icon: const Icon(Icons.bookmark_added_outlined, color: Color(0xFFD4AF37)),
              tooltip: "Simpan Batas",
              onPressed: () async {
                await _saveProgress();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Batas baca tersimpan!")));
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.exit_to_app, color: Colors.redAccent),
              tooltip: "Keluar",
              onPressed: _confirmExit,
            ),
          ],
        ),
        body: Column(
          children: [
            // Pemutar Audio Sederhana
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFF16384C).withOpacity(0.5),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(_isPlaying ? Icons.pause_circle : Icons.play_circle, color: const Color(0xFFD4AF37), size: 36),
                    onPressed: _toggleAudioPlay,
                  ),
                  const SizedBox(width: 8),
                  Text(_isPlaying ? "Memutar qari..." : "Ketuk untuk mendengar pelafalan"),
                ],
              ),
            ),
            // Daftar Kata
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 16,
                  alignment: WrapAlignment.center,
                  textDirection: TextDirection.rtl,
                  children: _words.map((w) {
                    final isHighlighted = w['word_position'] == _activeWordPosition;
                    return GestureDetector(
                      onTap: () => _showWordDetail(w),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isHighlighted ? const Color(0xFFD4AF37).withOpacity(0.3) : const Color(0xFF16384C),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isHighlighted ? const Color(0xFFD4AF37) : Colors.white12,
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              w['text_uthmani'],
                              style: TextStyle(
                                fontSize: 26,
                                color: isHighlighted ? const Color(0xFFD4AF37) : Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              w['translation_literal'],
                              style: const TextStyle(fontSize: 12, color: Colors.white70),
                            ),
                            const SizedBox(height: 6),
                            // Badge Frekuensi Kemunculan
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black38,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                "${w['freq']}x",
                                style: const TextStyle(fontSize: 10, color: Color(0xFFD4AF37)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            // Tombol Navigasi Ayat (Sebelumnya / Selanjutnya)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              color: const Color(0xFF0B1B2B),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16384C)),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text("Sebelumnya"),
                    onPressed: _currentVerse > 1
                        ? () {
                            setState(() => _currentVerse--);
                            _loadVerseData();
                          }
                        : null,
                  ),
                  Text("$_currentVerse / $_maxVerseInSurah", style: const TextStyle(fontWeight: FontWeight.bold)),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16384C)),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text("Selanjutnya"),
                    onPressed: _currentVerse < _maxVerseInSurah
                        ? () {
                            setState(() => _currentVerse++);
                            _loadVerseData();
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
