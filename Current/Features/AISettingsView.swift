import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var keyInput = ""
    @State private var status: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section("DeepSeek") {
                LabeledContent("默认模型", value: DeepSeekIntentResolver.model)
                Text("使用 DeepSeek 官方 API 解析听歌需求，API 调用按 DeepSeek 账户计费。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                SecureField(store.deepSeekConfigured ? "输入新的个人 Key 以替换" : "填写个人 DeepSeek Key", text: $keyInput)
                    .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(testing).accessibilityIdentifier("deepSeekKeyInput")
                Text(store.deepSeekConfigured ? "已保存个人 Key" : "尚未配置个人 Key")
                    .foregroundStyle(.secondary).accessibilityIdentifier("deepSeekKeyStatus")
                Button("保存 Key") {
                    do { try store.saveDeepSeekKey(keyInput); keyInput = ""; status = "已保存至本机 Keychain。" }
                    catch { status = error.localizedDescription }
                }.disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                    .accessibilityIdentifier("saveDeepSeekKey")
                Button(testing ? "正在测试…" : "测试连接") {
                    testing = true; status = nil
                    testTask = Task { @MainActor in
                        defer { testing = false }
                        do {
                            _ = try await DeepSeekIntentResolver(diagnostics: IntentAPIDiagnostic.record).resolve(text: "轻柔、放松一点", concepts: store.pool.intentConcepts)
                            try Task.checkCancellation()
                            status = "连接成功，已验证推荐条件解析。"
                        } catch is CancellationError {} catch { status = error.localizedDescription }
                    }
                }.disabled(!store.deepSeekConfigured || testing || !keyInput.isEmpty)
                    .accessibilityIdentifier("testDeepSeekConnection")
                if store.deepSeekConfigured {
                    Button("清除个人 Key", role: .destructive) {
                        do { try store.clearDeepSeekKey(); keyInput = ""; status = "已从本机移除个人 Key。" }
                        catch { status = error.localizedDescription }
                    }.disabled(testing).accessibilityIdentifier("clearDeepSeekKey")
                }
            } header: { Text("个人 API Key") } footer: {
                Text("Key 只保存在本机 Keychain，不写入日志。生成时会把听歌需求、听感词表，以及分别标明来源的音频曲风与百科曲风词表发送至 DeepSeek；不发送音频、网易云凭据或完整歌单。")
            }
            if let status { Section { Text(status).font(.callout).accessibilityIdentifier("deepSeekConnectionStatus") } }
            Section { Link("获取 DeepSeek Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!) }
        }
        .navigationTitle("AI 设置").navigationBarTitleDisplayMode(.inline)
        .onDisappear { testTask?.cancel(); keyInput = "" }
    }
}
