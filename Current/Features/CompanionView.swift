import SwiftUI

struct CompanionView: View {
    @EnvironmentObject private var pool: SongPoolStore
    @EnvironmentObject private var companion: CompanionClient
    @State private var selected = Set<UUID>()
    @State private var force = false
    @State private var showUnpair = false
    private var tasks: [CompanionJobStatus] { companion.activeStatuses }
    private var candidates: [PoolSong] {
        let submitted = Set(tasks.map(\.id))
        return pool.songs.filter { !$0.track.isDemo && $0.state != .unavailable && !submitted.contains($0.id) && (force || !pool.companionReady($0)) }
    }
    private var selectableIDs: Set<UUID> { Set(candidates.prefix(1000).map(\.id)) }
    private var failedCount: Int { tasks.filter { $0.state == .failed }.count }
    private var canPause: Bool { tasks.contains { $0.state == .queued || $0.state == .fetching || $0.state == .analyzing } }
    private var statusSummary: String {
        let running = tasks.filter { $0.state == .fetching || $0.state == .analyzing }.count
        let waiting = tasks.filter { $0.state == .queued || $0.state == .authorizationRequired }.count
        let syncing = tasks.filter { $0.state == .completed }.count
        let missing = tasks.filter { $0.state == .unavailable }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) 首处理中") }
        if waiting > 0 { parts.append("\(waiting) 首排队") }
        if syncing > 0 { parts.append("\(syncing) 首待同步") }
        if missing > 0 { parts.append("\(missing) 首不可用") }
        return parts.joined(separator: " · ")
    }
    private var emptyCandidates: String {
        if tasks.isEmpty { return "没有待分析的歌曲。" }
        if tasks.contains(where: { $0.state == .queued || $0.state == .fetching || $0.state == .analyzing }) {
            return "其余歌曲正在处理，完成后会自动同步。"
        }
        if tasks.contains(where: { $0.state == .completed }) { return "其余歌曲已完成，正在等待同步。" }
        if tasks.contains(where: { $0.state == .authorizationRequired }) { return "其余歌曲等待更新网易云授权。" }
        return "其余歌曲分析失败或音源不可用，可到分析管理处理。"
    }
    var body: some View {
        CurrentPage {
            connectionHeader
            if !tasks.isEmpty { taskSection }
            if companion.connected { selectionSection }
        }
        .navigationTitle("Mac 分析").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if companion.paired {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if companion.connected {
                            Toggle("重新分析已有结果", isOn: $force).debugHitArea()
                            Button("更新网易云授权") { companion.updateAuthorization() }
                            Button(companion.syncPaused ? "继续同步" : "暂停结果同步") { companion.setSyncPaused(!companion.syncPaused) }
                            Divider()
                        }
                        Button("解除配对", role: .destructive) { showUnpair = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("更多操作")
                }
            }
        }
        .onChange(of: force) { _, _ in selected = [] }
        .onChange(of: candidates.map(\.id)) { _, ids in selected.formIntersection(Set(ids)) }
        .onAppear { companion.setDiscoveryVisible(true) }
        .onDisappear { companion.setDiscoveryVisible(false) }
        .sheet(isPresented: Binding(get: { companion.pairingStage != nil }, set: { if !$0 { companion.cancelPairing() } })) {
            CompanionPairingSheet(companion: companion)
        }
        .confirmationDialog("解除配对？", isPresented: $showUnpair) {
            Button("解除配对", role: .destructive) { companion.unpair() }
        } message: { Text("离线时请同时在 Mac 解除配对，才能立即清除电脑上的授权。") }
    }
    private var connectionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(companion.paired ? companion.name : "Mac 分析", systemImage: "desktopcomputer")
                    .font(CurrentTheme.TypeScale.section)
                if companion.paired {
                    Text(companion.connected ? "已连接" : "未连接")
                        .font(CurrentTheme.TypeScale.secondary.weight(.semibold))
                        .foregroundStyle(companion.connected ? .green : CurrentTheme.muted)
                }
                Spacer()
            }
            if !companion.paired {
                Text("在附近的 Mac 打开分析伴侣并开启 Wi-Fi。手机离线后，已下发任务仍会继续。")
                    .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            }
            if companion.connected {
                if !companion.authorized {
                    Button("更新网易云授权") { companion.updateAuthorization() }.buttonStyle(.bordered).debugHitArea()
                }
                if companion.syncPaused {
                    Button("继续同步 / 重试") { companion.setSyncPaused(false) }.buttonStyle(.bordered).debugHitArea()
                }
            } else {
                Button(companion.discovering ? "正在寻找电脑…" : "寻找附近的 Mac") { companion.discover() }
                    .buttonStyle(.bordered).debugHitArea().disabled(companion.discovering || companion.connecting)
                if !companion.paired {
                    ForEach(companion.computers) { computer in
                        Button { companion.requestPairing(with: computer) } label: {
                            HStack {
                                Label(computer.name, systemImage: "desktopcomputer")
                                Spacer(); Text("请求配对").font(CurrentTheme.TypeScale.secondary)
                            }.frame(minHeight: 44)
                        }.buttonStyle(DebugHitAreaStyle(base: CurrentRowStyle())).disabled(companion.connecting)
                    }
                } else {
                    if let computer = companion.discoveredPairedComputer {
                        Label(computer.name, systemImage: "desktopcomputer")
                            .font(CurrentTheme.TypeScale.emphasis)
                    }
                    Text(companion.connecting ? "正在连接…" : "恢复后会自动补同步。")
                        .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                }
            }
            if let error = companion.error { Text(error).font(CurrentTheme.TypeScale.secondary).foregroundStyle(.orange) }
        }
    }
    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mac 分析任务 · \(tasks.count)").font(CurrentTheme.TypeScale.section)
                Spacer()
                if canPause {
                    Button(companion.analysisPaused ? "继续分析" : "暂停分析") { companion.setAnalysisPaused(!companion.analysisPaused) }
                        .disabled(!companion.connected)
                }
            }
            if failedCount > 0 {
                Button("重试 \(failedCount) 首失败歌曲") { companion.retryFailed() }
                    .buttonStyle(.bordered).debugHitArea().disabled(!companion.connected || !companion.authorized)
            }
            if !statusSummary.isEmpty {
                Text(statusSummary)
                    .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            }
            DisclosureGroup("任务列表") {
                LazyVStack(spacing: 0) {
                ForEach(tasks) { job in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.track.title).font(CurrentTheme.TypeScale.emphasis).foregroundStyle(job.state == .unavailable ? CurrentTheme.muted : .primary).lineLimit(1)
                            if let failure = job.failure { Text(failure).font(CurrentTheme.TypeScale.caption).foregroundStyle(job.state == .unavailable ? CurrentTheme.muted : .orange) }
                        }
                        Spacer()
                        Text(job.state.title).font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                    }.opacity(job.state == .unavailable ? 0.6 : 1).padding(.vertical, 8)
                }
                }
            }
        }
    }
    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(force ? "选择重新分析的歌曲" : "选择歌曲").font(CurrentTheme.TypeScale.section)
                Spacer()
                if !candidates.isEmpty {
                    Button(selected == selectableIDs ? "取消全选" : (candidates.count > 1000 ? "选择前 1000 首" : "全选")) {
                        selected = selected == selectableIDs ? [] : selectableIDs
                    }
                }
            }
            if candidates.isEmpty {
                Text(emptyCandidates)
                    .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            } else {
                PrimaryButton(title: "交给 Mac 分析 · \(selected.count) 首", symbol: "desktopcomputer") {
                    companion.submit(selected, force: force)
                    if companion.error == nil { selected = [] }
                }.disabled(selected.isEmpty || !companion.authorized)
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { song in
                        Button {
                            if selected.contains(song.id) { selected.remove(song.id) } else { selected.insert(song.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Artwork(track: song.track).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.track.title).font(CurrentTheme.TypeScale.emphasis).lineLimit(1)
                                    Text(song.track.artist).font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: selected.contains(song.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(song.id) ? CurrentTheme.accent : .secondary)
                            }.foregroundStyle(.primary).padding(.vertical, 10).contentShape(Rectangle())
                        }.buttonStyle(DebugHitAreaStyle(base: CurrentRowStyle())).disabled(selected.count >= 1000 && !selected.contains(song.id))
                    }
                }
            }
        }
    }
}

