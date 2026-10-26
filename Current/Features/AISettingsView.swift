import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var keyInput = ""
    @State private var status: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section("OpenRouter") {
                LabeledContent("默认模型", value: OpenRouterIntentResolver.model)
                Text("免费路由会选择可用的免费模型，每次实际使用的模型可能不同。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                SecureField(store.openRouterConfigured ? "输入新的个人 Key 以替换" : "填写个人 OpenRouter Key", text: $keyInput)
                    .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(testing).accessibilityIdentifier("openRouterKeyInput")
                Text(store.openRouterConfigured ? "已保存个人 Key" : "尚未配置个人 Key")
                    .foregroundStyle(.secondary).accessibilityIdentifier("openRouterKeyStatus")
                Button("保存 Key") {
                    do { try store.saveOpenRouterKey(keyInput); keyInput = ""; status = "已保存至本机 Keychain。" }
                    catch { status = error.localizedDescription }
                }.disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                    .accessibilityIdentifier("saveOpenRouterKey")
                Button(testing ? "正在测试…" : "测试连接") {
                    testing = true; status = nil
                    testTask = Task { @MainActor in
                        defer { testing = false }
                        do {
                            _ = try await OpenRouterIntentResolver(diagnostics: OpenRouterDiagnostic.record).resolve(text: "轻柔、放松一点", concepts: store.pool.intentConcepts)
                            try Task.checkCancellation()
                            status = "连接成功，已验证推荐条件解析。"
                        } catch is CancellationError {} catch { status = error.localizedDescription }
                    }
                }.disabled(!store.openRouterConfigured || testing || !keyInput.isEmpty)
                    .accessibilityIdentifier("testOpenRouterConnection")
                if store.openRouterConfigured {
                    Button("清除个人 Key", role: .destructive) {
                        do { try store.clearOpenRouterKey(); keyInput = ""; status = "已从本机移除个人 Key。" }
                        catch { status = error.localizedDescription }
                    }.disabled(testing).accessibilityIdentifier("clearOpenRouterKey")
                }
            } header: { Text("个人 API Key") } footer: {
                Text("Key 只保存在本机 Keychain，不写入日志。生成时会把这次听歌需求和听感词表发送至 OpenRouter 及其模型供应商；不发送音频、网易云凭据或完整歌单。")
            }
            if let status { Section { Text(status).font(.callout).accessibilityIdentifier("openRouterConnectionStatus") } }
            Section { Link("获取 OpenRouter Key", destination: URL(string: "https://openrouter.ai/settings/keys")!) }
        }
        .navigationTitle("AI 设置").navigationBarTitleDisplayMode(.inline)
        .onDisappear { testTask?.cancel(); keyInput = "" }
    }
}
