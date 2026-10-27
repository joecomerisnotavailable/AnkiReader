"""Index Kanjium's CC BY-SA 4.0 accent data; keep source labels and variants."""
import csv, hashlib, json, re
from pathlib import Path

def index_pitch(connection):
    source = Path('Resources/kanjium-accents.tsv')
    if not source.exists():
        raise FileNotFoundError('Download Kanjium accents.txt as Resources/kanjium-accents.tsv (see README).')
    connection.execute('CREATE TABLE IF NOT EXISTS pitch(form TEXT,reading TEXT,patterns TEXT,PRIMARY KEY(form,reading))')
    def kana(text):
        return ''.join(chr(ord(c)-0x60) if '\u30a1' <= c <= '\u30f6' else c for c in text)
    patterns = {}
    for row in csv.reader(source.open(), delimiter='\t'):
        if len(row) < 3: continue
        form, reading, raw = row[:3]
        reading = kana(reading or form)
        entries = patterns.setdefault((form, reading), [])
        for match in re.finditer(r'(?:\(([^)]*)\))?(\d+)', raw):
            item = {'position': int(match[2]), 'label': match[1] or ''}
            if item not in entries: entries.append(item)
    connection.executemany('INSERT OR REPLACE INTO pitch VALUES(?,?,?)', [(f,r,json.dumps(p,ensure_ascii=False)) for (f,r),p in patterns.items()])
    connection.execute('INSERT OR REPLACE INTO metadata VALUES(?,?)', ('pitch_source_sha256',hashlib.sha256(source.read_bytes()).hexdigest()))
    connection.execute('INSERT OR REPLACE INTO metadata VALUES(?,?)', ('pitch_source','https://github.com/mifunetoshiro/kanjium; Uros O.; CC BY-SA 4.0'))

if __name__ == '__main__':
    import sqlite3
    with sqlite3.connect('Resources/dictionary.sqlite') as connection: index_pitch(connection)
