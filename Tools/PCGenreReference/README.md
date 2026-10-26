# 风格模型参考检查

这里只生成正确性对照，不做性能验收。App 不依赖 Python / Essentia。

- 模型：仓库内 `Semantics/Genres/discogs-effnet.onnx`，18 MB，400 个独立风格输出。
- `generate.py`：用官方 `TensorflowInputMusiCNN` 和 ONNX CPU 推理生成确定性 PCM / mel / 输出分数。
- Python 环境需 numpy、essentia、onnxruntime；本轮版本见 docs/validation/genre-effnet-18507048698/manifest.json。
- `Scripts/check-genres.sh [参考文件目录]`：编译生产 Swift 代码，对比 mel、推理分数和文件解码，检查取消、损坏文件、多标签结果。
- 本机默认复用 `/tmp/current-spm` 中 Xcode 已获取的 ONNX Runtime 1.24.2。可用 `CURRENT_SPM_CACHE` 指定同版本缓存，不重复下载。
- 所有生成文件写 `.cache/`，不提交，不打包到 iPhone。

```sh
python generate.py
../../Scripts/check-genres.sh
```
