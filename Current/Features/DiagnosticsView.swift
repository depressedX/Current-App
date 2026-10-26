import SwiftUI

struct DiagnosticsView: View {
    @State private var entries: [LogEntry] = []
    @State private var category: LogCategory?
    @State private var exportURL: URL?
    @State private var busy = false
    @State private var failure: String?
    @State private var confirmClear = false
    private var filtered: [LogEntry] { entries.filter { category == nil || $0.category == category } }
    var body: some View {
        CurrentPage {
            Text("日志保存在本机，最多约 2 MB。不记录登录凭据、歌曲名、听歌需求或完整网络地址。")
                .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            HStack(spacing: 20) {
                Button("刷新") { Task { await reload() } }
                Button("准备导出") { Task { await export() } }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("分享日志", systemImage: "square.and.arrow.up") }
                }
                Spacer(minLength: 0)
            }.font(CurrentTheme.TypeScale.body).disabled(busy)
            if busy { ProgressView() }
            Picker("日志类别", selection: $category) {
                Text("全部").tag(Optional<LogCategory>.none)
                ForEach(LogCategory.allCases, id: \.self) { item in
                    Text(item.title).tag(Optional(item))
                }
            }.pickerStyle(.menu)
            if filtered.isEmpty && !busy {
                Text("暂无日志").font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(filtered) { entry in
                    NavigationLink {
                        ScrollView {
                            Text(detail(entry)).font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24)
                        }.navigationTitle("事件详情").navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.category.title).font(CurrentTheme.TypeScale.emphasis)
                                Spacer()
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard)).monospacedDigit()
                                    .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                            }
                            Text("\(entry.operation.rawValue) · \(entry.event.rawValue)")
                                .font(CurrentTheme.TypeScale.secondary)
                            if let error = entry.error {
                                Text("\(error.domain) \(error.code)").font(CurrentTheme.TypeScale.caption).foregroundStyle(.red)
                            }
                        }.foregroundStyle(.primary).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(CurrentRowStyle())
                }
            }
            Text("显示最近 200 条；导出包含全部保留日志及 App、系统和设备型号信息。分享前可先查看内容。")
                .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
            Button("清除诊断日志", role: .destructive) { confirmClear = true }.disabled(busy)
        }
        .navigationTitle("诊断日志").navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog("清除本机日志及已生成的导出文件？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { Task { await clear() } }
        }
        .alert("日志操作失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
    @MainActor private func reload() async {
        busy = true; defer { busy = false }
        do { entries = try await AppLog.shared.entries() }
        catch { failure = "无法读取本机日志，请检查可用空间。" }
    }
    @MainActor private func export() async {
        busy = true; exportURL = nil; defer { busy = false }
        do { exportURL = try await AppLog.shared.export() }
        catch { failure = "无法生成导出文件，请检查可用空间。" }
    }
    @MainActor private func clear() async {
        busy = true; defer { busy = false }
        do {
            try await AppLog.shared.clear(); exportURL = nil
            entries = try await AppLog.shared.entries()
        } catch { failure = "日志清除失败，请稍后重试。" }
    }
    private func detail(_ entry: LogEntry) -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entry) else { return "无法显示事件" }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension LogCategory {
    var title: String {
        switch self {
        case .app: return "应用"
        case .auth: return "登录"
        case .api: return "接口"
        case .playback: return "播放"
        case .analysis: return "歌曲分析"
        case .storage: return "本机存储"
        case .companion: return "Mac 连接与配对"
        }
    }
}
