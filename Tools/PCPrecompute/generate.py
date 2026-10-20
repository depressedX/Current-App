"""PC only: paired CLAP text vectors + pinned DCLAP audio files for the iOS bundle.
No LLM, user music, login credentials, or network inference is used.
"""
import argparse, hashlib, json, os, shutil, subprocess
from pathlib import Path
P = Path(__file__).resolve().parent
ROOT = P.parents[1]
CACHE = P / '.cache'
os.environ.update(HF_HOME=str(CACHE/'huggingface'), HF_HUB_DISABLE_TELEMETRY='1', TOKENIZERS_PARALLELISM='false')
SPACE = 'dclap-epoch36-text-v1-slaney48k-v1'
TOKENIZER_REVISION = '8fa0f1c6d0433df6e97c127f64b2a1d6c0dcda8a'

def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()

def download(url, dest, expected=None, mirror=False):
    if dest.exists() and (expected is None or digest(dest)==expected): return
    dest.parent.mkdir(parents=True, exist_ok=True)
    if mirror:
        if url.startswith('https://github.com/'): url='https://ghfast.top/'+url
        elif url.startswith('https://huggingface.co/'): url=url.replace('https://huggingface.co/','https://hf-mirror.com/',1)
    part=dest.with_name(dest.name+'.partial')
    subprocess.run(['curl','--fail','--location','--retry','3','--connect-timeout','30','--continue-at','-', '--output',str(part),url],check=True)
    if expected and digest(part)!=expected: raise RuntimeError('SHA256 mismatch: '+dest.name)
    part.replace(dest)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--mirror',action='store_true',help='Use ghfast/hf-mirror for downloads; model SHA256 still checked')
    parser.add_argument('--reference',action='store_true',help='Also generate librosa/native parity fixtures in the PC cache')
    args=parser.parse_args()
    import numpy as np
    import onnxruntime as ort
    from transformers import AutoTokenizer
    ort.disable_telemetry_events()
    manifest=json.loads((P/'model-manifest.json').read_text())
    for asset in manifest['assets']:
        target=CACHE/'models'/asset['name']
        download(asset['url'],target,asset['sha256'],args.mirror)
        if target.stat().st_size!=asset['size']: raise RuntimeError('Size mismatch')
    tokdir=CACHE/'tokenizer'
    for name in ['tokenizer.json','tokenizer_config.json','special_tokens_map.json','vocab.json','merges.txt']:
        download(f'https://huggingface.co/laion/clap-htsat-unfused/resolve/{TOKENIZER_REVISION}/{name}',tokdir/name,mirror=args.mirror)
    tokenizer=AutoTokenizer.from_pretrained(tokdir,local_files_only=True)
    options=ort.SessionOptions(); options.intra_op_num_threads=1
    text=ort.InferenceSession(str(CACHE/'models/clap_text_model.onnx'),sess_options=options,providers=['CPUExecutionProvider'])
    source=json.loads((P/'concepts.json').read_text())
    def unit(a):
        a=np.asarray(a,dtype=np.float32)
        if a.shape!=(512,) or not np.isfinite(a).all() or np.linalg.norm(a)<1e-8: raise RuntimeError('Invalid embedding')
        return a/np.linalg.norm(a)
    concepts=[]
    for c in source['concepts']:
        parts=[]
        for prompt in c['prompts']:
            tokens=tokenizer(prompt,padding='max_length',truncation=True,max_length=77,return_tensors='np')
            parts.append(unit(text.run(None,{k:tokens[k].astype(np.int64) for k in ['input_ids','attention_mask']})[0].reshape(-1)))
        concepts.append({k:c[k] for k in ['id','label','definition']} | {'vector':unit(np.mean(parts,axis=0)).tolist()})
    out=ROOT/'Current/Resources/Semantics';(out/'Models').mkdir(parents=True,exist_ok=True)
    result={'schemaVersion':1,'spaceID':SPACE,'catalogVersion':source['version'],'concepts':concepts,
            'provenance':{'conceptsSHA256':digest(P/'concepts.json'),'tokenizerRevision':TOKENIZER_REVISION,
                          'tokenizerFilesSHA256':{x.name:digest(x) for x in tokdir.iterdir() if x.is_file()},
                          'textModelSHA256':manifest['assets'][0]['sha256'],'generator':'PCPrecompute/generate.py',
                          'promptAggregation':'L2 each template, mean, L2'}}
    (out/'concept-vectors.json').write_text(json.dumps(result,ensure_ascii=False,separators=(',',':'))+'\n')
    for a in manifest['assets']:
        if a['name'].startswith('model_epoch_36'): shutil.copy2(CACHE/'models'/a['name'],out/'Models'/a['name'])
    (out/'model-manifest.json').write_text(json.dumps({'spaceID':SPACE,'assets':[a for a in manifest['assets'] if a['name'].startswith('model_epoch_36')]},indent=2)+'\n')
    print('GENERATED',len(concepts),'concepts;',sum(x.stat().st_size for x in out.rglob('*') if x.is_file()),'bundle resource bytes',flush=True)
    if args.reference:
        import librosa
        # Deterministic input tests every frequency band; generated audio is not user data.
        rng=np.random.default_rng(24680)
        y=(rng.normal(0,.08,480000)+.1*np.sin(2*np.pi*220*np.arange(480000)/48000)).astype(np.float32)
        y.tofile(CACHE/'reference-audio.f32')
        q=(np.clip(y,-1,1)*32767).astype(np.int16).astype(np.float32)/32767
        m=librosa.feature.melspectrogram(y=q,sr=48000,n_fft=2048,hop_length=480,win_length=2048,window='hann',center=True,pad_mode='reflect',power=2,n_mels=128,fmin=0,fmax=14000)
        m=librosa.power_to_db(m,ref=1,amin=1e-10,top_db=None).astype(np.float32)
        m.tofile(CACHE/'reference-mel.f32')
        audio=ort.InferenceSession(str(out/'Models/model_epoch_36.onnx'),sess_options=options,providers=['CPUExecutionProvider'])
        v=audio.run(None,{'mel_spectrogram':m[None,None]})[0].reshape(-1)
        (CACHE/'reference-embedding.json').write_text(json.dumps(unit(v).tolist()))
        print('GENERATED frontend + inference parity fixtures',flush=True)
if __name__=='__main__': main()
