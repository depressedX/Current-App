import SwiftUI

struct SongPoolView: View {
    @EnvironmentObject private var pool: SongPoolStore
    @State private var showImport = false
    @State private var selection = 0
    private var visible: [PoolSong] {
        pool.songs.filter { selection == 0 ? $0.state != .completed : $0.state == .completed }
    }
    var body: some View {
        CurrentPage {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(pool.completedCount) 首已分析").font(CurrentTheme.TypeScale.section)
                    Text("\(pool.pendingCount) 首待处理").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                }
                Spacer()
                if pool.pendingCount > 0 {
                    Button(pool.paused ? "继续分析" : "暂停") { pool.paused ? pool.resume() : pool.pause() }
                        .font(CurrentTheme.TypeScale.emphasis).frame(minHeight: 44)
                        .disabled(pool.loading || pool.failure != nil)
                        .accessibilityIdentifier("poolToggle")
                }
            }
            if pool.songs.contains(where: { $0.state == .completed && !$0.semanticReady }) {
                Button("补全听感分析") { pool.analyzeHearing(); selection = 0 }
                    .font(CurrentTheme.TypeScale.secondary).frame(minHeight: 44)
            }
            if pool.songs.contains(where: { $0.state == .failed }) {
                Button("重试失败项") { pool.retryFailed() }
                    .font(CurrentTheme.TypeScale.secondary).frame(minHeight: 44)
                    .accessibilityIdentifier("retryFailedAnalysis")
            }
            if let reason = pool.waitReason, pool.pendingCount > 0 {
                Text(reason).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            }
            if let failure = pool.failure { Text(failure).font(CurrentTheme.TypeScale.secondary).foregroundStyle(.red) }
            Picker("歌曲状态", selection: $selection) {
                Text("待处理").tag(0)
                Text("已分析").tag(1)
            }.pickerStyle(.segmented)
            if visible.isEmpty {
                ContentUnavailableView(selection == 0 ? "没有待处理的歌曲" : "还没有分析结果",
                                       systemImage: "waveform",
                                       description: Text(selection == 0 ? "从歌单加入歌曲，再开始分析。" : "分析完成后，在这里查看维度。"))
            }
            LazyVStack(spacing: CurrentTheme.Space.small) {
                ForEach(visible) { song in
                    NavigationLink { PoolSongDetail(id: song.id) } label: {
                        HStack(spacing: CurrentTheme.Space.row) {
                            Artwork(track: song.track).frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.track.title).font(CurrentTheme.TypeScale.emphasis).foregroundStyle(.primary).lineLimit(1)
                                Text(subtitle(song)).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            if song.state.active { ProgressView() }
                            else { Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure).foregroundStyle(CurrentTheme.muted) }
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(CurrentRowStyle())
                }
            }
            Text("每次分析一首。听感由 DCLAP 本地计算，播放时自动暂停。")
                .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
        }
        .navigationTitle("歌曲池").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImport = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("加入歌曲").disabled(pool.loading || pool.failure != nil)
            }
        }
        .sheet(isPresented: $showImport) { NavigationStack { PoolImportView() } }
    }
    private func subtitle(_ song: PoolSong) -> String {
        if song.features != nil, song.state == .completed {
            if let bpm = song.resolvedBPM {
                return "\(song.bpmSource == .localAnalysis ? "约 " : "")\(Int(bpm.rounded())) BPM · \(song.semanticReady ? "听感已分析" : "听感待分析")"
            }
            return song.semanticReady ? "听感已分析 · BPM 未知" : "BPM 未知 · 听感待分析"
        }
        return song.state == .failed ? (song.failure ?? "分析失败") : song.state.title
    }
}

