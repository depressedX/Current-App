"""Generate small synthetic parity fixtures, never personal lyrics or downloaded weights."""
from pathlib import Path
import argparse,json
import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer
p=argparse.ArgumentParser();p.add_argument('--assets',type=Path,required=True);p.add_argument('--out',type=Path,default=Path(__file__).parent/'.cache/reference');a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True)
t=Tokenizer.from_file(str(a.assets/'tokenizer.json'));t.enable_truncation(max_length=256)
opts=ort.SessionOptions();opts.intra_op_num_threads=1;opts.inter_op_num_threads=1
s=ort.InferenceSession(str(a.assets/'model_quantized.onnx'),sess_options=opts,providers=['CPUExecutionProvider'])
texts=['分别、离别','为这个句子生成表示以用于检索相关文章：分别、离别','毕业那天，我们约定未来再见。','今晚准备做一碗蔬菜汤。','Hello WORLD café naïve，中文标点！','[CLS]早安[MASK] 晚安[SEP]','\x00早\u200b安\n Café\t你好\ufffd','𠀀𠮷 山川 🌙 👩‍💻','a'*101,'分别，' * 300]
rows=[]
for text in texts:
 e=t.encode(text);n=len(e.ids)
 inputs={'input_ids':np.array([e.ids],dtype=np.int64),'attention_mask':np.array([e.attention_mask],dtype=np.int64),'token_type_ids':np.array([e.type_ids],dtype=np.int64)}
 v=s.run(['last_hidden_state'],inputs)[0][0,0];v=v/np.linalg.norm(v)
 rows.append({'text':text,'ids':e.ids,'vector':v.tolist()})
(a.out/'reference.json').write_text(json.dumps(rows,ensure_ascii=False))
print('Saved',len(rows),'synthetic tokenizer/vector references')
