# PC 预计算

这一步只在电脑运行。把固定概念的英文描述交给 **DCLAP 配套 CLAP 文本编码器**，生成与手机音频向量同空间的 512 维向量。

```sh
cd Tools/PCPrecompute
./precompute.sh --reference
# 网络受限时可加 --mirror；模型仍校验固定 SHA256。
```

需要 `uv`。依赖使用 `requirements.lock` 固定完整版本；`requirements.txt` 记录直接依赖。Python 环境、约 501 MB 文本模型、tokenizer 和对照数据都放在 `.cache/`、`.venv/`，已忽略，不进 Xcode。

## 输入与输出

- `concepts.json`：稳定 ID、中文名称、定义、英文多模板。修改听感词从这里开始。
- `model-manifest.json`：固定发行版本、大小、SHA256。
- `generate.py`：每个模板编码并归一化 → 求均值 → 再归一化。
- `Current/Resources/Semantics/concept-vectors.json`：生成的向量、概念及来源指纹。
- `Current/Resources/Semantics/Models/`：音频图与外部权重，二者必须放在同一目录。
- `--reference`：另生成 librosa mel 和 Python ORT 向量，供原生数值对照；不进 App。

生成的资源应随源码维护。打开 Xcode 即可使用；运行 App 不需要下载文本模型，也不需要 Python。

概念是产品定义的候选听感，不是客观真值。相反的词也分别计算，不假设“阴郁 = 1 − 快乐”。新增、改写模板时同步提升 `catalogVersion` 和 Swift `SemanticSpace.catalogVersion`；换模型或前处理时提升 `spaceID`，旧结果重新分析。

## 验证

```sh
zsh Scripts/check-semantics.sh Tools/PCPrecompute/.cache
zsh Scripts/check-native-semantics.sh /absolute/path/to/local-audio.m4a
```

从仓库根目录执行。后者直接编译生产 Swift 源码，用原生 ONNX Runtime 对比 Python 结果；可选音频路径用于检查真实解码、推理与取消。不会下载模拟器。

## 清理

预计算和对照结束后可以删除本目录的 `.cache/`、`.venv/`。保留生成的 Xcode 资源；下次重算会重新下载 PC 文本模型。
