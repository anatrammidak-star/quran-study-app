import os
import sqlite3
import requests

OUTPUT_DIR = os.path.join("assets", "db")
os.makedirs(OUTPUT_DIR, exist_ok=True)
DB_PATH = os.path.join(OUTPUT_DIR, "quran_study.db")

conn = sqlite3.connect(DB_PATH)
cursor = conn.cursor()

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

# Unduh surah pembuka sebagai sampel awal build
SURAHS = [1, 112, 113, 114]

for s_num in SURAHS:
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
                raw_text = w.get("text_uthmani", "")
                trans = w.get("translation", {}).get("text", "")

                clean_text = raw_text.replace(" ", "").strip()
                if clean_text in ["لَا", "لا"]:
                    trans = "tidak / bukan"
                elif clean_text in ["لَمْ", "لم"]:
                    trans = "tidak / belum (lampau)"
                elif clean_text in ["لَنْ", "لن"]:
                    trans = "tidak akan pernah"
                elif clean_text in ["مَا", "ما"]:
                    trans = "tidak / apa yang"

                cursor.execute("""
                    INSERT INTO words (surah_number, verse_number, word_position, text_uthmani, translation_literal, lemma)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, (s_num, v_num, pos, raw_text, trans, clean_text))
                pos += 1

cursor.execute("CREATE INDEX IF NOT EXISTS idx_lookup ON words (surah_number, verse_number);")
conn.commit()
conn.close()
