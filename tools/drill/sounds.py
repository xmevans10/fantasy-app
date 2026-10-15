"""Generate the original arcade sound cues with Python standard-library PCM synthesis."""
import math,wave,random,struct
from pathlib import Path
root=Path(__file__).resolve().parents[2] / 'BallIQ/Resources/Audio'
root.mkdir(parents=True, exist_ok=True)
for name,notes,duration in [('snap',[180,360],.12),('good',[523.25,659.25,783.99],.6),('bad',[110,82.4],.35),('touchdown',[523.25,659.25,783.99,1046.5],1.1)]:
 samples=[];rate=22050;rng=random.Random(7)
 for i in range(int(rate*duration)):
  t=i/rate;env=min(1,t/.01)*max(0,1-t/duration)**1.8
  v=sum(math.sin(2*math.pi*f*t)*(.5+.5*math.sin(2*math.pi*4*t)) for f in notes)/len(notes)
  if name=='snap':v=.6*(rng.random()*2-1)+.4*v
  samples.append(struct.pack('<h',int(v*env*9000)))
 with wave.open(str(root/f'drill-{name}.wav'),'wb') as w:
  w.setnchannels(1);w.setsampwidth(2);w.setframerate(rate);w.writeframes(b''.join(samples))
