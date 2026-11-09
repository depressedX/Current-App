# 播放风控排查（2026-11-09）

## 真机结论

已从连接的 iPhone 读取 Current 脱敏日志。获取播放地址接口返回 HTTP 200、业务码 `-460`，随后播放失败。失败发生在创建音频播放器资源之前，不是 AVFoundation 解码问题。

- 11 月 9 日 13:57:41–42：获取地址失败 `-460`，随后播放失败。
- 13:30:50、13:36:25：同一启动会话获取地址成功，播放器 ready。
- 13:16:06–10、13:41:37–40：有密集失败请求；日志无法判断是用户连续切歌还是其他触发，不应据此断言自动重试。
- 11 月 4 日也已有间歇性 `-460`。

时间为 Asia/Shanghai。日志不含请求/响应正文，因此不能进一步确定服务端依据的是 IP、账号、请求特征还是其他策略。截图提示与该业务码一致；不代表设备真的不安全，也不等同于歌曲无版权或登录过期。

## Kumone 对照与修复

参考本机 Kumone 的 `Sources/Kumone/Core/API/NeteaseClient.swift` 中 EAPI 请求构造：

- 两者都使用 `interface.music.163.com/eapi/song/enhance/player/url/v1`，没有发现专门解除 `-460` 的流程。
- Current 原先将整份 Cookie jar 放进加密 header，仅补 os/appver，缺少 requestId、deviceId、版本等客户端字段。
- Current 原先发送 iPhone User-Agent，但 Cookie 和 EAPI header 声明 PC 客户端。
- 现补齐 Kumone 所用协议字段，使用应用标识 `current`（不收集硬件 ID），只在加密 header 中携带 MUSIC_U / __csrf；HTTP User-Agent 与现有 PC 协议配置对齐。
- 保留 standard/aac，避免把编码变化混入本次修复；不复制 macOS 功能或凭据文件存储方式。

这是待真机验证的兼容性修复，不是已证实的风控根因，也不保证服务端放行。不增加自动重试、代理轮换、第三方音源或权限绕过。凭据仍仅由 Keychain 持久化。

## 验证

`Scripts/check-core.sh` 已通过：覆盖完整 header、认证字段白名单、变化的 requestId、HTTP 客户端标识，以及 `-460` 只请求一次、不误判歌曲不可用。实际账号与原网络下的播放恢复仍需安装新构建后验收。

若新构建仍返回 `-460`：停止连续尝试，稍后重试；用官方网易云客户端检查同账号同网络是否正常，必要时完成官方验证，再比较 Wi-Fi / 蜂窝网络结果。切换网络只用于定位影响范围，不应反复请求探测风控。
