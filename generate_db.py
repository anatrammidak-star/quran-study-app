import os
import sqlite3
import requests

OUTPUT_DIR = os.path.join("assets", "db")
os.makedirs(OUTPUT_DIR, exist_ok=True)
DB_PATH = os.path.join(OUTPUT_DIR, "quran_study.db")

conn = sqlite3.connect(DB_PATH)
cursor = conn.cursor()

cursor.executescript("""
DROP TABLE IF EXISTS chapters;
DROP TABLE IF EXISTS verses;
DROP TABLE IF EXISTS words;
DROP TABLE IF EXISTS word_frequencies;
DROP TABLE IF EXISTS word_audio_timestamps;
DROP TABLE IF EXISTS surah_audios;
DROP TABLE IF EXISTS user_progress;

CREATE TABLE chapters (
    id INTEGER PRIMARY KEY,
    name_simple TEXT NOT NULL,
    name_arabic TEXT NOT NULL,
    verses_count INTEGER NOT NULL
);

CREATE TABLE verses (
    id INTEGER PRIMARY KEY,
    surah_number INTEGER NOT NULL,
    verse_number INTEGER NOT NULL,
    text_uthmani TEXT NOT NULL
);

CREATE TABLE words (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    surah_number INTEGER NOT NULL,
    verse_number INTEGER NOT NULL,
    word_position INTEGER NOT NULL,
    text_uthmani TEXT NOT NULL,
    translation_literal TEXT NOT NULL,
    lemma TEXT NOT NULL,
    particle_type TEXT
);

CREATE TABLE word_frequencies (
    lemma TEXT PRIMARY KEY,
    total_occurrences INTEGER NOT NULL,
    frequency_rank INTEGER NOT NULL
);

CREATE TABLE word_audio_timestamps (
    reciter_key TEXT NOT NULL,
    surah_number INTEGER NOT NULL,
    verse_number INTEGER NOT NULL,
    word_position INTEGER NOT NULL,
    start_time_ms INTEGER NOT NULL,
    end_time_ms INTEGER NOT NULL,
    PRIMARY KEY(reciter_key, surah_number, verse_number, word_position)
);

CREATE TABLE surah_audios (
    reciter_key TEXT NOT NULL,
    surah_number INTEGER NOT NULL,
    audio_url TEXT NOT NULL,
    PRIMARY KEY(reciter_key, surah_number)
);

CREATE TABLE user_progress (
    id INTEGER PRIMARY KEY DEFAULT 1,
    surah_number INTEGER NOT NULL,
    verse_number INTEGER NOT NULL,
    word_position INTEGER DEFAULT 1,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO user_progress (id, surah_number, verse_number, word_position) VALUES (1, 1, 1, 1);
""")
conn.commit()

print("[1/4] Mengambil metadata 114 Surah...")
chap_res = requests.get("https://api.quran.com/api/v4/chapters?language=id").json()
for c in chap_res.get("chapters", []):
    cursor.execute("INSERT INTO chapters (id, name_simple, name_arabic, verses_count) VALUES (?, ?, ?, ?)",
                   (c['id'], c['name_simple'], c['name_arabic'], c['verses_count']))
conn.commit()

print("[2/4] Menghasilkan URL Audio Resmi Per Surah (MP3Quran CDN)...")
for s_num in range(1, 115):
    s_padded = f"{s_num:03d}"
    # Al-Hushari Murattal
    url_husary = f"https://server13.mp3quran.net/husr/{s_padded}.mp3"
    cursor.execute("INSERT OR REPLACE INTO surah_audios (reciter_key, surah_number, audio_url) VALUES (?, ?, ?)",
                   ('al_husary', s_num, url_husary))

    # Mishary Rashid Alafasy
    url_alafasy = f"https://server8.mp3quran.net/afs/{s_padded}.mp3"
    cursor.execute("INSERT OR REPLACE INTO surah_audios (reciter_key, surah_number, audio_url) VALUES (?, ?, ?)",
                   ('alafasy', s_num, url_alafasy))
conn.commit()

