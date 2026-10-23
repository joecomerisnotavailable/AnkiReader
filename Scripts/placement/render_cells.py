"""Render saved fits beside the unrefined grid. Requires Pillow; never runs OCR."""
import argparse,json
from PIL import Image, ImageDraw, ImageOps
p=argparse.ArgumentParser();p.add_argument('fits');p.add_argument('corpus');p.add_argument('output');p.add_argument('--image',default='000815ae45dafec4.jpg');p.add_argument('--prefix',default='今年');a=p.parse_args()
f=next(f for f in json.load(open(a.fits)) if f['image']==a.image and f['text'].startswith(a.prefix))
im=ImageOps.exif_transpose(Image.open(a.corpus+'/'+a.image)).convert('RGB');w,h=im.size
q=[(p['x']*w,p['y']*h) for p in f['corners']];pad=15
crop=(int(min(p[0] for p in q))-pad,int(min(p[1] for p in q))-pad,int(max(p[0] for p in q))+pad,int(max(p[1] for p in q))+pad)
parts=[]
for refined in [False,True]:
 image=im.copy();d=ImageDraw.Draw(image)
 ts=f['boundaries'] if refined else [i/(len(f['boundaries'])-1) for i in range(len(f['boundaries']))]
 for t in ts:
  b,c=(3,1) if f['vertical'] else (1,3)
  start=(q[0][0]+(q[b][0]-q[0][0])*t,q[0][1]+(q[b][1]-q[0][1])*t)
  end=(q[c][0]+(q[2][0]-q[c][0])*t,q[c][1]+(q[2][1]-q[c][1])*t)
  d.line([start,end],fill=(0,140,255) if refined else (255,60,60),width=2)
 parts.append(image.crop(crop))
out=Image.new('RGB',(parts[0].width*2+20,parts[0].height),'white');out.paste(parts[0],(0,0));out.paste(parts[1],(parts[0].width+20,0));out.save(a.output)
print(f['text'])
