# Current

此刻，想听什么？原生 iPhone 音乐播放器，支持 CarPlay 模板。

## 启动

```sh
xcodegen generate
open Current.xcodeproj
```

选择 **Current** scheme、iPhone 模拟器运行。真机先配置自己的 Team 和 Bundle ID。
最低 iOS 17，仅 iPhone；无 Mac、iPad 或 Catalyst target。没有第三方运行时依赖。

Current scheme 允许在 Apple Silicon Mac 上选择 **My Mac (Designed for iPhone)**，直接运行 iPhone App，无需模拟器。这不是独立 macOS 版本；CarPlay 仍需设备和授权。

## MVP

- 网易云二维码登录、登录恢复、用户头像/昵称/ID、退出并删除 Keychain 凭据。
- 音乐库：读取前 100 个用户歌单，可选择选歌范围。
- 输入一句话，随机组成队列；真实歌单读取前 60 首，随机取最多 12 首。
- AVPlayer 播放、进度、上一首/下一首、系统媒体控制、后台音频。
- 很合此刻 / 这次不想听 / 情绪不太对 / 风格不太对 / 听腻了。
- 本机保存最近队列和反馈，按账号隔离。不会修改网易云收藏。
- 未登录可体验 8 首原创合成短音频；演示和真实账号明确分开。

- 「我的 → 歌曲池」：整单／单曲加入，串行基础分析、暂停继续、失败重试与结果详情。

**已接入 OpenRouter 文本理解与多条件检索。** 在「我的 → AI 设置」填写个人 Key，默认模型 `openrouter/free`，Key 仅存本机 Keychain。曲风、BPM 和听感要求取交集，再排序；“120 BPM 左右”默认 110–130，“最好／优先”的项仅影响排序。歌单显示实际条件，一次加入全部匹配歌曲，不用不匹配的歌曲凑数；听完后可手动再听一遍。反馈暂不参与排序。

## 歌曲分析

「我的 → 歌曲池 → + → 选择歌单 → 全部加入／单曲 +」，返回歌曲池点「继续分析」。演示空间可直接分析原创短音频。

当前只测量 BPM、周期强度、电平、动态分布和过零率；风格、浪漫、朦胧等维度明确显示待接入模型。分析与日常推荐队列分开，播放／后台／节能／过热时让路。

[开源调研](docs/07-analysis-research.md) · [分析方案与 iPhone 12 验收门槛](docs/08-song-analysis-pipeline.md)

无需模拟器运行分析检查：`zsh Scripts/check-analysis.sh`。

## CarPlay

选择 **CurrentCarPlay** scheme。两套构建使用相同源码和 Bundle ID，不要同时安装。
提供当前队列、最近队列、系统 Now Playing 和「很合此刻」按钮。生成队列和登录在 iPhone 完成。
真机签名需要 Apple 批准 `com.apple.developer.carplay-audio`，普通 Current 构建不要求该能力。

## 验证

无需模拟器的核心检查：`./Scripts/check-core.sh`。加 `--live` 会使用临时会话检查网易云二维码接口，不读取保存的账号。

模拟器下载已按用户要求取消；下方测试命令仅供运行时安装后使用。

```sh
xcodebuild -project Current.xcodeproj -scheme Current -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcodebuild -project Current.xcodeproj -scheme CurrentCarPlay -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

真实登录要由用户在网易云 App 确认。服务端风控、会员和地区权限影响实际播放；不替换第三方音源，不播放被识别为试听的资源。

- [产品范围](docs/01-product-mvp.md)
- [架构与参考](docs/02-architecture.md)
- [调研资料](docs/03-research.md)
- [验证记录](docs/04-validation.md)

## 真机排障

「我的 → 诊断日志」可查看、筛选、准备导出并手动分享日志。复现后导出即可，不需要连接 Xcode；日志不包含凭据、歌曲名、听歌需求或签名 URL。见 [日志方案](docs/09-diagnostic-logging.md)。
