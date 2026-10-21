import os
import sqlite3
import requests

OUTPUT_DIR = os.path.join("assets", "db")
os.makedirs(OUTPUT_DIR, exist_ok=True)
DB_PATH = os.path.join(OUTPUT_DIR, "quran_study.db")

conn = sqlite3.connect(DB_PATH)
cursor = conn.cursor()

# 1. Pastikan Skema Lengkap
cursor.executescript("""
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
    translation_literal TEXT NOT NULL,
    lemma TEXT
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

CREATE TABLE IF NOT EXISTS surah_audio_urls (
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

# Daftar surah sampel
SURAHS = [1, 112, 113, 114]
RECITERS = {
    'al_husary': 6,
    'alafasy': 7
}

print("[1/3] Mengunduh teks Al-Qur'an dan pemetaan kata...")
for s_num in SURAHS:
    url = f"https://api.quran.com/api/v4/verses/by_chapter/{s_num}?language=id&words=true&word_fields=text_uthmani,location&fields=text_uthmani"
    resp = requests.get(url)
    if resp.status_code == 200:
        for v in resp.json().get("verses", []):
            v_num = v["verse_number"]
            cursor.execute("INSERT OR REPLACE INTO verses (surah_number, verse_number, text_uthmani) VALUES (?, ?, ?)",
                           (s_num, v_num, v["text_uthmani"]))

            pos = 1
            for w in v.get("words", []):
                if w.get("char_type_name") == "word":
                    raw_text = w.get("text_uthmani", "")
                    trans = w.get("translation", {}).get("text", "")
                    clean_text = raw_text.replace(" ", "").strip()

                    # Presisi partikel negasi
                    if clean_text in ["لَا", "لا"]:
                        trans = "tidak / bukan"
                    elif clean_text in ["لَمْ", "لم"]:
                        trans = "tidak / belum (lampau)"
                    elif clean_text in ["لَنْ", "لن"]:
                        trans = "tidak akan pernah"

                    cursor.execute("""
                        INSERT INTO words (surah_number, verse_number, word_position, text_uthmani, translation_literal, lemma)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """, (s_num, v_num, pos, raw_text, trans, clean_text))
                    pos += 1

print("[2/3] Mengunduh data timestamp segmen audio per kata...")
for key, reciter_id in RECITERS.items():
    for s_num in SURAHS:
        # URL timestamp segmen kata dari Quran.com
        ts_url = f"https://api.quran.com/api/v4/recitations/{reciter_id}/by_chapter/{s_num}?segments=true"
        ts_resp = requests.get(ts_url)
        if ts_resp.status_code == 200:
            audio_files = ts_resp.json().get("audio_files", [])
            for af in audio_files:
                audio_url = af.get("audio_url")
                if audio_url:
                    cursor.execute("INSERT OR REPLACE INTO surah_audio_urls (reciter_key, surah_number, audio_url) VALUES (?, ?, ?)",
                                   (key, s_num, audio_url))

                # Ambil milidetik tiap kata
                for seg in af.get("timestamps", []):
                    # seg: [verse_key, word_pos, start_ms, end_ms]
                    if len(seg) >= 4:
                        w_pos = seg[1]
                        s_ms = seg[2]
                        e_ms = seg[3]
                        v_num = int(seg[0].split(":")[1])
                        cursor.execute("""
                            INSERT OR REPLACE INTO word_audio_timestamps 
                            (reciter_key, surah_number, verse_number, word_position, start_time_ms, end_time_ms)
                            VALUES (?, ?, ?, ?, ?, ?)
                        """, (key, s_num, v_num, w_pos, s_ms, e_ms))

print("[3/3] Membangun indeks database...")
cursor.execute("CREATE INDEX IF NOT EXISTS idx_words ON words (surah_number, verse_number);")
cursor.execute("CREATE INDEX IF NOT EXISTS idx_timestamps ON word_audio_timestamps (reciter_key, surah_number, verse_number);")
conn.commit()
conn.close()
print("Selesai! Database kini memuat data kata dan timestamp kedua qari.")
