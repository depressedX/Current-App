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

**尚无推荐算法、语义理解、BPM 分析或情绪模型。输入文本只命名本次听歌意图，不影响随机选择。**

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