private struct PoolImportView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var pool: SongPoolStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        CurrentPage {
            Text("选择歌单，可整单加入，也可挑选单曲。")
                .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            if store.listener != nil {
                if store.libraryLoading { ProgressView("读取歌单") }
                if store.playlists.isEmpty && !store.libraryLoading {
                    Text("暂无歌单").foregroundStyle(CurrentTheme.muted)
                }
                ForEach(store.playlists) { playlist in
                    NavigationLink { PoolPlaylistView(playlist: playlist) } label: {
                        HStack(spacing: CurrentTheme.Space.row) {
                            PlaylistArtwork(url: playlist.artwork).frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.title).font(CurrentTheme.TypeScale.emphasis).foregroundStyle(.primary)
                                Text("\(playlist.count) 首").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure)
                        }.padding(.vertical, 8)
                    }
                }
            } else if store.demoMode {
                NavigationLink("原创演示曲库") { PoolPlaylistView(playlist: nil) }
            } else { Text("先连接网易云或进入演示空间").foregroundStyle(CurrentTheme.muted) }
        }
        .navigationTitle("从歌单加入").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        .task { if store.listener != nil { await store.loadPlaylists() } }
    }
}

private struct PoolPlaylistView: View {
    let playlist: UserPlaylist?
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var pool: SongPoolStore
    @State private var tracks: [Track] = []
    @State private var busy = true
    @State private var failure: String?
    @State private var notice: String?
    @State private var loadedAccount: String?
    var body: some View {
        let added = Set(pool.songs.map { $0.track.id })
        CurrentPage {
            if busy { ProgressView("读取完整歌单…") }
            if let failure {
                Text(failure).font(CurrentTheme.TypeScale.secondary).foregroundStyle(.red)
                Button("重试") { Task { await load() } }
            }
            if !tracks.isEmpty {
                HStack {
                    Text("\(tracks.count) 首").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                    Spacer()
                    Button("全部加入") { add(tracks) }.font(CurrentTheme.TypeScale.emphasis)
                        .disabled(loadedAccount != pool.account || tracks.allSatisfy { added.contains($0.id) })
                }
                if let notice { Text(notice).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted) }
                LazyVStack(spacing: 8) {
                    ForEach(tracks) { track in
                        HStack(spacing: 12) {
                            Artwork(track: track).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).font(CurrentTheme.TypeScale.emphasis).lineLimit(1)
                                Text(track.artist).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted).lineLimit(1)
                            }
                            Spacer()
                            Button { add([track]) } label: {
                                Image(systemName: added.contains(track.id) ? "checkmark" : "plus").frame(width: 44, height: 44)
                            }.disabled(added.contains(track.id) || loadedAccount != pool.account)
                                .accessibilityLabel(added.contains(track.id) ? "已在歌曲池" : "加入\(track.title)")
                        }
                    }
                }
            } else if !busy && failure == nil { Text("歌单中暂无可读取的歌曲").foregroundStyle(CurrentTheme.muted) }
        }
        .navigationTitle(playlist?.title ?? "原创演示曲库").navigationBarTitleDisplayMode(.inline)
        .task(id: pool.account) { await load() }
    }
    private func load() async {
        let account = pool.account
        busy = true; failure = nil; tracks = []; notice = nil; loadedAccount = nil
        defer { if account == pool.account { busy = false } }
        do {
            let result: [Track]
            if let playlist {
                guard store.listener != nil else { return }
                result = try await store.api.tracks(playlistID: playlist.id, limit: nil)
            } else { result = DemoCatalog.tracks }
            try Task.checkCancellation()
            guard account == pool.account else { return }
            var seen = Set<Int>()
            tracks = result.filter { seen.insert($0.id).inserted }; loadedAccount = account
            if let playlist, tracks.count < playlist.count { notice = "部分歌曲暂不可读取，已显示 \(tracks.count) 首。" }
        } catch is CancellationError {} catch {
            guard account == pool.account else { return }
            failure = "读取失败，请检查网络和登录状态"
        }
    }
    private func add(_ selected: [Track]) {
        guard loadedAccount == pool.account else { return }
        let count = pool.enqueue(selected, source: playlist?.title ?? "原创演示曲库")
        notice = count > 0 ? "已加入 \(count) 首，在歌曲池继续分析。" : "歌曲已在池中"
    }
}

