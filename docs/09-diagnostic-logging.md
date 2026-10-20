# 真机诊断日志

## 参考与实现

Kumone 使用 Apple `Logger / OSLog`，按 API、音频源和播放模块分类，记录操作、错误码和耗时。参考：

- `kumone/Sources/Kumone/Core/API/NeteaseClient.swift`
- `kumone/Sources/Kumone/Core/Player/AudioSourceHTTPClient.swift`
- `kumone/Sources/Kumone/Core/Player/Engine/PlaybackJournal.swift`

Current 独立实现 `Diagnostics/AppLog.swift`：系统统一日志＋本机 JSONL 日志，不复制 Kumone 源码，也不引入第三方依赖。

## 真机如何使用

「我的 → 诊断日志」：查看最近 200 条、按类别筛选、点开事件详情、刷新。

复现问题后点「准备导出 → 分享日志」，由用户自行选择保存或分享位置。导出包含全部保留记录与 App／系统版本、设备型号，不自动发送给任何服务。

「清除诊断日志」删除保留文件及导出快照；之后的新事件继续记录。它不清除听歌历史、歌曲池或登录状态。

Mac 连接 iPhone 后，也可在 Console 选择设备，筛选 subsystem `com.liupenghao.current`。系统日志保留时间由 OS 管理；App 内文件用于脱离 Xcode 后回看。

## 记录范围

| 类别 | 事件 |
|---|---|
| app | 启动、前后台、日志清除 |
| auth | 登录恢复、登录成功、退出、演示模式 |
| api | 固定操作名、开始／成功／失败／取消、HTTP 与业务码、耗时 |
| playback | 加载、就绪、失败、暂停／继续、音频中断与输出变化 |
| analysis | 入池数量、阶段变化、暂停／继续、账号空间切换、下载／解码耗时与结果 |
| storage | 歌曲池恢复、歌曲池和历史保存失败 |

每条包含时间、级别、启动 session、环境版本。分析任务使用随机 job UUID；TaskLocal trace 将同一任务的 API、下载和解码串起来；span 对应一次具体操作。

分析可区分：获取地址、下载、容器识别、解码失败，以及 HTTP／业务码、网络码、AVFoundation 和底层 OSStatus 原因。已知应用错误另有稳定分类，不依赖异常文本。

不逐帧记录播放进度或 PCM 数据。

## 隐私边界

日志 API 不接收自由文本 message 或任意 metadata，调用点只能传固定枚举、数字和随机关联编号。

不记录：cookie、二维码 key、请求／响应正文、签名 URL、完整网络地址、用户名／账号 ID、歌曲名／歌曲 ID、歌单名、自然语言需求、歌词、音频数据、本机文件路径。

系统 Error 只提取白名单 domain、数值 code 和一层底层错误码，不读取或导出 localizedDescription；未知 domain 归为 Application。

OSLog 的 public 输出只包含上述结构化安全字段，不把原始 Error 或 URL 插值进去。关联编号用于事件串联，不能直接还原歌曲。

## 容量与性能

- utility 串行队列执行编码、系统日志和文件 I/O；主线程不写文件。
- 主日志 512 KiB，3 个滚动归档，合计最多约 2 MiB。
- 一个可覆盖的 JSON 导出快照，另占约 2 MiB；再次导出覆盖旧快照。
- 内存待写队列最多 256 条；过载时丢弃并在后续事件记 droppedBefore，不无限积压。
- 启动后首次追加会隔开上次中断留下的半行；读取时跳过不完整条目。
- 日志目录不参与备份；文件使用首次解锁后可读保护。
- 退出／崩溃前尚未写入的少量日志可能丢失；不提供同步崩溃处理器，系统 crash report 仍需单独查看。

## 验证

`zsh Scripts/check-diagnostics.sh`：关联编号、错误链脱敏、导出元信息、文件轮转上限、并发写入、半行恢复、清除日志和快照。

`zsh Scripts/check-core.sh` 与 `zsh Scripts/check-analysis.sh --download`：回归原有登录协议和完整音频分析链路。

真机查看和分享入口尚需设备验收；不以主机检查代替实际分享扩展和锁屏行为。

听感分窗事件 `semanticDecode` 增加 `audioRead` 数值上下文：读取／转换阶段、起点、实际及期望帧数、采样率、声道、状态和引擎；兼容旧日志缺少该字段。
