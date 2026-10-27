#!/usr/bin/env python3
"""Build offline JMdict index; keep the downloaded source and attribution separate."""
import gzip, hashlib, json, re, sqlite3, xml.etree.ElementTree as ET
from pathlib import Path
source=Path('Resources/JMdict_e.gz')
output=Path('Resources/dictionary.sqlite')
tmp=output.with_suffix('.building.sqlite')
if tmp.exists(): tmp.unlink()
c=sqlite3.connect(tmp)
c.executescript('CREATE TABLE entries(id TEXT PRIMARY KEY,expression TEXT,reading TEXT,definitions TEXT,commonness REAL,pos TEXT); CREATE TABLE forms(form TEXT,entry_id TEXT); CREATE INDEX form_lookup ON forms(form); CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT); CREATE TABLE form_details(entry_id TEXT,form TEXT,expression TEXT,definitions TEXT,pos TEXT,PRIMARY KEY(entry_id,form)); CREATE INDEX detail_lookup ON form_details(form);')
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
        for form in set(spellings+[reading]):
            matched=[sense for sense in valid if not sense.findall('stagk') or form==reading or form in [x.text for x in sense.findall('stagk')]]
            # Explicit spelling usage notes rank the relevant sense first without
            # pretending unrestricted shared senses have spelling restrictions.
            matched.sort(key=lambda sense: 0 if any(form in (x.text or '') for x in sense.findall('s_inf')) else 1)
            definitions=['; '.join(g.text or '' for g in sense.findall('gloss') if g.attrib.get('{http://www.w3.org/XML/1998/namespace}lang','eng')=='eng') for sense in matched]
            c.execute('INSERT INTO form_details VALUES(?,?,?,?,?)',(identity,form,form if form in spellings else (spellings or [reading])[0],json.dumps([g for g in definitions if g],ensure_ascii=False),','.join(dict.fromkeys(p.text or '' for sense in matched for p in sense.findall('pos')))))

    entry.clear()
c.execute('INSERT INTO metadata VALUES(?,?)',('source_sha256',hashlib.sha256(source.read_bytes()).hexdigest()))
c.execute('INSERT INTO metadata VALUES(?,?)',('source','https://www.edrdg.org/pub/Nihongo/JMdict_e.gz'))
c.execute('INSERT INTO metadata VALUES(?,?)',('license','CC BY-SA 4.0; https://www.edrdg.org/edrdg/licence.html'))
from index_pitch import index_pitch
index_pitch(c)
c.commit()
print('Indexed',c.execute('SELECT count(*) FROM entries').fetchone()[0],'entry-reading pairs')
c.close(); tmp.replace(output)