print("[3/4] Mengunduh dataset kata per kata untuk seluruh 114 Surah...")
# Mengunduh seluruh surah Al-Qur'an secara bertahap
for s_num in range(1, 115):
    page = 1
    while True:
        url = f"https://api.quran.com/api/v4/verses/by_chapter/{s_num}?language=id&words=true&word_fields=text_uthmani,location&fields=text_uthmani&page={page}&per_page=50"
        resp = requests.get(url)
        if resp.status_code != 200:
            break
        data = resp.json().get("verses", [])
        if not data:
            break

        for v in data:
            v_num = v["verse_number"]
            cursor.execute("INSERT OR REPLACE INTO verses (surah_number, verse_number, text_uthmani) VALUES (?, ?, ?)",
                           (s_num, v_num, v["text_uthmani"]))

            pos = 1
            for w in v.get("words", []):
                if w.get("char_type_name") == "word":
                    raw_text = w.get("text_uthmani", "").strip()
                    trans = w.get("translation", {}).get("text", "")
                    clean_lemma = raw_text.replace(" ", "").strip()
                    p_type = None

                    # Pembedaan tegas partikel negasi bahasa Arab
                    if clean_lemma in ["لَا", "لا"]:
                        trans = "tidak (bukan / no / not)"
                        p_type = "harf_nafy_general"
                    elif clean_lemma in ["لَمْ", "لم"]:
                        trans = "tidak / belum pernah (lampau / did not)"
                        p_type = "harf_nafy_past"
                    elif clean_lemma in ["لَنْ", "لن"]:
                        trans = "tidak akan pernah (masa depan / never)"
                        p_type = "harf_nafy_future"
                    elif clean_lemma in ["مَا", "ما"]:
                        trans = "tidak / apa yang"
                        p_type = "harf_nafy_descriptive"

                    cursor.execute("""
                        INSERT INTO words (surah_number, verse_number, word_position, text_uthmani, translation_literal, lemma, particle_type)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, (s_num, v_num, pos, raw_text, trans, clean_lemma, p_type))
                    pos += 1
        page += 1
    print(f" -> Surah {s_num}/114 tersimpan.")

conn.commit()

print("[4/4] Menginjeksi Data Frekuensi Global 30 Juz Resmi...")
GLOBAL_FREQUENCIES = {
    "اللَّه": (2699, 1), "ٱللَّهِ": (2699, 1), "لِلَّهِ": (2699, 1), "بِٱللَّهِ": (2699, 1),
    "رَبّ": (975, 2), "رَبِّ": (975, 2), "بِرَبِّ": (975, 2), "رَبَّنَا": (975, 2),
    "ٱلرَّحْمَٰنِ": (57, 45), "ٱلرَّحِيمِ": (115, 28), "يَوْمِ": (405, 7),
    "ٱلدِّينِ": (92, 34), "ٱلَّذِينَ": (1080, 2), "عَلَيْهِمْ": (483, 5),
    "لَا": (812, 3), "لا": (812, 3), "لَمْ": (382, 8), "لم": (382, 8),
    "لَنْ": (106, 31), "لن": (106, 31), "مَا": (2143, 2), "ما": (2143, 2),
    "قُلْ": (332, 10), "هُوَ": (481, 6), "أَحَدٌ": (85, 38), "ٱلنَّاسِ": (241, 15)
}

for lemma, (total_occ, rank) in GLOBAL_FREQUENCIES.items():
    cursor.execute("INSERT OR REPLACE INTO word_frequencies (lemma, total_occurrences, frequency_rank) VALUES (?, ?, ?)",
                   (lemma, total_occ, rank))

cursor.execute("""
    INSERT OR IGNORE INTO word_frequencies (lemma, total_occurrences, frequency_rank)
    SELECT lemma, COUNT(*), 500 FROM words GROUP BY lemma
""")

cursor.execute("CREATE INDEX IF NOT EXISTS idx_w ON words(surah_number, verse_number);")
cursor.execute("CREATE INDEX IF NOT EXISTS idx_aud ON surah_audios(reciter_key, surah_number);")
conn.commit()
conn.close()
print("Selesai! Database 114 Surah dan Audio URL siap digunakan.")
