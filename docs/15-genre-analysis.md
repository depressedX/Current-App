# 音乐风格：客户端接入

2026-10-20。Discogs-EffNet 已接入歌曲池。本轮按要求只做正确性和构建检查，不做性能验收。

## 产品行为

- 新加入歌曲：基础测量 → 乐器识别 → 风格推理 → 原有 DCLAP 链路，仍由同一串行队列调度。
- 歌曲详情展示前 5 个风格候选、大类和原始匹配分数；可同时有摇滚、后摇等标签，不强制单选，不将分数显示成百分比。
- 旧歌曲可单曲“重新分析”，也可用“更新歌曲分析”补齐。失败保留上次结果；暂停、切换账号、播放抢占沿用现有逻辑。
- 网易云百科与本地模型结果分别展示和保存。
- 人声和听感平稳程度继续待定。

## 代码与资源

| 内容 | 位置 |
|---|---|
| 16 kHz 解码、模型校验、ONNX 推理 | `Current/Analysis/GenreAnalyzer.swift` |
| FFT、mel、流式分帧 | `Current/Analysis/GenreFrontend.swift` |
| 多标签结果与版本 | `GenreAnalysis` / `GenreMatch`，存入 `PoolSong.genres` |
| 模型、标签、来源和许可证 | `Current/Resources/Semantics/Genres/` |
| PC 正确性参考 | `Tools/PCGenreReference/` |

资源沿用现有 Semantics 目录打包，iPhone 与 CarPlay 目标均包含；无新增 SPM 依赖。模型 18,027,718 字节，校验 SHA256 `a280825b334797cf677939db8cd5762c0392aedd0ca6415dbc1cd083f045e43c`，与人工验收版本相同。

## 数据契约

- 版本：`discogs-effnet-400-v1`。保存候选、大类、分数、窗口数、解码时长及分析时间。
- 400 个独立 sigmoid 输出，不做 softmax；跨完整窗口取均值，按均值取前 5。
- 16 kHz 单声道；512 点对称 Hann，hop 256；96 个 Slaney mel 频带，三角面积归一化；`log10(1 + 10000 * energy)`。
- 每个输入 `[1,128,96]`，窗口 hop 62 帧。中心补零、尾帧补零及不完整 patch 丢弃行为与用户验收使用的 PC 实现一致。
- 整曲流式读取，保留有限 PCM 与 mel 缓冲；模型每首加载、结束后释放，取消在解码及窗口之间检查。

## 正确性检查

- 官方 Essentia 对照：原生 mel 最大误差约 0.000106，平均约 0.00000556。
- 工程 ONNX Runtime 1.24.2 对照 PC 推理：平均分数最大误差约 0.00000191。
- 浮点 WAV 整条链路、分帧边界、多标签排序、JSON 往返、损坏模型、取消通过。
- 歌曲池覆盖旧数据升级、结果落盘、失败保留与重试。
- 人工判断依据见 [11 首评分结论](validation/genre-effnet-18507048698/ratings-report.md)。不把该样本评价称为通用准确率。

官方资料：[模型元数据](https://essentia.upf.edu/models/feature-extractors/discogs-effnet/discogs-effnet-bsdynamic-1.json)、[前处理](https://essentia.upf.edu/reference/std_TensorflowInputMusiCNN.html)。资源来源、镜像版本及许可证保留在 Genres/manifest.json 和 LICENSE.txt。
