import os
import sqlite3
import requests

OUTPUT_DIR = os.path.join("assets", "db")
os.makedirs(OUTPUT_DIR, exist_ok=True)
DB_PATH = os.path.join(OUTPUT_DIR, "quran_study.db")

conn = sqlite3.connect(DB_PATH)
cursor = conn.cursor()

cursor.executescript("""
CREATE TABLE IF NOT EXISTS chapters (
    id INTEGER PRIMARY KEY,
    name_simple TEXT NOT NULL,
    name_arabic TEXT NOT NULL,
    verses_count INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS verses (
    id INTEGER PRIMARY KEY,
    surah_number INTEGER NOT NULL,
    verse_number INTEGER NOT NULL,
    text_uthmani TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS words (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    surah_number INTEGER NOT NULL,
    verse_number INTEGER NOT NULL,
    word_position INTEGER NOT NULL,
    text_uthmani TEXT NOT NULL,
    transliteration_latin TEXT,
    translation_literal TEXT NOT NULL,
    lemma TEXT NOT NULL,
    particle_type TEXT
);

CREATE TABLE IF NOT EXISTS word_frequencies (
    lemma TEXT PRIMARY KEY,
    total_occurrences INTEGER NOT NULL,
    frequency_rank INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS word_audio_timestamps (
    reciter_key TEXT NOT NULL,
    surah_number INTEGER NOT NULL,
    verse_number INTEGER NOT NULL,
    word_position INTEGER NOT NULL,
    start_time_ms INTEGER NOT NULL,
    end_time_ms INTEGER NOT NULL,
    PRIMARY KEY(reciter_key, surah_number, verse_number, word_position)
);

CREATE TABLE IF NOT EXISTS surah_audios (
    reciter_key TEXT NOT NULL,
    surah_number INTEGER NOT NULL,
    audio_url TEXT NOT NULL,
    PRIMARY KEY(reciter_key, surah_number)
);

CREATE TABLE IF NOT EXISTS user_progress (
    id INTEGER PRIMARY KEY DEFAULT 1,
    surah_number INTEGER NOT NULL,
    verse_number INTEGER NOT NULL,
    word_position INTEGER DEFAULT 1,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO user_progress (id, surah_number, verse_number, word_position) VALUES (1, 1, 1, 1);
""")
conn.commit()

print("[1/3] Mengunduh metadata lengkap 114 Surah...")
chap_res = requests.get("https://api.quran.com/api/v4/chapters?language=id").json()
for c in chap_res.get("chapters", []):
    cursor.execute("""
        INSERT OR REPLACE INTO chapters (id, name_simple, name_arabic, verses_count) 
        VALUES (?, ?, ?, ?)
    """, (c['id'], c['name_simple'], c['name_arabic'], c['verses_count']))
conn.commit()

# Surah konten teks aktif
ACTIVE_SURAHS = [1, 2, 110, 111, 112, 113, 114]
RECITERS = {'al_husary': 6, 'alafasy': 7}

print("[2/3] Mengunduh teks dan transliterasi kata...")
for s_num in ACTIVE_SURAHS:
    page = 1
    while True:
        url = f"https://api.quran.com/api/v4/verses/by_chapter/{s_num}?language=id&words=true&word_fields=text_uthmani,transliteration,location&fields=text_uthmani&page={page}&per_page=50"
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
                    trans_id = w.get("translation", {}).get("text", "")
                    trans_lat = w.get("transliteration", {}).get("text", "")
                    clean_lemma = raw_text.replace(" ", "").strip()
                    p_type = None

                    if clean_lemma in ["لَا", "لا"]:
                        trans_id = "tidak (bukan / no / not)"
                        p_type = "harf_nafy_general"
                    elif clean_lemma in ["لَمْ", "لم"]:
                        trans_id = "tidak / belum pernah (lampau / did not)"
                        p_type = "harf_nafy_past"
                    elif clean_lemma in ["لَنْ", "لن"]:
                        trans_id = "tidak akan pernah (masa depan / never)"
                        p_type = "harf_nafy_future"
                    elif clean_lemma in ["مَا", "ما"]:
                        trans_id = "tidak / apa yang"
                        p_type = "harf_nafy_descriptive"

                    cursor.execute("""
                        INSERT INTO words (surah_number, verse_number, word_position, text_uthmani, transliteration_latin, translation_literal, lemma, particle_type)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, (s_num, v_num, pos, raw_text, trans_lat, trans_id, clean_lemma, p_type))
                    pos += 1
        page += 1

# Suntik frekuensi 30 Juz resmi
GLOBAL_FREQUENCIES = {
    "اللَّه": (2699, 1), "ٱللَّهِ": (2699, 1), "لِلَّهِ": (2699, 1), "بِٱللَّهِ": (2699, 1),
    "رَبّ": (975, 2), "رَبِّ": (975, 2), "بِرَبِّ": (975, 2),
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
    SELECT lemma, 1, 1500 FROM words WHERE lemma NOT IN (SELECT lemma FROM word_frequencies)
""")

print("[3/3] Menyiapkan audio CDN resmi...")
for key, r_id in RECITERS.items():
    for s_num in ACTIVE_SURAHS:
        ts_url = f"https://api.quran.com/api/v4/recitations/{r_id}/by_chapter/{s_num}?segments=true"
        ts_resp = requests.get(ts_url)
        if ts_resp.status_code == 200:
            for af in ts_resp.json().get("audio_files", []):
                audio_url = af.get("audio_url", "")
                if audio_url:
                    if not audio_url.startswith("http"):
                        base_reciter = "mishari_al_afasy" if r_id == 7 else "khalil_al_husary"
                        audio_url = f"https://download.quranicaudio.com/qdc/{base_reciter}/{audio_url}"
                    cursor.execute("INSERT OR REPLACE INTO surah_audios (reciter_key, surah_number, audio_url) VALUES (?, ?, ?)",
                                   (key, s_num, audio_url))

                for seg in af.get("timestamps", []):
                    if len(seg) >= 4:
                        cursor.execute("""
                            INSERT OR REPLACE INTO word_audio_timestamps 
                            (reciter_key, surah_number, verse_number, word_position, start_time_ms, end_time_ms)
                            VALUES (?, ?, ?, ?, ?, ?)
                        """, (key, s_num, int(seg[0].split(":")[1]), seg[1], seg[2], seg[3]))

cursor.execute("CREATE INDEX IF NOT EXISTS idx_words ON words(surah_number, verse_number);")
cursor.execute("CREATE INDEX IF NOT EXISTS idx_w_ts ON word_audio_timestamps(reciter_key, surah_number, verse_number);")
conn.commit()
conn.close()
print("Database siap.")
