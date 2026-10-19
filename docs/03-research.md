# 前期调研索引

整理时间：2026-10-19。以下是技术路线和材料，不是本项目已验证的模型能力。

## 自研网易云客户端

Kumone / YesPlayMusic 提供登录、用户歌单、播放的公开实现。Kumone 原生实现 weapi/eapi，直连网易云。
第三方实现证明技术路线存在，不保证当前账号、地区、会员权限和接口长期有效。

- Kumone：https://github.com/missuo/kumone
- YesPlayMusic：https://github.com/qier222/YesPlayMusic
- API Enhanced：https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced

## Kumone BPM 研究

本地源码 `Core/Player/Analysis/TrackAnalyzer.swift`：解码为 22.05kHz、STFT、起音包络、自相关估计 BPM、动态规划跟踪拍点。
结果还有 downbeat、调性、能量、LUFS、人声活跃度、结构估计。`AutoMixTypes.swift` 定义数据。
分析依赖音频，不是网易云 BPM metadata；当前实现受 macOS 编译条件限制。
UI 数值在 DEBUG AutoMix Debug 的 Next/preload 区域，不是普通歌曲详情页。
有合成鼓点测试，不能推导真实曲库准确率。

## 歌曲数据库

| 来源 | 用途 | 限制 |
|---|---|---|
| Beatport | BPM、Key、电子乐风格 | API 权限待确认；不能推断全曲库覆盖 |
| GetSongBPM | BPM、调性 API | 申请 Key、要求回链 |
| ReccoBeats | 音频特征、相似推荐 | 真实网易云歌单命中率待测 |
| Discogs | Genre/Style、发行版本 | 发行级标签不等于每首歌标签 |
| Cyanite | 输入音频分析情绪/风格 | 服务费用与授权另核实 |
| AcousticBrainz | 历史音频特征 | 已停止采集，不作为主数据源 |

匹配优先 ISRC，再结合歌手、曲名、版本和时长。Original / Extended / Remix / Live 不混为一首。

- https://www.beatport.com/genre/house/5/tracks
- https://getsongbpm.com/api
- https://reccobeats.com/
- https://support.discogs.com/hc/en-us/articles/360005055213-Database-Guidelines-9-Genres-Styles
- https://docs.cyanite.ai/docs/guides/model-outputs/
- https://acousticbrainz.org/download

## 开源模型

| 方案 | 能力 | 采用前检查 |
|---|---|---|
| LAION CLAP | 音频/文字向量，按描述搜索 | 中文/英文 prompt 对比、组合条件可靠性；相似度不是概率 |
| Music2Emo | 情绪标签、Valence、Arousal | 本地速度、华语曲库效果、依赖授权 |
| Essentia | BPM、风格、情绪、人声等 | 库与预训练权重许可证分开，模型通常非商业限制 |
| AudioMuse-AI | 完整个人曲库分析/智能歌单 | 作为产品与流程参考，AGPL 项目 |

「阴郁」不直接等同 sad；悲伤可以低能量，也可以激烈。听感情绪与歌词情绪分别建模。
尚未运行这些模型或对比准确率。

- https://github.com/LAION-AI/CLAP
- https://huggingface.co/amaai-lab/music2emo
- https://github.com/AMAAI-Lab/Music2Emotion
- https://essentia.upf.edu/models.html
- https://essentia.upf.edu/licensing_information.html
- https://github.com/NeptuneHub/AudioMuse-AI

## 个性化与反馈

歌曲属性 / 长期偏好 / 当前意图分开。单次「不喜欢」不能判断是情绪、风格还是听腻。
先做轻量反馈和可解释规则，积累交互后再引入 Contextual Bandit。
Bandit 根据上下文选歌，从反馈更新策略，平衡利用和探索；不负责理解音频或自动解释负反馈原因。
若引入探索，要记录候选、选中项、选择概率、上下文和结果，用于策略评估。

- https://vowpalwabbit.org/docs/vowpal_wabbit/python/latest/tutorials/python_Contextual_bandits_and_Vowpal_Wabbit.html

## 交互参考

- Pinterest Board：集合表达一种意图，收藏动作自然完善集合。
- Spotify AI Playlist：自然语言起步，继续修改结果。
- Spotify daylist：按时间/场景变化，不把临时需求混入永久偏好。
- Readwise Reader：消费时轻量整理，筛选视图立刻消费整理结果。
- Letterboxd：看过、喜欢、评分、加入片单是不同信号。

https://newsroom.pinterest.com/news/pinterest-boards-get-ai-powered-upgrade-for-personalized-experience/
https://newsroom.spotify.com/2024-04-07/spotify-premium-users-can-now-turn-any-idea-into-a-personalized-playlist-with-ai-playlist-in-beta/
https://support.spotify.com/ws/article/exclude-playlists-or-tracks-from-your-taste-profile/
https://docs.readwise.io/reader/docs/faqs/filtered-views
https://letterboxd.com/welcome/
