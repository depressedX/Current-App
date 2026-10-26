"""PC-only correctness fixtures using the reference preprocessing; never bundled."""
from pathlib import Path
import numpy as np,essentia.standard as es,onnxruntime as ort,json,wave,sys
r=Path(__file__).resolve().parents[2]
model=r/'Current/Resources/Semantics/Genres/discogs-effnet.onnx'
out=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parent/'.cache/reference'
out.mkdir(parents=True,exist_ok=True)
t=np.arange(80000,dtype=np.float32)/16000
x=(0.3*np.sin(2*np.pi*220*t)+0.1*np.sin(2*np.pi*1700*t)+np.random.default_rng(31).normal(0,.02,len(t))).astype('float32')
x.tofile(out/'pcm.f32');mel=es.TensorflowInputMusiCNN()
m=np.stack([mel(f) for f in es.FrameGenerator(x,frameSize=512,hopSize=256,startFromZero=False)])
m.tofile(out/'mel.f32');patch=np.stack([m[p:p+128] for p in range(0,len(m)-127,62)])
s=ort.InferenceSession(str(model),providers=['CPUExecutionProvider'])
pred=s.run(['activations'],{'melspectrogram':patch})[0]
(out/'scores.json').write_text(json.dumps(pred.mean(axis=0).tolist()))
# Float WAV preserves the reference samples exactly; no compression or resampling differences.
import struct
raw=x.tobytes();fmt=struct.pack('<HHIIHH',3,1,16000,64000,4,32)
(out/'reference.wav').write_bytes(b'RIFF'+struct.pack('<I',36+len(raw))+b'WAVEfmt '+struct.pack('<I',16)+fmt+b'data'+struct.pack('<I',len(raw))+raw)
print('frames',m.shape,'patches',patch.shape)
