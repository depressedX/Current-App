# BGE 原生一致性基准

这里生成合成文本的分词 ID 与向量，用来对照 Swift 实现。不是把用户歌词预计算后放进 App；实际歌词索引由 iPhone 本地生成。

在仓库根目录执行：

```sh
uv venv --python 3.11 Tools/PCLyricsReference/.venv
uv pip install --python Tools/PCLyricsReference/.venv/bin/python onnxruntime==1.24.2 numpy tokenizers
Tools/PCLyricsReference/.venv/bin/python Tools/PCLyricsReference/generate.py --assets Current/Resources/Semantics/Lyrics
zsh Scripts/check-lyrics.sh
```

原生检查复用 `/tmp/current-spm` 已解析的项目运行时；可用 `CURRENT_SPM_CACHE` 指定缓存路径，不下载另一套运行时。需先让 Xcode 完成项目依赖解析。

`.venv/`、`.cache/` 均忽略。生成物只有合成文本，不提交个人歌词或试跑音频。
