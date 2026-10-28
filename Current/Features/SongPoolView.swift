import SwiftUI

struct SongPoolView: View {
    @EnvironmentObject private var pool: SongPoolStore
    @State private var showImport = false
    @State private var selection = 0
    private var pending: [PoolSong] {
        pool.songs.filter { $0.state != .completed && $0.state != .failed && $0.state != .unavailable }
    }
    private var failed: [PoolSong] { pool.songs.filter { $0.state == .failed } }
    private var unavailable: [PoolSong] { pool.songs.filter { $0.state == .unavailable } }
    private var visible: [PoolSong] {
        switch selection {
        case 1: return failed
        case 2: return unavailable
        default: return pending
        }
    }
    private var outdated: Bool {
        pool.songs.contains { $0.state == .completed && ($0.features?.profile?.version != ObjectiveProfile.currentVersion || $0.genres?.compatible != true) }
    }
    private var missingLyrics: Bool {
        pool.songs.contains { ($0.state == .completed || $0.state == .failed) && !$0.track.isDemo && ($0.lyrics?.compatible != true || $0.lyricsFailure == true) }
    }
    var body: some View {
        CurrentPage {
            NavigationLink { CompanionView() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer").foregroundStyle(CurrentTheme.accent)
                    Text("Mac 分析").font(CurrentTheme.TypeScale.emphasis)
                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(CurrentTheme.muted)
                }.foregroundStyle(.primary).padding(16)
                    .background(CurrentTheme.surface, in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.card))
            }.buttonStyle(CurrentPressStyle())
            actions
            Picker("歌曲状态", selection: $selection) {
                Text("待分析 \(pending.count)").tag(0)
                Text("失败 \(failed.count)").tag(1)
                Text("不可用 \(unavailable.count)").tag(2)
            }.pickerStyle(.segmented)
            if selection == 2 && !unavailable.isEmpty {
                Text("音源不可用的歌曲不参与歌单生成与播放。")
                    .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            }
            if visible.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(emptyDescription))
            }
            LazyVStack(spacing: CurrentTheme.Space.small) {
                ForEach(visible) { song in
                    NavigationLink { PoolSongDetail(id: song.id) } label: {
                        HStack(spacing: CurrentTheme.Space.row) {
                            Artwork(track: song.track).frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.track.title).font(CurrentTheme.TypeScale.emphasis).foregroundStyle(song.state == .unavailable ? CurrentTheme.muted : .primary).lineLimit(1)
                                Text(subtitle(song)).font(CurrentTheme.TypeScale.secondary)
                                    .foregroundStyle(song.state == .failed ? CurrentTheme.accent : CurrentTheme.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if song.state.active { ProgressView() }
                            else { Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure).foregroundStyle(CurrentTheme.muted) }
                        }.saturation(song.state == .unavailable ? 0 : 1)
                            .opacity(song.state == .unavailable ? 0.6 : 1)
                            .padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(CurrentRowStyle())
                }
            }
        }
        .navigationTitle("分析管理").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImport = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("加入歌曲").disabled(pool.loading || pool.failure != nil)
            }
            if outdated || missingLyrics {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if outdated { Button("更新分析") { pool.analyzeHearing(); selection = 0 } }
                        if missingLyrics { Button("补全歌词") { pool.indexMissingLyrics(); selection = 0 } }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("更多操作")
                }
            }
        }
        .sheet(isPresented: $showImport) { NavigationStack { PoolImportView() } }
    }
    @ViewBuilder private var actions: some View {
        if pool.localRunning || (selection == 0 && pool.localPendingCount > 0) {
            Button(pool.localRunning ? "暂停本机分析" : "本机分析") { pool.localRunning ? pool.pause() : pool.resume() }
                .buttonStyle(PoolActionStyle(prominent: true))
                .disabled(pool.loading || pool.failure != nil)
                .accessibilityIdentifier("poolToggle")
            if selection == 0, let reason = pool.waitReason {
                Text(reason).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            }
        } else if selection == 1 && !failed.isEmpty {
            Button("重试失败项 · \(failed.count) 首") { pool.retryFailed() }
                .buttonStyle(PoolActionStyle(prominent: true))
                .disabled(pool.loading || pool.failure != nil)
                .accessibilityIdentifier("retryFailedAnalysis")
        }
        if let failure = pool.failure {
            Text(failure).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.accent)
        }
    }
    private var emptyTitle: String {
        switch selection {
        case 1: return "没有失败的歌曲"
        case 2: return "没有不可用的歌曲"
        default: return "没有待分析的歌曲"
        }
    }
    private var emptySymbol: String {
        switch selection {
        case 1: return "exclamationmark.triangle"
        case 2: return "slash.circle"
        default: return "waveform"
        }
    }
    private var emptyDescription: String {
        switch selection {
        case 1: return "分析失败的歌曲会保留在这里，可重试。"
        case 2: return "音源不可用的歌曲会保留在这里，不参与歌单生成与播放。"
        default: return failed.isEmpty ? "从歌单加入歌曲。" : "从歌单加入歌曲，或重试失败的歌曲。"
        }
    }
    private func subtitle(_ song: PoolSong) -> String {
        if song.state == .unavailable { return song.unavailability?.message ?? "音源不可用" }
        if song.state == .failed { return song.failure ?? "分析失败" }
        if song.remotePending == true { return "已交给 Mac · 等待同步" }
        if song.needsReanalysis == true { return "重新分析中" }
        if song.features != nil {
            var parts: [String] = []
            if let bpm = song.resolvedBPM { parts.append("\(song.bpmSource == .localAnalysis ? "约 " : "")\(Int(bpm.rounded())) BPM") }
            if song.features?.profile.map({ $0.classifierAvailable && $0.classifiedWindows > 0 }) == true { parts.append("乐器已识别") }
            return parts.isEmpty ? song.state.title : parts.joined(separator: " · ")
        }
        return song.state.title
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
                                .accessibilityLabel(added.contains(track.id) ? "已加入" : "加入\(track.title)")
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
        notice = count > 0 ? "已加入 \(count) 首" : "歌曲已在池中"
    }
}

