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
            NavigationLink { CompanionView() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer").foregroundStyle(CurrentTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("交给 Mac 分析").font(CurrentTheme.TypeScale.emphasis)
                        Text("手动提交 · 完成后自动同步").font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                    }
                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(CurrentTheme.muted)
                }.foregroundStyle(.primary).padding(16)
                    .background(CurrentTheme.surface, in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.card))
            }.buttonStyle(CurrentPressStyle())
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(pool.completedCount) 首已分析").font(CurrentTheme.TypeScale.section)
                        Text(queueSummary).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                    }
                    Spacer()
                    if pool.pendingCount > 0 {
                        Button(pool.localRunning ? "暂停本机分析" : "本机分析") { pool.localRunning ? pool.pause() : pool.resume() }
                            .buttonStyle(PoolActionStyle(prominent: true))
                            .disabled(pool.loading || pool.failure != nil)
                            .accessibilityIdentifier("poolToggle")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { queueActions }
                    VStack(alignment: .leading, spacing: 8) { queueActions }
                }
                if let reason = pool.waitReason, pool.pendingCount > 0 {
                    Text(reason).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                }
                if let failure = pool.failure {
                    Text(failure).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink { LyricsSearchView() } label: {
                    HStack(spacing: 12) {
                        Text("歌词检索").font(CurrentTheme.TypeScale.emphasis).foregroundStyle(.primary)
                        Spacer()
                        Text("\(pool.lyricsCount) 首可检索").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                        Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure).foregroundStyle(CurrentTheme.muted)
                    }.frame(minHeight: 44)
                        .padding(.horizontal, 16).padding(.vertical, 4)
                        .background(CurrentTheme.surface, in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.card))
                        .contentShape(RoundedRectangle(cornerRadius: CurrentTheme.Radius.card))
                }.buttonStyle(CurrentPressStyle())
                if pool.songs.contains(where: { ($0.state == .completed || $0.state == .failed) && !$0.track.isDemo && ($0.lyrics?.compatible != true || $0.lyricsFailure == true) }) {
                    Button("本机补全歌词索引") { pool.indexMissingLyrics(); selection = 0 }
                        .buttonStyle(PoolActionStyle())
                }
            }
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
                                Text(subtitle(song)).font(CurrentTheme.TypeScale.secondary)
                                    .foregroundStyle(song.state == .failed ? CurrentTheme.accent : CurrentTheme.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if song.state.active { ProgressView() }
                            else { Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure).foregroundStyle(CurrentTheme.muted) }
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(CurrentRowStyle())
                }
            }
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
    private var queueSummary: String {
        let failed = pool.songs.filter { $0.state == .failed }.count
        return failed > 0 ? "\(pool.pendingCount) 首待处理 · \(failed) 首失败" : "\(pool.pendingCount) 首待处理"
    }
    @ViewBuilder private var queueActions: some View {
        if pool.songs.contains(where: { $0.state == .completed && ($0.features?.profile?.version != ObjectiveProfile.currentVersion || $0.genres?.compatible != true) }) {
            Button("本机更新分析") { pool.analyzeHearing(); selection = 0 }
                .buttonStyle(PoolActionStyle())
        }
        if pool.songs.contains(where: { $0.state == .failed }) {
            Button("重试失败项") { pool.retryFailed() }
                .buttonStyle(PoolActionStyle())
                .accessibilityIdentifier("retryFailedAnalysis")
        }
    }
    private func subtitle(_ song: PoolSong) -> String {
        if song.features != nil, song.state == .completed {
            if let bpm = song.resolvedBPM {
                return "\(song.bpmSource == .localAnalysis ? "约 " : "")\(Int(bpm.rounded())) BPM · \(song.features?.profile.map { $0.classifierAvailable && $0.classifiedWindows > 0 } == true ? "乐器已识别" : "待更新分析")"
            }
            return song.features?.profile.map { $0.classifierAvailable && $0.classifiedWindows > 0 } == true ? "乐器已识别 · BPM 未知" : "BPM 未知 · 待更新分析"
        }
        return song.remotePending == true ? "已交给 Mac · 等待同步" : (song.state == .failed ? "分析失败 · 可重试" : song.state.title)
    }
}

private struct PoolActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CurrentTheme.TypeScale.secondary.weight(.semibold))
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? CurrentTheme.accent : Color.primary.opacity(0.06), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .animation(CurrentTheme.Motion.press, value: configuration.isPressed)
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

