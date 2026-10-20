# 歌曲分析：开源项目调研

日期：2026-10-20。范围：公开架构文档、核心源码与官方示例；未运行这些 Python 模型，也未做 iPhone 模型性能实测。

## 结论

- 借鉴 AudioMuse 的「导入 → 独立任务 → 分阶段结果 → 检索池」，不搬其服务端技术栈到手机。
- 当前端上先跑有资源上限的原生声学测量。语义优先评估 DCLAP 音频分支，文本和固定听感锚点另行处理。
- 完整 CLAP、Music2Emo 暂作离线对照。轻量、ONNX、参数量小，都不等于已经通过 iPhone 12 验收。
- 不用 BPM、响度或过零率推断「快乐」「浪漫」「朦胧」。基础完成与听感就绪分别表达。

## AudioMuse-AI：参考任务架构

Flask 提交任务，PostgreSQL 保存状态和结果，独立 worker 获取音频并运行多阶段分析。基础声学、MusiCNN、DCLAP 与可选歌词各有职责，结果供相似度索引和歌单生成使用。

值得借鉴：稳定歌曲身份、去重、阶段补齐、任务取消、临时文件清理、失败隔离。手机只保留串行调度，不引入容器、数据库队列或整套多模型依赖；也不把“缺少可选特征”伪装成完整听感分析。

依据：[架构与算法](https://github.com/NeptuneHub/AudioMuse-AI/blob/main/docs/ALGORITHM.md)、[单曲处理源码](https://github.com/NeptuneHub/AudioMuse-AI/blob/main/tasks/analysis/song.py)、[分析辅助源码](https://github.com/NeptuneHub/AudioMuse-AI/blob/main/tasks/analysis/helper.py)。

## Essentia：参考明确属性与统计聚合

C++ 算法网络支持流式处理；Music Extractor 汇总频谱、节奏、调性等帧级结果，高层分类另加模型。RhythmExtractor2013 有 multifeature 与 degara 路径；后者没有可用的节拍置信度，不能把固定输出当概率。

Current 借鉴按帧计算、汇总并保存来源，不直接移植整套 extractor。当前 Swift BPM 是简化能量起音自相关，不是 Essentia 同算法，准确率需要真实音乐对照。

依据：[Extractor](https://essentia.upf.edu/streaming_extractor_music.html)、[RhythmExtractor2013 源码](https://github.com/MTG/essentia/blob/master/src/algorithms/rhythm/rhythmextractor2013.cpp)、[模型](https://essentia.upf.edu/models.html)。

## LAION CLAP：参考开放听感匹配

音频与文本编码到同一向量空间，支持没有固定标签的描述。官方封装以 48 kHz 音频和固定时长输入做预处理，融合与非融合配置的裁剪方式不同；直接调用示例不等于稳定的整曲摘要。

Current 需要固定版本、窗口位置、预处理与聚合规则，用余弦相似度排序；不能称为情绪概率。中文描述需和英文改写比较，不能假设模型天然理解中文听感。

依据：[推理封装 hook.py](https://github.com/LAION-AI/CLAP/blob/main/src/laion_clap/hook.py)、[项目说明](https://github.com/LAION-AI/CLAP)。

## AudioMuse-AI-DCLAP：优先验证轻量音频分支

蒸馏音频编码器约 7M 参数，输出 512 维；文本编码器仍复用教师模型。示例使用 48 kHz 单声道、10 秒窗口、50% 重叠，log-mel 输入逐窗推理后平均并归一化。

这些预处理必须一致，不能把当前 11.025 kHz 声学流直接喂给它。可先把固定描述的文本向量预计算，只在手机加载音频分支。公开加速数据来自树莓派，不外推为 iPhone 耗时；ONNX 转 Core ML 后还需检验算子、精度、内存和实际计算设备。

依据：[README 与推理示例](https://github.com/NeptuneHub/AudioMuse-AI-DCLAP)。

## Music2Emo：情绪对照，不是完整听感模型

多任务头同时预测情绪分类与 Valence/Arousal。实际入口还调用 MERT-v1-95M 特征提取及音乐特征处理，不能只看最后的小型分类头估算部署成本。

适合验证情绪轴，不覆盖浪漫、朦胧、空间感的全部含义。当前不把它的 PyTorch 和预处理链装进 iPhone；先离线评估，只有明确收益才做移动端转换。

依据：[music2emo.py](https://github.com/AMAAI-Lab/Music2Emotion/blob/main/music2emo.py)、[特征提取源码](https://github.com/AMAAI-Lab/Music2Emotion/blob/main/preprocess/feature_extractor.py)、[项目说明](https://github.com/AMAAI-Lab/Music2Emotion)。

## librosa：实验基准与算法对照

Python 音乐分析库。beat_track 从起音强度估计节奏，再用动态规划选择一致的节拍位置；不仅是读音量或数波峰。

用于离线对照与实验，不把 Python、NumPy、Numba 运行时打包到 App。Current 简化 BPM 不能声称达到 librosa 的节拍跟踪质量。

依据：[beat.py](https://github.com/librosa/librosa/blob/main/librosa/beat.py)。

## 许可与证据边界

- AudioMuse／DCLAP 仓库 AGPL-3.0；自研不能直接把它们当宽松许可 SDK。
- [Essentia 库](https://essentia.upf.edu/licensing_information.html) 与模型分别授权；MTG 模型通常有非商业条款。
- Music2Emo [源码 LICENSE](https://github.com/AMAAI-Lab/Music2Emotion/blob/main/LICENSE) 为 MIT，而 [Hugging Face 模型卡](https://huggingface.co/amaai-lab/music2emo) 标 Apache-2.0；仍需分别核对 MERT 等依赖权重。
- CLAP、librosa 的代码许可不自动覆盖所有依赖、权重和音频输入。
- 本次 Current 独立编写 Swift 声学实现，没有复制上述项目的算法实现，也未随 App 分发它们的模型。

公开源码证明架构和接口，不证明真实歌库效果、网易云分析输入可用性或 iPhone 性能。