private struct CompanionPairingSheet: View {
    @ObservedObject var companion: CompanionClient
    @State private var code = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Label(companion.pairingComputerName, systemImage: "desktopcomputer")
                    .font(CurrentTheme.TypeScale.section)
                if companion.pairingStage == .waiting {
                    ProgressView("等待 Mac 接受配对请求…")
                    Text("请在 Mac 的弹窗中点击“接受配对”。")
                        .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                } else {
                    Text("输入 Mac 弹窗中显示的 4 位数字")
                        .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                    TextField("4 位配对码", text: $code).debugHitArea()
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .font(.system(.largeTitle, design: .monospaced))
                        .padding(16).background(CurrentTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .onChange(of: code) { _, value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4)) }
                        .disabled(companion.pairingStage == .verifying)
                    PrimaryButton(title: companion.pairingStage == .verifying ? "正在验证…" : "验证并连接", symbol: "link") {
                        companion.verifyPairing(code: code)
                    }.disabled(code.count != 4 || companion.pairingStage == .verifying)
                }
                if let error = companion.error { Text(error).font(CurrentTheme.TypeScale.secondary).foregroundStyle(.orange) }
                Spacer()
            }.padding(24)
                .navigationTitle("配对 Mac").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { companion.cancelPairing() } } }
        }.presentationDetents([.medium, .large])
    }
}
