# 架构

## 分层

| 模块 | 责任 |
|---|---|
| App | 创建唯一 AppStore，恢复登录 |
| Core/NetEaseAPI | weapi/eapi 请求、二维码、账号、歌单、播放地址 |
| Core/KeychainStore | 本机登录凭据 |
| Core/AppStore | 账号隔离、异步请求生命周期、队列、反馈、本机历史 |
| Core/PlaybackController | AVPlayer、音频会话、中断、进度、系统媒体控制 |
| Core/Models | 歌曲、听歌意图、反馈、随机队列生成器 |
| Design | 色彩、抽象封面、按钮 |
| Features | 此刻、音乐库、我的、登录、完整播放器、反馈 |
| CarPlay | CPListTemplate / CPTabBarTemplate / CPNowPlayingTemplate |

Swift 5 language mode，iOS 17+。不依赖服务端，无第三方包。
界面通过 ObservableObject 订阅状态，CarPlay 使用同一 AppStore。

## 真实和模拟

真实：网易云协议请求、账号资料、用户歌单、播放 URL、系统音频。
模拟：文本到选歌关系。随机队列生成器不读取情绪或风格。
演示：8 首本项目生成的 24 秒合成音频，离线可运行，歌曲为虚构示例。

## 状态与数据

- 歌曲 metadata、当前 prompt、用户反馈独立保存。
- cookie 存 Keychain；不进入听歌历史或日志。
- 历史和反馈在 Application Support，含账号 ID，界面按账号过滤。
- 登出取消请求，清空播放，先删除本机凭据，再尽力通知服务端。
- 账号 epoch / 播放 generation 拦截迟到响应，防止登出后重新写入旧会话。
- 试听/无 URL 提示不可播放，不自动寻找其他平台资源。

## Kumone 参考边界

本地参考路径：`/Users/liupenghao/Documents/kumone`。
借鉴 Core / Features / Design 的分层、SwiftUI 和 AVPlayer、CarPlay 系统模板。
Current 源码独立编写，没有复制 Kumone 的 UI、引擎或模型代码；服务协议常量和端点来自公开协议资料。
未引入 Kumone 的 LGPL 代码、macOS 专属 AutoMix / 音频分析、MLX 或 Sparkle。

## CarPlay

CurrentCarPlay 配置声明音频 entitlement 与 CarPlay scene；Current 配置仅普通 iPhone scene。
两个构建共享账号和状态代码，不提供驾驶中自由文本输入。
实际设备仍需获批的 Apple provisioning profile；可编译不能证明已获授权或已在车机验证。

官方参考：
- https://developer.apple.com/documentation/carplay
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.carplay-audio
- https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter
- https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/main/util/crypto.js
