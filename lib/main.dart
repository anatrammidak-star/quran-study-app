import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' show join;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:just_audio/just_audio.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await initDatabase();
  runApp(QuranStudyApp(database: db));
}

Future<Database> initDatabase() async {
  final dbPath = await getDatabasesPath();
  final path = join(dbPath, "quran_study.db");

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
      title: 'Belajar Terjemah Al-Qur\'an',
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
  List<Map<String, dynamic>> _chapters = [];
  List<Map<String, dynamic>> _words = [];

  int _currentSurah = 1;
  int _currentVerse = 1;
  int _maxVerseInSurah = 7;
  String _currentSurahName = "Al-Fatihah";

  String _selectedReciter = 'al_husary';
  bool _isPlaying = false;
  bool _isDownloading = false;
  bool _isAudioOffline = false;

  // Parameter Pengulangan (Looping) 1 - 40 Kali
  int _targetRepeatCount = 1;
  int _currentRepeatIndex = 0;

  // Penanda Milidetik Rentang Ayat
  int _verseStartMs = 0;
  int _verseEndMs = 0;

  // Pilihan Font Khat (0: Mushaf Madinah, 1: Amiri Modern)
  int _selectedFontIndex = 0;

  TextStyle _getArabicStyle({double fontSize = 28, Color color = Colors.white}) {
    if (_selectedFontIndex == 0) {
      return GoogleFonts.scheherazadeNew(
        fontSize: fontSize + 6,
        color: color,
        fontWeight: FontWeight.bold,
        height: 1.8,
      );
    } else {
      return GoogleFonts.amiri(
        fontSize: fontSize,
        color: color,
        fontWeight: FontWeight.normal,
        height: 1.8,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _loadInitialData();

    // Pantau posisi pemutaran secara real-time untuk memotong dan mengulang ayat
    _audioPlayer.positionStream.listen((position) {
      final currentMs = position.inMilliseconds;

      if (_isPlaying && _verseEndMs > 0 && currentMs >= _verseEndMs) {
        _handleVerseLoop();
      }
    });

    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state.playing);
      }
    });
  }

  // Logika Pengulangan Ayat Sesuai Target (1x - 40x)
  void _handleVerseLoop() async {
    if (_currentRepeatIndex + 1 < _targetRepeatCount) {
      setState(() => _currentRepeatIndex++);
      await _audioPlayer.seek(Duration(milliseconds: _verseStartMs));
      await _audioPlayer.play();
    } else {
      setState(() {
        _currentRepeatIndex = 0;
        _isPlaying = false;
      });
      await _audioPlayer.seek(Duration(milliseconds: _verseStartMs));
      await _audioPlayer.pause();
    }
  }

  Future<void> _loadInitialData() async {
    final chaps = await widget.db.rawQuery("SELECT * FROM chapters ORDER BY id ASC");
    final progress = await widget.db.query('user_progress', where: 'id = 1');

    int sId = 1;
    int vId = 1;
    if (progress.isNotEmpty) {
      sId = progress.first['surah_number'] as int;
      vId = progress.first['verse_number'] as int;
    }

    setState(() {
      _chapters = chaps;
      _currentSurah = sId;
      _currentVerse = vId;
    });

    await _loadVerseData();
  }

  Future<void> _loadVerseData() async {
    final chMeta = await widget.db.query('chapters', where: 'id = ?', whereArgs: [_currentSurah]);
    if (chMeta.isNotEmpty) {
      _currentSurahName = chMeta.first['name_simple'] as String;
      _maxVerseInSurah = chMeta.first['verses_count'] as int;
    }

    final res = await widget.db.rawQuery('''
      SELECT w.*, COALESCE(f.total_occurrences, 1) as freq, COALESCE(f.frequency_rank, 1) as rank
      FROM words w
      LEFT JOIN word_frequencies f ON w.lemma = f.lemma
      WHERE w.surah_number = ? AND w.verse_number = ?
      ORDER BY w.word_position ASC
    ''', [_currentSurah, _currentVerse]);

    // Ambil batas milidetik awal dan akhir ayat
    final timeBounds = await widget.db.rawQuery('''
      SELECT MIN(start_time_ms) as start_ms, MAX(end_time_ms) as end_ms
      FROM word_audio_timestamps
      WHERE reciter_key = ? AND surah_number = ? AND verse_number = ?
    ''', [_selectedReciter, _currentSurah, _currentVerse]);

    int sMs = 0;
    int eMs = 0;
    if (timeBounds.isNotEmpty && timeBounds.first['start_ms'] != null) {
      sMs = timeBounds.first['start_ms'] as int;
      eMs = timeBounds.first['end_ms'] as int;
    }

    await _checkAudioStatus();

    setState(() {
      _words = res;
      _verseStartMs = sMs;
      _verseEndMs = eMs;
      _currentRepeatIndex = 0;
    });

    if (_isPlaying) {
      await _audioPlayer.seek(Duration(milliseconds: _verseStartMs));
    }
  }

  Future<String> _getLocalAudioPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return join(dir.path, 'audio_${_selectedReciter}_$_currentSurah.mp3');
  }

  Future<void> _checkAudioStatus() async {
    final filePath = await _getLocalAudioPath();
    final exists = await File(filePath).exists();
    setState(() => _isAudioOffline = exists);
  }

  Future<void> _downloadSurahAudio() async {
    setState(() => _isDownloading = true);
    try {
      final audioMeta = await widget.db.query(
        'surah_audios',
        where: 'reciter_key = ? AND surah_number = ?',
        whereArgs: [_selectedReciter, _currentSurah],
      );

      if (audioMeta.isEmpty) throw Exception("Alamat URL belum terdaftar.");

      final url = audioMeta.first['audio_url'] as String;
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 40));
      if (response.statusCode != 200) throw Exception("Server CDN mengembalikan status ${response.statusCode}.");

      final path = await _getLocalAudioPath();
      await File(path).writeAsBytes(response.bodyBytes);

      await _checkAudioStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Audio surah berhasil diunduh dan tersimpan secara offline!")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Gagal mengunduh: $e")),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Tautan audio belum siap.")),
        );
        return;
      }
    }

    await _audioPlayer.seek(Duration(milliseconds: _verseStartMs));
    await _audioPlayer.play();
  }

  void _showWordDetail(Map<String, dynamic> word) async {
    String negasiInfo = "";
    if (word['particle_type'] == 'harf_nafy_general') {
      negasiInfo = "Partikel Negasi (لَا): Makna 'Tidak / Bukan' umum untuk masa kini atau masa depan (No / Not).";
    } else if (word['particle_type'] == 'harf_nafy_past') {
      negasiInfo = "Partikel Negasi (لَمْ): Makna 'Tidak / Belum' lampau (Did not / Past).";
    } else if (word['particle_type'] == 'harf_nafy_future') {
      negasiInfo = "Partikel Negasi (لَنْ): Makna 'Tidak akan pernah' di masa depan secara mutlak (Never).";
    }

    final variations = await widget.db.rawQuery('''
      SELECT DISTINCT text_uthmani, surah_number, verse_number, translation_literal 
      FROM words 
      WHERE lemma = ? AND NOT (surah_number = ? AND verse_number = ?)
      LIMIT 4
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
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(
                  word['text_uthmani'],
                  style: _getArabicStyle(fontSize: 40, color: const Color(0xFFD4AF37)),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  "Arti Harfiah: ${word['translation_literal']}",
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              const Divider(color: Colors.white24, height: 24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10)),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Kemunculan di Al-Qur'an:", style: TextStyle(color: Colors.white70)),
                        Text("${word['freq']}x", style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 16)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Peringkat Kosakata:", style: TextStyle(color: Colors.white70)),
                        Text("Urutan #${word['rank']} Terbanyak", style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
              ),
              if (negasiInfo.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFD4AF37)),
                  ),
                  child: Text(negasiInfo, style: const TextStyle(color: Color(0xFFFCE082), fontSize: 13)),
                ),
              ],
              const SizedBox(height: 16),
              const Text("Bentuk Serupa di Ayat Lain:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white70)),
              const SizedBox(height: 8),
              if (variations.isEmpty)
                const Text("Belum ada variasi pada surah yang aktif.", style: TextStyle(color: Colors.white38, fontSize: 12))
              else
                ...variations.map((v) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child:
