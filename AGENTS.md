# Current 开发约定

- iPhone / CarPlay，SwiftUI、AVFoundation、系统框架优先。
- 参考 Kumone 的分层和原生质感；不引入其 macOS AutoMix、MLX、Sparkle。
- 模拟功能在界面标明。不要把随机队列称为智能推荐。
- 登录凭据只进 Keychain；日志和反馈不保存 cookie。
- 歌曲属性、用户偏好、当前听歌意图分开建模。
- 反馈保留原因和场景，不把跳过自动当成讨厌。
- Git 操作使用 GitButler；独立分支 `liupenghao03/<description>`。未经要求不 push、不建 PR。
- 不使用 qa-bug-loop、qa-bug-regression-e2e、qa-e2e-improver、qa-flick-e2e-runner、qa-kpp-e2e-dispatch、qa-ktest-runner、qa-ui-e2e。
- 文档简洁、易读、逻辑清晰。

- 爱心与负向反馈仅服务 Current 推荐偏好，永不同步网易云收藏；接入推荐系统后作为排序权重信号。
