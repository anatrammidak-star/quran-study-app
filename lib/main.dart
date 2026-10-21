import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:just_audio/just_audio.dart';

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
  late AudioPlayer _audioPlayer;
  List<Map<String, dynamic>> _words = [];
  int _activeWordPosition = -1;
  int _currentSurah = 1;
  int _currentVerse = 1;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _loadProgressAndVerse();
  }

  Future<void> _loadProgressAndVerse() async {
    final progress = await widget.db.query('user_progress', where: 'id = 1');
    if (progress.isNotEmpty) {
      setState(() {
        _currentSurah = progress.first['surah_number'] as int;
        _currentVerse = progress.first['verse_number'] as int;
      });
    }
    _loadWords();
  }

  Future<void> _loadWords() async {
    final res = await widget.db.query(
      'words',
      where: 'surah_number = ? AND verse_number = ?',
      whereArgs: [_currentSurah, _currentVerse],
      orderBy: 'word_position ASC',
    );
    setState(() => _words = res);
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
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16384C),
        title: const Text("Keluar Aplikasi", style: TextStyle(color: Color(0xFFD4AF37))),
        content: const Text("Simpan batas belajar saat ini dan keluar?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
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
            IconButton(
              icon: const Icon(Icons.bookmark_added_outlined, color: Color(0xFFD4AF37)),
              tooltip: "Simpan Batas Baca",
              onPressed: () async {
                await _saveProgress();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Batas belajar tersimpan.")),
                  );
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
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 16,
                    alignment: WrapAlignment.center,
                    direction: Axis.horizontal,
                    textDirection: TextDirection.rtl,
                    children: _words.map((w) {
                      final isSelected = w['word_position'] == _activeWordPosition;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _activeWordPosition = w['word_position'];
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFFD4AF37).withOpacity(0.2) : const Color(0xFF16384C),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected ? const Color(0xFFD4AF37) : Colors.transparent,
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
                                  color: isSelected ? const Color(0xFFD4AF37) : Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                w['translation_literal'],
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
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
            ],
          ),
        ),
      ),
    );
  }
}
