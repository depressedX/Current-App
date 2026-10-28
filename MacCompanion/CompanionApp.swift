import SwiftUI
import AppKit

@main
struct CurrentCompanionApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @StateObject private var worker = CompanionWorker()
    var body: some Scene {
        Window("Current · 分析伴侣", id: "main") {
            CompanionDashboard(worker: worker).frame(minWidth: 760, minHeight: 520)
                .onAppear { appDelegate.worker = worker }
                .onDisappear { worker.shutdown() }
        }.defaultSize(width: 1000, height: 700)
    }
}
@MainActor
private final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    weak var worker: CompanionWorker?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { worker?.shutdown() }
}

private enum CompanionStyle {
    static let accent = Color(red: 0.925, green: 0.286, blue: 0.286)
    static let surface = Color(nsColor: .controlBackgroundColor)
}
struct CompanionDashboard: View {
    @ObservedObject var worker: CompanionWorker
    @State private var section = 0
    @State private var showUnpair = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(CompanionStyle.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current").font(.headline)
                        Text("分析伴侣").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 12).padding(.top, 18)
                List(selection: $section) {
                    Label("分析任务", systemImage: "waveform.path").tag(0)
                    Label("连接与授权", systemImage: "iphone.and.arrow.forward").tag(1)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label(worker.connected ? "手机已连接" : "等待手机连接", systemImage: worker.connected ? "circle.fill" : "circle")
                        .font(.caption).foregroundStyle(worker.connected ? .green : .secondary)
                    Text("关闭窗口即停止分析并退出")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }.navigationSplitViewColumnWidth(210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if section == 0 { tasks } else { connection }
                    if let error = worker.error {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    }
                }.padding(32).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(CompanionStyle.accent)
        .onChange(of: worker.pairingRequest?.id) { _, request in
            if request != nil { NSApp.activate(ignoringOtherApps: true) }
        }
        .sheet(isPresented: Binding(get: { worker.pairingRequest != nil }, set: { if !$0 { worker.cancelPairingRequest() } })) {
            CompanionPairingPrompt(worker: worker)
        }
        .confirmationDialog("解除配对并清除授权？", isPresented: $showUnpair) {
            Button("解除配对", role: .destructive) { worker.unpair() }
        } message: { Text("未完成的任务将取消，手机需要重新配对。") }
    }
    private var tasks: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("让电脑分析，安心听歌").font(.title2.weight(.semibold))
                    Text("同时分析最多 \(worker.concurrentAnalyses) 首歌曲，完成后自动同步结果。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(worker.analysisPaused ? "继续分析" : "暂停分析") { worker.setAnalysisPaused(!worker.analysisPaused) }
                    .buttonStyle(.borderedProminent).controlSize(.large).clipShape(Capsule())
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("同时分析", selection: Binding(get: { worker.concurrentAnalyses }, set: { worker.setConcurrency($0) })) {
                        ForEach(CompanionWorker.concurrencyRange, id: \.self) { count in Text("\(count) 首").tag(count) }
                    }.pickerStyle(.menu).frame(width: 180)
                    Spacer()
                    Text("进行中 \(worker.runningCount) 首").font(.callout).foregroundStyle(.secondary)
                }
                Text("默认 4 首。并行越多，内存占用越高；调低后，正在分析的歌曲会继续完成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                metric("待处理", count: worker.pendingCount)
                metric("等待同步", count: worker.jobs.filter { $0.state == .completed }.count)
                metric("进行中", count: worker.runningCount)
                metric("不可用", count: worker.unavailableCount)
            }
            HStack {
                Text("分析记录").font(.headline)
                Spacer()
                Button(worker.syncPaused ? "恢复同步" : "暂停同步") { worker.setSyncPaused(!worker.syncPaused) }
                if worker.jobs.contains(where: { $0.state == .failed }) {
                    Button("重试失败项") { worker.retryFailed() }
                }
            }.buttonStyle(.bordered)
            if worker.unavailableCount > 0 {
                Text("不可用歌曲已灰显，不计入待处理，不参与失败重试、歌单生成与播放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if worker.activeJobs.isEmpty {
                ContentUnavailableView("暂无待处理任务", systemImage: "music.note.list",
                    description: Text("完成的结果会保存在手机歌曲池，已同步任务自动移出队列。"))
                    .frame(maxWidth: .infinity, minHeight: 240)
                if worker.pairedDevice == nil { pairingCard }
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(worker.activeJobs) { job in
                        HStack(spacing: 14) {
                            Image(systemName: "music.note").foregroundStyle(CompanionStyle.accent)
                                .frame(width: 44, height: 44).background(CompanionStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.track.title).font(.body.weight(.medium)).foregroundStyle(job.state == .unavailable ? .secondary : .primary).lineLimit(1)
                                Text(job.failure ?? job.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 12)
                            if job.state == .fetching || job.state == .analyzing { ProgressView().controlSize(.small) }
                            Text(job.state.title).font(.caption).foregroundStyle(job.state == .failed ? .orange : .secondary)
                            if job.state != .synced {
                                Button { worker.cancel([job.id]) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("取消此任务")
                            }
                        }.opacity(job.state == .unavailable ? 0.55 : 1).padding(14).background(CompanionStyle.surface)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    private func metric(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(CompanionStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("连接与授权").font(.title2.weight(.semibold))
            if worker.pairedDevice == nil { pairingCard }
            else {
                Label(worker.connected ? "手机已连接" : "手机已配对 · 当前离线", systemImage: "iphone")
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(CompanionStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                Text(worker.account == nil ? "在手机点击“更新授权”，复用网易云登录状态。" : "网易云授权由手机提供，凭据仅存放在本机钥匙串。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("解除配对并清除授权", role: .destructive) { showUnpair = true }
            }
            if !worker.ready { Button("重试启动局域网服务") { worker.start() } }
        }
    }
    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("连接你的 iPhone", systemImage: "iphone.and.arrow.forward").font(.headline)
            if let request = worker.pairingRequest {
                Text(request.approved ? "在 \(request.name) 上输入下面的数字。" : "\(request.name) 请求与你配对。")
                    .font(.callout).foregroundStyle(.secondary)
                if request.approved {
                    Text(worker.pairingCode).font(.system(size: 40, weight: .semibold, design: .monospaced)).tracking(10)
                }
                Button("取消配对") { worker.cancelPairingRequest() }.buttonStyle(.bordered)
            } else {
                Text("保持两台设备在附近并开启 Wi-Fi，在手机找到这台 Mac，点击“请求配对”，然后在 Mac 弹窗中接受。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(CompanionStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct CompanionPairingPrompt: View {
    @ObservedObject var worker: CompanionWorker
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let request = worker.pairingRequest {
                Label(request.approved ? "在手机输入配对码" : "允许这台 iPhone 配对？", systemImage: "iphone.and.arrow.forward")
                    .font(.title3.weight(.semibold))
                Text(request.name).font(.headline)
                if request.approved {
                    Text(worker.pairingCode).font(.system(size: 44, weight: .semibold, design: .monospaced)).tracking(10)
                    Text("5 分钟内有效。验证成功后，两台设备会自动记住彼此。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("取消配对", role: .cancel) { worker.cancelPairingRequest() }.buttonStyle(.bordered)
                } else {
                    Text("接受后会显示 4 位数字，请在发起请求的手机上输入。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("拒绝", role: .cancel) { worker.cancelPairingRequest() }.buttonStyle(.bordered)
                        Spacer()
                        Button("接受配对") { worker.approvePairingRequest() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }.padding(28).frame(width: 420, alignment: .leading).tint(CompanionStyle.accent)
    }
}
