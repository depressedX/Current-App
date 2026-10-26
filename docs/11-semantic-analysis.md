# 听感分析：当前工程方案

> 客观特征新版见 [客观歌曲分析 v1](12-objective-song-profile.md)。DCLAP 相似度仍是实验结果，不作为确定分类。
## 分工

| 位置 | 工作 | 随 App 分发 |
|---|---|---|
| `Tools/PCPrecompute` | 配套 CLAP 文本编码器预计算固定概念 | 否 |
| `Resources/Semantics/concept-vectors.json` | 16 个听感概念的 512 维向量 | 是 |
| `Resources/Semantics/Models` | DCLAP 音频 ONNX 图 + 外部权重 | 是，合计 22,411,906 字节 |
| `DCLAPFrontend` | Swift / Accelerate 音频前处理 | 是 |
| `DCLAPEngine` | 官方 ONNX Runtime 1.24.2 原生绑定 | 是 |
| `OpenRouterIntentResolver` | 解析 BPM 条件、听感概念和权重 | 是，个人 Key；默认 `openrouter/free` |
| `MockListeningIntentResolver` | 随机选择概念向量 | 仅保留离线测试入口，生产生成不调用 |

不做模型下载管理页。音频模型随 App 更新，文本模型只留在电脑。运行库也有体积，不能把 22.4 MB 说成 App 最终增量。当前没有 Core ML 转换；后续可以替换推理适配层，不改歌曲池和向量空间协议。

## 音频链路

下载一个临时音频 → 基础声学分析 → DCLAP → 原子保存 → 删除临时音频。

- 基础测量仍是 11.025 kHz 流式读取；网易云百科 BPM 优先，本地 BPM 后备。
- 听感使用 AVAudioFile 按源 PCM 帧定位，AVAudioConverter 显式流式转换为 48 kHz mono Float32；10 秒窗、5 秒 hop。
- 最多取前／中／后三个 20 秒区域，共最多 9 窗。重复起点去重；不足 10 秒不伪造向量。
- 每窗先 int16 量化，STFT 2048 / 480、周期 Hann、reflect center、128 Slaney mel、0–14 kHz、power dB，无 top_db 截断。
- 窗口输出均值后 L2 归一化。保存窗口起点与计算耗时，不宣称覆盖整首。
- 余弦相似度排序，显示前 6 个概念；不是概率，也没有统一“合格”阈值。

## 存储

参考 Kumone `AnalysisStore`：分析结果属于 Application Support，独立于音频缓存，用 actor 串行管理。

```text
Application Support/Current/
  song-pool.json             # 任务、基础值、听感摘要及记录 ID
  SongAnalysis/<UUID>.json   # 不可变 512 维音频向量、账号、歌曲 ID、空间版本
```

- 任务摘要不塞全部向量，阶段更新不反复重写向量。
- 原子写入、设备首次解锁后可读。读取校验账号、歌曲 ID、schema、空间版本、维度及有限值。
- 重新分析先写新记录，成功后换引用。失败保留旧值；未完成／版本不兼容的结果不参与推荐。
- 历史 JSON 缺少 `semantic` 仍可读取；点“补全听感分析”升级。
- 移除或替换后无引用的记录留一天，再于成功保存歌曲池后清理，避免误删待提交记录。
- 不保存分析音频，不记录 cookie、签名 URL 或歌曲原始文本到诊断日志。

## 查询链路（临时）

文本输入 → `OpenRouterIntentResolver` → **JSON Schema 推荐查询** → 校验范围／概念／权重 → BPM 筛选 → 当前账号已完成歌曲的音频向量 → 听感加权排序 → 首批最多 12 首，剩余 3 首时补歌。

网络层使用 `MacPaw/OpenAI 0.5.3`，请求 `/api/v1/chat/completions`，启用严格 `json_schema` 和 `provider.require_parameters`。模型返回概念 ID 和权重，App 查本地同空间概念向量，不接受模型生成的 embedding。Key 在「我的 → AI 设置」保存／清除／测试连接，仅存独立 Keychain 项；只发送本次需求及概念词表，不发送音频、完整歌单或网易云凭据。模型拒绝、输出截断、非法条件、免费额度不足和网络失败会明确提示，不回退随机选歌。

反馈仍只属于 Current；没有同步网易云收藏，也还没有训练个性化权重。

## 手机约束

每首使用一个后台 utility worker、一个 ONNX session、单线程 CPU 推理。每次只保留 10 秒 PCM 和一窗 mel；不缓存整曲。每首结束释放 session，不永久驻留模型。

播放／加载、后台、低电量、过热时取消；解码和前处理检查取消，单次 ORT run 完成后检查取消。旧任务退出才开下一首，暂停响应上限取决于一个推理窗，必须真机实测。

iPhone 12 性能仍需真机 Instruments 验收：峰值 footprint、暂停延迟、连续任务温升和播放响应。Mac 对照只能证明实现一致，不能代替真机数据。

## 来源

- [DCLAP：模型与前处理](https://github.com/NeptuneHub/AudioMuse-AI-DCLAP)
- [官方 ONNX Runtime Swift 包](https://github.com/microsoft/onnxruntime-swift-package-manager/tree/1.24.2)
- 本地 Kumone：`Core/Storage/AnalysisStore.swift` 的持久化组织；没有引入其 macOS 分析运行时。

模型仓库标注 AGPL-3.0；运行库 MIT。第三方声明放在资源目录，正式分发前需按对应许可处理源码等义务。
