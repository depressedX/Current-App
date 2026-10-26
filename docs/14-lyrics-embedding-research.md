# 歌词语义检索：候选与边界

2026-10-20。本页保留选型调研。BGE 已完成独立实验并接入，见 [歌词索引与主题检索](16-lyrics-analysis.md)；iPhone 12 性能仍待真机验证。

## 推荐先试

中文先试 **BGE-small-zh-v1.5**。中英日等跨语言检索再比较 **multilingual-e5-small**。歌词 embedding 与音频 DCLAP 分开存储、分别匹配；不能直接比较两种空间的向量。

| 候选 | 适用点 | 体积与限制 |
|---|---|---|
| [BGE-small-zh-v1.5](https://huggingface.co/BAAI/bge-small-zh-v1.5) | 中文检索；512 维、512 token；MIT | 官方 FP32 权重 95.8 MB。社区量化 ONNX 约 24 MB，另需 tokenizer；未实测 |
| [multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small) | 多语言、跨语言检索；384 维、512 token；MIT | 官方 FP32 权重 471 MB，small 不代表比中文 BGE 小。检索需 query:/passage: 前缀 |
| [gte-multilingual-base](https://huggingface.co/Alibaba-NLP/gte-multilingual-base) | AudioMuse-AI 的现成实现参考 | 不是本轮手机小模型首选，不预先下载 |

BGE 量化文件：[ONNX 社区转换](https://huggingface.co/onnx-community/bge-small-zh-v1.5-ONNX/tree/main/onnx)。model_quantized.onnx 约 168 kB，还必须带约 23.8 MB 的外部权重；不能只看图文件大小。包体、运行内存、延迟是三件事。

## 能解决什么

适合找主题接近的歌词，例如离别、故乡、成长，或找与指定歌曲歌词相近的歌曲。它不直接输出可信的情绪标签、叙事解释或否定逻辑；诗歌隐喻、反讽和“不要伤感”类要求要专门测试。歌词快乐与声音快乐分开处理。

## 最小链路（设计建议）

1. 获取已有文本歌词，不先做语音识别。
2. 去 LRC 时间戳、创作人员信息；保留原文与译文来源，重复副歌在索引侧去重，不改展示歌词。
3. 按段落切块，优先约 128–256 token，跨段少量重叠，具体按 tokenizer 测量。
4. 用同一模型生成歌词块向量和查询向量，遵守各自 pooling、归一化与指令规范。
5. 先召回相关块，再聚合到歌曲；保留命中段落便于核对，避免整首一个均值丢失局部主题。
6. 版本、歌词内容哈希、语言、切块策略随向量保存。无歌词标为缺失，不等于纯音乐。
7. 音频条件和歌词条件分别评分；必要时先按 BPM/风格筛选，再按歌词排序，不把两个 embedding 直接做点积。

首轮用已有歌单中文歌曲，人工给 10 条明确主题需求及反例。对照原始关键词搜索，检查前几名是否更相关；通过后才移到手机。跨语言另设测试集。

## 可借鉴项目

- [AudioMuse-AI 歌词链路](https://github.com/NeptuneHub/AudioMuse-AI/blob/main/docs/ALGORITHM.md#3-lyrics-analysis)：文本歌词优先，多语言向量、独立歌词索引、查询模型按需加载。它的缺词兜底和音频推断不能直接当成 Current 的事实标签。
- [swift-embeddings](https://github.com/jkrukowski/swift-embeddings)：Swift / MLTensor 路线，支持多种 encoder，文档明确列出 multilingual-e5-small。须核对具体版本的 iOS API、tokenizer 和 pooling，不能仅凭 Package.swift 平台声明认定真机兼容。
- [Hugging Face Ember](https://github.com/huggingface/ember)：sentence-transformers → Core ML 的转换及 ANE 推理参考，不是可以直接嵌入 iPhone 的完整功能。

Current 已有 ONNX Runtime，首轮优先复用运行时。Core ML 是效果验证后的可选优化，不承诺一定更快。批量建索引串行执行；查询只编码短文本，歌词向量缓存复用。
