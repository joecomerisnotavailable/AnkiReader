#!/usr/bin/env python3
import csv, io, json, subprocess, time
from pathlib import Path
root=Path('Benchmark/private')
selected=json.loads((root/'novel-selection.json').read_text())
results=[]
for image in selected:
    start=time.monotonic()
    p=subprocess.run(['tesseract',str(root/'normalized'/image),'stdout','--tessdata-dir','Resources/tessdata','-l','jpn_vert','--psm','5','-c','tessedit_create_tsv=1'],capture_output=True,text=True,timeout=120)
    words=[r for r in csv.DictReader(io.StringIO(p.stdout),delimiter='\t') if r.get('text','').strip()]
    result={'image':image,'seconds':time.monotonic()-start,'words':words,'error':p.stderr if p.returncode else None}
    results.append(result)
    (root/'tesseract-mac.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    print(image, len(words),round(result['seconds'],2),flush=True)
