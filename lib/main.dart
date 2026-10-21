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

  // Salin ulang jika versi baru ditimpa
  ByteData data = await rootBundle.load("assets/db/quran_study.db");
  List<int> bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  await File(path).writeAsBytes(bytes, flush: true);

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

  // Fitur Pengulangan (Looping 1 - 40 Kali)
  int _targetRepeatCount = 1;
  int _currentRepeatIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadProgressAndVerse();

    // Sinkronisasi highlight kata berdasarkan milidetik audio
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

    // Deteksi selesai putar untuk mekanisme repeat 1 - 40x
    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
        });

        if (state.processingState == ProcessingState.completed) {
          _handleAudioLooping();
        }
      }
    });
  }

  void _handleAudioLooping() async {
    if (_currentRepeatIndex + 1 < _targetRepeatCount) {
      setState(() {
        _currentRepeatIndex++;
      });
      await _audioPlayer.seek(Duration.zero);
      await _audioPlayer.play();
    } else {
      setState(() {
        _currentRepeatIndex = 0;
        _isPlaying = false;
        _activeWordPosition = -1;
      });
      await _audioPlayer.seek(Duration.zero);
      await _audioPlayer.pause();
    }
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
    final res = await widget.db.rawQuery('''
      SELECT w.*, COALESCE(f.total_occurrences, 1) as freq, COALESCE(f.frequency_rank, 999) as rank
      FROM words w
      LEFT JOIN word_frequencies f ON w.lemma = f.lemma
      WHERE w.surah_number = ? AND w.verse_number = ?
      ORDER BY w.word_position ASC
    ''', [_currentSurah, _currentVerse]);

    final maxV = await widget.db.rawQuery(
      'SELECT MAX(verse_number) as total FROM verses WHERE surah_number = ?',
      [_currentSurah]
    );

    final tsRes = await widget.db.query(
      'word_audio_timestamps',
      where: 'reciter_key = ? AND surah_number = ? AND verse_number = ?',
      whereArgs: [_selectedReciter, _currentSurah, _currentVerse],
    );

    await _checkAudioStatus();

    setState(() {
      _words = res;
      _timestamps = tsRes;
      _maxVerseInSurah = (maxV.first['total'] as int?) ?? 1;
      _activeWordPosition = -1;
      _currentRepeatIndex = 0;
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

      if (audioMeta.isEmpty) throw Exception("URL audio tidak ditemukan");

      final url = audioMeta.first['audio_url'] as String;
      final response = await http.get(Uri.parse(url));
      final path = await _getLocalAudioPath();
      await File(path).writeAsBytes(response.bodyBytes);

      await _checkAudioStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Audio surah tersimpan offline!")),
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

  // Menampilkan Rincian Kata, Frekuensi, dan Variasinya
  void _showWordDetail(Map<String, dynamic> word) async {
    String negasiInfo = "";
    if (word['particle_type'] == 'harf_nafy_general') {
      negasiInfo = "Partikel Negasi (لَا): Makna 'Tidak / Bukan' secara umum (No / Not).";
    } else if (word['particle_type'] == 'harf_nafy_past') {
      negasiInfo = "Partikel Negasi (لَمْ): Makna 'Tidak / Belum' untuk masa lampau (Did not / Past).";
    } else if (word['particle_type'] == 'harf_nafy_future') {
      negasiInfo = "Partikel Negasi (لَنْ): Makna 'Tidak akan pernah' untuk masa depan (Never / Future).";
    }

    // Ambil daftar variasi kata dengan lema yang sama di ayat lain
    final variations = await widget.db.rawQuery('''
      SELECT DISTINCT text_uthmani, surah_number, verse_number, translation_literal 
      FROM words 
      WHERE lemma = ? AND NOT (surah_number = ? AND verse_number = ?)
      LIMIT 5
    ''', [word['lemma'], _currentSurah, _currentVerse]);

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16384C),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(
                  word['text_uthmani'],
                  style: const TextStyle(fontSize: 36, color: Color(0xFFD4AF37), fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  "Arti Harfiah: ${word['translation_literal']}",
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              const Divider(color: Colors.white24, height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      const Text("Kemunculan", style: TextStyle(color: Colors.white60, fontSize: 12)),
                      Text("${word['freq']}x di Al-Qur'an", style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                  Column(
                    children: [
                      const Text("Peringkat Kata", style: TextStyle(color: Colors.white60, fontSize: 12)),
                      Text("#${word['rank']}", style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                ],
              ),
              if (negasiInfo.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFD4AF37), width: 1),
                  ),
                  child: Text(negasiInfo, style: const TextStyle(color: Color(0xFFFCE082), fontSize: 13)),
                ),
              ],
              const SizedBox(height: 16),
              const Text("Contoh Variasi di Ayat Lain:", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 8),
              if (variations.isEmpty)
                const Text("Belum ada variasi lain yang terdata.", style: TextStyle(color: Colors.white38, fontSize: 12))
              else
                ...variations.map((v) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("Surah ${v['surah_number']}:${v['verse_number']}", style: const TextStyle(color: Colors.white38, fontSize: 12)),
                      Text("${v['text_uthmani']} (${v['translation_literal']})", style: const TextStyle(color: Colors.white, fontSize: 14)),
                    ],
                  ),
                )),
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
            // Tombol Download Audio
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
            // Bar Kontrol Audio & Pengulangan (Loop 1 - 40x)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFF16384C).withOpacity(0.6),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(_isPlaying ? Icons.pause_circle : Icons.play_circle, color: const Color(0xFFD4AF37), size: 38),
                    onPressed: _toggleAudioPlay,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_isPlaying ? "Memutar (${_currentRepeatIndex + 1}/$_targetRepeatCount)" : "Putar Ayat", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        const Text("Ketuk kata untuk melihat frekuensi & variasi", style: TextStyle(fontSize: 11, color: Colors.white54)),
                      ],
                    ),
                  ),
                  // Dropdown Pilihan Pengulangan 1 - 40x
                  Row(
                    children: [
                      const Icon(Icons.repeat, size: 16, color: Color(0xFFD4AF37)),
                      const SizedBox(width: 4),
                      DropdownButton<int>(
                        value: _targetRepeatCount,
                        dropdownColor: const Color(0xFF16384C),
                        underline: const SizedBox(),
                        items: [1, 3, 5, 7, 10, 20, 30, 40].map((int val) {
                          return DropdownMenuItem<int>(
                            value: val,
                            child: Text("${val}x", style: const TextStyle(fontSize: 12, color: Color(0xFFD4AF37))),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              _targetRepeatCount = val;
                              _currentRepeatIndex = 0;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Area Baca Kata per Kata
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
            // Navigasi Pindah Ayat
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