private struct PoolSongDetail: View {
    let id: UUID
    @EnvironmentObject private var pool: SongPoolStore
    @Environment(\.dismiss) private var dismiss
    private var song: PoolSong? { pool.songs.first { $0.id == id } }
    var body: some View {
        CurrentPage {
            if let song {
                HStack(spacing: 16) {
                    Artwork(track: song.track).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.track.title).font(CurrentTheme.TypeScale.section)
                        Text(song.track.artist).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                    }
                }
                Text(song.state.title).font(CurrentTheme.TypeScale.emphasis)
                if let failure = song.failure, song.state == .failed {
                    Text(failure).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                    Button("重试") { pool.retry(id) }
                }
                if song.needsReanalysis == true && song.features != nil {
                    Text(song.state == .failed ? "重新分析失败，以下保留上次结果。" : "正在重新分析，以下为上次结果。")
                        .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                }
                if song.state == .completed || song.state == .failed {
                    Button("重新分析") { pool.reanalyze(id) }
                        .accessibilityIdentifier("reanalyzeSong")
                    Text("重新获取 BPM 与音频，成功后更新结果。")
                        .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                }
                GroupBox("节奏") {
                    VStack(spacing: 12) {
                        dimension("BPM", song.resolvedBPM.map { String(format: "%.1f", $0) } ?? "未知")
                        dimension("来源", song.bpmSource?.title ?? "暂无可靠结果")
                        if let wiki = song.wikiBPM {
                            dimension("百科获取时间", wiki.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        if !song.track.isDemo { dimension("网易云百科", song.bpmLookup?.title ?? "尚未获取") }
                        if let features = song.features {
                            dimension("本地估计", features.bpm.map { String(format: "%.1f", $0) } ?? "未知")
                        }
                    }.padding(.vertical, 8)
                }
                if song.canBackfillBPM {
                    Button("获取网易云 BPM") { pool.backfillBPM(id) }
                }
                if let features = song.features {
                    GroupBox("基础维度") {
                        VStack(spacing: 12) {
                            dimension("节奏周期强度", String(format: "%.2f", features.rhythmStrength))
                            dimension("平均电平", String(format: "%.1f dBFS", features.rmsDBFS))
                            dimension("峰值电平", String(format: "%.1f dBFS", features.peakDBFS))
                            dimension("电平变化 P90–P10", String(format: "%.1f dB", features.dynamicSpreadDB))
                            dimension("过零率", String(format: "%.0f 次/秒", features.zeroCrossingsPerSecond))
                        }.padding(.vertical, 8)
                    }
                    Text("本地 BPM 可能有半速／倍速误差，周期强度不等于置信度。电平与过零率不直接代表听感。")
                        .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                    GroupBox("分析来源") {
                        VStack(spacing: 12) {
                            dimension("引擎", features.version)
                            dimension("音频范围", String(format: "%.0f–%.0f 秒", features.sampleStart, features.sampleStart + features.sampleDuration))
                            dimension("计算耗时", String(format: "%.2f 秒", features.elapsedSeconds))
                        }.padding(.vertical, 8)
                    }
                }
                GroupBox("听感维度") {
                    VStack(spacing: 12) {
                        if let semantic = song.semantic {
                            ForEach(semantic.matches) { match in
                                dimension(match.label, String(format: "%.3f", match.similarity))
                            }
                            dimension("模型", "DCLAP · 512 维")
                            dimension("分析窗口", "\(semantic.windowStarts.count) × 10 秒")
                            dimension("起点（秒）", semantic.windowStarts.map { String(format: "%.0f", $0) }.joined(separator: " / "))
                            dimension("听感耗时", String(format: "%.2f 秒", semantic.elapsedSeconds))
                            if !semantic.compatible { Text("模型版本已更新，请重新分析").foregroundStyle(.red) }
                        } else { dimension("听感", "尚未分析，点击重新分析") }
                    }.padding(.vertical, 8)
                }
                Text("数值为概念相似度，不是概率；只代表所选音频片段。")
                    .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                Text("来自：\(song.sources.joined(separator: "、"))")
                    .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                Button("移出歌曲池", role: .destructive) { pool.remove(id); dismiss() }
            }
        }
        .navigationTitle("分析详情").navigationBarTitleDisplayMode(.inline)
    }
    private func dimension(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(CurrentTheme.muted)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }.font(CurrentTheme.TypeScale.secondary)
    }
}
