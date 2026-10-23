#!/usr/bin/env python3
"""Read only the requested deck. Images and note-derived labels remain local."""
import argparse, hashlib, html, json, re, shutil, sqlite3
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('profile', type=Path)
p.add_argument('--deck', default='Language::Japanese::Yomichan')
p.add_argument('--output', type=Path, default=Path('Benchmark/private'))
a = p.parse_args()
c = sqlite3.connect((a.profile/'collection.anki2').as_uri()+'?mode=ro', uri=True)
ids = [i for i,n in c.execute('select id,name from decks') if n.replace('\x1f','::') == a.deck]
if not ids: raise SystemExit('Requested deck not found')
rows = c.execute('select distinct n.id,n.mid,n.flds from notes n join cards c on c.nid=n.id where c.did=?', (ids[0],)).fetchall()
a.output.mkdir(parents=True, exist_ok=True)
images = {}
for nid, mid, fields in rows:
    names = dict(c.execute('select ord,name from fields where ntid=?', (mid,)))
    values = {names.get(i,str(i)): s for i,s in enumerate(fields.split('\x1f'))}
    for filename in re.findall(r'<img[^>]+src=[\"\']([^\"\']+)', fields, re.I):
        source = a.profile/'collection.media'/html.unescape(filename)
        if not source.is_file() or source.parent != a.profile/'collection.media': continue
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if digest not in images:
            name = digest[:16]+source.suffix.lower()
            shutil.copyfile(source, a.output/name)
            images[digest] = {'image':name,'sha256':digest,'noteLabels':[], 'layout':'unlabeled', 'groundTruthVerified':False}
        # These are hints, not manually verified OCR ground truth.
        relevant = {k:html.unescape(re.sub('<[^>]+>','',v)).strip() for k,v in values.items() if k.lower() in ('expression','reading','sentence','term','word')}
        images[digest]['noteLabels'].append({'noteID':str(nid), **relevant})
(a.output/'manifest.json').write_text(json.dumps({'sourceDeck':a.deck,'cases':list(images.values())},ensure_ascii=False,indent=2))
print(f'Copied {len(images)} distinct images from {len(rows)} notes. Field names: {sorted(names.values())}')