struct PoolSongDetail: View {
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
                HStack {
                    HStack(spacing: 8) {
                        if song.state.active {
                            ProgressView().controlSize(.small)
                        } else {
                            Circle().fill(statusColor(song.state)).frame(width: 7, height: 7)
                        }
                        Text(song.state.title).font(CurrentTheme.TypeScale.secondary.weight(.semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(statusColor(song.state).opacity(0.10), in: Capsule())
                    .accessibilityElement(children: .combine)
                    Spacer()
                }
                if let failure = song.failure, song.state == .failed {
                    Text(failure).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)

                }
                if song.needsReanalysis == true && song.features != nil {
                    Text(song.state == .failed ? "重新分析失败，以下保留上次结果。" : "正在重新分析，以下为上次结果。")
                        .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                }
                if song.state == .completed || song.state == .failed {
                    PrimaryButton(title: "本机重新分析") { pool.reanalyze(id) }
                        .accessibilityIdentifier("reanalyzeSong")
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
                GroupBox("歌词") {
                    VStack(spacing: 12) {
                        if let lyrics = song.lyrics {
                            Text(lyrics.status == .indexed ? "已索引" : lyrics.status.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !lyrics.compatible { Text("索引需要更新").foregroundStyle(CurrentTheme.muted) }
                        } else { Text("尚未建立歌词索引").foregroundStyle(CurrentTheme.muted) }
                        if song.lyricsFailure == true {
                            Text(song.lyrics == nil ? "本次歌词分析失败，请重试" : "本次更新失败，保留上次歌词结果")
                                .foregroundStyle(CurrentTheme.muted)
                        }
                        if !song.track.isDemo && (song.state == .completed || song.state == .failed) {
                            detailAction("更新歌词索引") { pool.indexLyrics(id) }
                        }
                    }.font(CurrentTheme.TypeScale.secondary).padding(.vertical, 8)
                }
                GroupBox("网易云百科") {
                    VStack(spacing: 12) {
                        if let wiki = song.wikiMetadata {
                            ForEach(wiki.fields.indices, id: \.self) { index in
                                let field = wiki.fields[index]
                                dimension(field.title, field.values.joined(separator: "、"))
                            }
                            if wiki.fields.isEmpty { Text("暂无百科资料").foregroundStyle(CurrentTheme.muted) }
                            dimension("更新时间", wiki.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                        } else { Text("尚未录入百科资料").foregroundStyle(CurrentTheme.muted) }
                        if song.bpmLookup == .failed {
                            Text("本次获取失败，已保留上次资料").foregroundStyle(CurrentTheme.muted)
                        }
                        if !song.track.isDemo && song.state == .completed {
                            detailAction("更新网易云百科") { pool.refreshWiki(id) }
                        }
                    }.font(CurrentTheme.TypeScale.secondary).padding(.vertical, 8)
                }
                GroupBox("乐器识别") {
                    VStack(spacing: 12) {
                        if let profile = song.features?.profile {
                            if !profile.classifierAvailable || profile.classifiedWindows == 0 {
                                Text("本次未能完成识别，可重新分析")
                                    .foregroundStyle(CurrentTheme.muted)
                            } else if profile.soundLabels.isEmpty {
                                Text("暂未识别出明确乐器")
                                    .foregroundStyle(CurrentTheme.muted)
                            } else {
                                Text(profile.soundLabels.map(\.label).joined(separator: "、"))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            Text("重新分析后查看乐器")
                                .foregroundStyle(CurrentTheme.muted)
                        }
                    }.font(CurrentTheme.TypeScale.secondary).padding(.vertical, 8)
                }
                GroupBox("音乐风格") {
                    VStack(spacing: 12) {
                        if let genres = song.genres {
                            ForEach(genres.matches) { match in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(match.title).foregroundStyle(.primary)
                                        if match.familyTitle != match.title {
                                            Text(match.familyTitle).font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                                        }
                                    }
                                    Spacer()
                                    Text(String(format: "%.3f", match.score))
                                        .foregroundStyle(CurrentTheme.muted).monospacedDigit()
                                }.font(CurrentTheme.TypeScale.secondary)
                            }
                            if !genres.compatible {
                                Text("旧版结果，请重新分析").foregroundStyle(CurrentTheme.muted)
                            }
                        } else {
                            Text("重新分析后查看风格候选").foregroundStyle(CurrentTheme.muted)
                        }
                    }.font(CurrentTheme.TypeScale.secondary).padding(.vertical, 8)
                }
                GroupBox("待定维度") {
                    VStack(spacing: 12) {
                        dimension("人声", "待定")
                        dimension("听感平稳程度", "待定")
                    }.padding(.vertical, 8)
                }
                Text("来自：\(song.sources.joined(separator: "、"))")
                    .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                Button(role: .destructive) { pool.remove(id); dismiss() } label: {
                    Text("移出歌曲池")
                        .font(CurrentTheme.TypeScale.emphasis)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(CurrentTheme.accent)
                        .background(CurrentTheme.accent.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(CurrentTheme.accent.opacity(0.18)))
                }.buttonStyle(CurrentPressStyle())
            }
        }
        .navigationTitle("分析详情").navigationBarTitleDisplayMode(.inline)
    }
    private func statusColor(_ state: AnalysisState) -> Color {
        switch state {
        case .completed: return .green
        case .failed: return CurrentTheme.accent
        case .queued: return .secondary
        default: return CurrentTheme.accent
        }
    }
    private func detailAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CurrentTheme.TypeScale.emphasis)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(.primary)
                .background(.primary.opacity(0.06), in: Capsule())
        }.buttonStyle(CurrentPressStyle())
    }
    private func dimension(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(CurrentTheme.muted)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }.font(CurrentTheme.TypeScale.secondary)
    }
}
