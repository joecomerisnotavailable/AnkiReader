#!/usr/bin/env python3
"""Build offline JMdict index; keep the downloaded source and attribution separate."""
import gzip, hashlib, json, re, sqlite3, xml.etree.ElementTree as ET
from pathlib import Path
source=Path('Resources/JMdict_e.gz')
output=Path('Resources/dictionary.sqlite')
tmp=output.with_suffix('.building.sqlite')
if tmp.exists(): tmp.unlink()
c=sqlite3.connect(tmp)
c.executescript('CREATE TABLE entries(id TEXT PRIMARY KEY,expression TEXT,reading TEXT,definitions TEXT,commonness REAL,pos TEXT); CREATE TABLE forms(form TEXT,entry_id TEXT); CREATE INDEX form_lookup ON forms(form); CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);')
for _,entry in ET.iterparse(gzip.open(source),events=['end']):
    if entry.tag!='entry': continue
    eid=entry.findtext('ent_seq')
    kanji=[k.findtext('keb') for k in entry.findall('k_ele')]
    senses=entry.findall('sense')
    # Respect spelling/reading restrictions when indexing each entry-reading pair.
    for r in entry.findall('r_ele'):
        reading=r.findtext('reb')
        forms=r.findall('re_restr')
        spellings=[e.text for e in forms] if forms else kanji
        if r.find('re_nokanji') is not None: spellings=[]
        valid=[s for s in senses if (not s.findall('stagr') or reading in [x.text for x in s.findall('stagr')]) and (not s.findall('stagk') or any(x.text in spellings for x in s.findall('stagk')))]
        glosses=['; '.join(g.text or '' for g in s.findall('gloss') if g.attrib.get('{http://www.w3.org/XML/1998/namespace}lang','eng')=='eng') for s in valid]
        tags=[x.text or '' for x in r.findall('re_pri')]+[x.text or '' for k in entry.findall('k_ele') if k.findtext('keb') in spellings for x in k.findall('ke_pri')]
        ranks=[int(t[2:]) for t in tags if re.match(r'^nf\d+$',t)]
        common=max([0.2]+([1-(min(ranks)-1)/60] if ranks else [])+([0.8] if any(t in tags for t in ['news1','ichi1','spec1','gai1']) else []))
        identity=eid+':'+reading
        c.execute('INSERT INTO entries VALUES(?,?,?,?,?,?)',(identity,(spellings or [reading])[0],reading,json.dumps([g for g in glosses if g],ensure_ascii=False),common,','.join(dict.fromkeys(p.text or '' for s in valid for p in s.findall('pos')))))
        c.executemany('INSERT INTO forms VALUES(?,?)',[(f,identity) for f in set(spellings+[reading])])
    entry.clear()
c.execute('INSERT INTO metadata VALUES(?,?)',('source_sha256',hashlib.sha256(source.read_bytes()).hexdigest()))
c.execute('INSERT INTO metadata VALUES(?,?)',('source','https://www.edrdg.org/pub/Nihongo/JMdict_e.gz'))
c.execute('INSERT INTO metadata VALUES(?,?)',('license','CC BY-SA 4.0; https://www.edrdg.org/edrdg/licence.html'))
c.commit()
print('Indexed',c.execute('SELECT count(*) FROM entries').fetchone()[0],'entry-reading pairs')
c.close(); tmp.replace(output)
