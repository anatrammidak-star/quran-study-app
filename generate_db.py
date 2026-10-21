import os
import sqlite3
import requests

OUTPUT_DIR = os.path.join("assets", "db")
os.makedirs(OUTPUT_DIR, exist_ok=True)
DB_PATH = os.path.join(OUTPUT_DIR, "quran_study.db")

conn = sqlite3.connect(DB_PATH)
cursor = conn.cursor()

# Skema Database Lengkap
cursor.executescript("""
DROP TABLE IF EXISTS verses;
DROP TABLE IF EXISTS words;
DROP TABLE IF EXISTS word_frequencies;
DROP TABLE IF EXISTS word_audio_timestamps;
DROP TABLE IF EXISTS surah_audios;
DROP TABLE IF EXISTS user_progress;

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
    frequency_rank INTEGER
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

# Surah awal yang disiapkan (Al-Fatihah, Al-Ikhlas, Al-Falaq, An-Nas, dan ayat demonstrasi negasi Al-Baqarah 1-5)
TARGET_SURAHS = [1, 112, 113, 114]
RECITERS = {
    'al_husary': 6,
    'alafasy': 7
}

print("[1/4] Mengunduh teks, memetakan partikel, dan arti harfiah...")

for s_num in TARGET_SURAHS:
    url = f"https://api.quran.com/api/v4/verses/by_chapter/{s_num}?language=id&words=true&word_fields=text_uthmani,location&fields=text_uthmani"
    resp = requests.get(url)
    if resp.status_code != 200:
        continue
    
    data = resp.json().get("verses", [])
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

                # Penanganan presisi harfiah partikel negasi
                if clean_lemma in ["لَا", "لا"]:
                    trans = "tidak (not/no)"
                    p_type = "harf_nafy_general"
                elif clean_lemma in ["لَمْ", "لم"]:
                    trans = "tidak / belum (did not/past)"
                    p_type = "harf_nafy_past"
                elif clean_lemma in ["لَنْ", "لن"]:
                    trans = "tidak akan pernah (never/future)"
                    p_type = "harf_nafy_future"
                elif clean_lemma in ["مَا", "ما"]:
                    trans = "tidak / bukan"
                    p_type = "harf_nafy_descriptive"

                cursor.execute("""
                    INSERT INTO words (surah_number, verse_number, word_position, text_uthmani, translation_literal, lemma, particle_type)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, (s_num, v_num, pos, raw_text, trans, clean_lemma, p_type))
                pos += 1

conn.commit()

print("[2/4] Menghitung statistik kemunculan lema (frekuensi di Al-Qur'an)...")
# Menghitung agregasi frekuensi kemunculan
cursor.execute("""
    INSERT INTO word_frequencies (lemma, total_occurrences)
    SELECT lemma, COUNT(*) as cnt
    FROM words
    GROUP BY lemma
""")

# Memberikan peringkat (Rank)
cursor.execute("""
    UPDATE word_frequencies
    SET frequency_rank = (
        SELECT COUNT(*) + 1 
        FROM word_frequencies f2 
        WHERE f2.total_occurrences > word_frequencies.total_occurrences
    )
""")
conn.commit()

print("[3/4] Mengambil metadata audio dan timestamp per kata...")
for key, r_id in RECITERS.items():
    for s_num in TARGET_SURAHS:
        ts_url = f"https://api.quran.com/api/v4/recitations/{r_id}/by_chapter/{s_num}?segments=true"
        ts_resp = requests.get(ts_url)
        if ts_resp.status_code == 200:
            audio_files = ts_resp.json().get("audio_files", [])
            for af in audio_files:
                audio_url = af.get("audio_url")
                if audio_url:
                    if not audio_url.startswith("http"):
                        audio_url = f"https://download.quranicaudio.com/qdc/{'mishari_al_afasy' if r_id==7 else 'khalil_al_husary'}/{audio_url}"
                    cursor.execute("INSERT OR REPLACE INTO surah_audios (reciter_key, surah_number, audio_url) VALUES (?, ?, ?)",
                                   (key, s_num, audio_url))

                for seg in af.get("timestamps", []):
                    if len(seg) >= 4:
                        v_num = int(seg[0].split(":")[1])
                        w_pos = seg[1]
                        cursor.execute("""
                            INSERT OR REPLACE INTO word_audio_timestamps 
                            (reciter_key, surah_number, verse_number, word_position, start_time_ms, end_time_ms)
                            VALUES (?, ?, ?, ?, ?, ?)
                        """, (key, s_num, v_num, w_pos, seg[2], seg[3]))

conn.commit()

print("[4/4] Membangun indeks kueri...")
cursor.execute("CREATE INDEX IF NOT EXISTS idx_w ON words(surah_number, verse_number);")
cursor.execute("CREATE INDEX IF NOT EXISTS idx_ts ON word_audio_timestamps(reciter_key, surah_number, verse_number);")
conn.commit()
conn.close()
print("Database siap dengan data kata, frekuensi, dan audio timestamp.")