struct PoolSongDetail: View {
    let id: UUID
    @EnvironmentObject private var pool: SongPoolStore
    @Environment(\.dismiss) private var dismiss
    @State private var showMore = false
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
                if let failure = song.failure, song.state == .failed || song.state == .unavailable {
                    Text(failure).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                }
                if song.needsReanalysis == true && song.features != nil && song.state != .unavailable {
                    Text(song.state == .failed ? "重新分析失败，以下保留上次结果。" : "正在重新分析，以下为上次结果。")
                        .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                }
                if hasResults(song) {
                    results(song)
                } else if song.state != .failed && song.state != .unavailable {
                    Text("还没有分析结果。完成后会在这里显示曲风、BPM 和乐器。")
                        .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                }
                if song.state == .completed || song.state == .failed {
                    moreSection(song)
                }
                Button(role: .destructive) { pool.remove(id); dismiss() } label: {
                    Text("移出音乐库")
                        .font(CurrentTheme.TypeScale.emphasis)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(CurrentTheme.accent)
                        .background(CurrentTheme.accent.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(CurrentTheme.accent.opacity(0.18)))
                }.buttonStyle(CurrentPressStyle())
            }
        }
        .navigationTitle("歌曲详情").navigationBarTitleDisplayMode(.inline)
    }
    private func hasResults(_ song: PoolSong) -> Bool {
        song.features != nil || song.genres != nil || song.wikiMetadata != nil
    }
    private func results(_ song: PoolSong) -> some View {
        VStack(alignment: .leading, spacing: CurrentTheme.Space.group) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let bpm = song.resolvedBPM {
                    Text("\(song.bpmSource == .localAnalysis ? "约 " : "")\(Int(bpm.rounded()))")
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("BPM").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                } else {
                    Text("BPM 未知").font(CurrentTheme.TypeScale.section).foregroundStyle(CurrentTheme.muted)
                }
                Spacer()
            }
            if let genres = song.genres {
                field("曲风", genres.matches.isEmpty ? "未识别" : genres.matches.prefix(3).map(\.title).joined(separator: " · ") + (genres.compatible ? "" : " · 待更新"))
            } else if song.features != nil {
                field("曲风", "未识别")
            }
            if let profile = song.features?.profile {
                let labels = profile.soundLabels.map(\.label)
                field("乐器", profile.classifierAvailable && profile.classifiedWindows > 0 ? (labels.isEmpty ? "未识别" : labels.joined(separator: " · ")) : "未能识别")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CurrentTheme.surface, in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.card))
    }
    private func moreSection(_ song: PoolSong) -> some View {
        DisclosureGroup(isExpanded: $showMore) {
            VStack(alignment: .leading, spacing: 12) {
                detailAction("本机重新分析") { pool.reanalyze(id) }
                    .accessibilityIdentifier("reanalyzeSong")
                if !song.track.isDemo && song.state == .completed {
                    detailAction("更新资料") { pool.refreshWiki(id) }
                }
                if !song.track.isDemo {
                    detailAction("更新歌词") { pool.indexLyrics(id) }
                }
                Divider()
                lyricsStatus(song)
                Divider()
                fact("BPM 来源", song.bpmSource?.title ?? "暂无可靠结果")
                if let estimate = song.features?.bpm { fact("本地估计", String(format: "%.1f", estimate)) }
                if !song.track.isDemo { fact("网易云百科", song.bpmLookup?.title ?? "尚未获取") }
                if let wiki = song.wikiBPM { fact("百科获取时间", wiki.fetchedAt.shortDescription) }
                if let wiki = song.wikiMetadata {
                    if wiki.fields.isEmpty { fact("百科资料", "暂无") }
                    ForEach(wiki.fields.indices, id: \.self) { index in
                        fact(wiki.fields[index].title, wiki.fields[index].values.joined(separator: "、"))
                    }
                    fact("资料更新时间", wiki.fetchedAt.shortDescription)
                }
                fact("加入来源", song.sources.joined(separator: "、"))
            }.padding(.top, 12)
        } label: {
            Text("更多").font(CurrentTheme.TypeScale.emphasis)
        }
    }
    @ViewBuilder private func lyricsStatus(_ song: PoolSong) -> some View {
        VStack(alignment: .leading, spacing: CurrentTheme.Space.tiny) {
            HStack(alignment: .firstTextBaseline) {
                Text("歌词").foregroundStyle(CurrentTheme.muted)
                Spacer()
                Text(lyricsValue(song))
            }.font(CurrentTheme.TypeScale.secondary)
            if song.lyricsFailure == true {
                Text(song.lyrics == nil ? "本次歌词分析失败，可重试" : "本次更新失败，已保留上次结果")
                    .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            }
        }
    }
    private func lyricsValue(_ song: PoolSong) -> String {
        guard let lyrics = song.lyrics else { return "尚未建立索引" }
        if !lyrics.compatible { return "索引需要更新" }
        return lyrics.status == .indexed ? "已索引" : lyrics.status.title
    }
    private func statusColor(_ state: AnalysisState) -> Color {
        switch state {
        case .completed: return .green
        case .failed: return CurrentTheme.accent
        case .queued, .unavailable: return .secondary
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
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
            Text(value).font(CurrentTheme.TypeScale.body)
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(CurrentTheme.muted)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }.font(CurrentTheme.TypeScale.secondary)
    }
}
