import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var pool: SongPoolStore
    @Binding var showLogin: Bool
    @State private var search = ""
    @State private var filters = LibraryFilters()
    @State private var showFilters = false
    @FocusState private var desktopSearchFocused: Bool
    private var songs: [PoolSong] { pool.songs.filter { $0.state == .completed } }
    private var audioGenres: [GenreChoiceGroup] {
        GenreChoiceGroup.audio(songs.compactMap(\.genres))
    }
    private var wikiGenres: [String] { Array(Set(songs.flatMap { Array($0.wikiGenreLabels) })).sorted() }
    private var instruments: [String] {
        Array(Set(songs.flatMap { $0.features?.profile?.soundLabels.map(\.label) ?? [] })).sorted()
    }
    private var filtered: [PoolSong] {
        matching(filters)
    }
    private func matching(_ filters: LibraryFilters) -> [PoolSong] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return songs.filter { song in
            (query.isEmpty || song.track.title.localizedStandardContains(query) || song.track.artist.localizedStandardContains(query))
            && filters.matches(song)
        }
    }
    var body: some View {
        CurrentPage {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("我的音乐").font(CurrentTheme.TypeScale.section)
                    Text("\(songs.count) 首已纳入范围").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                }
                Spacer()
                NavigationLink { SongPoolView() } label: {
                    Text("管理").font(CurrentTheme.TypeScale.emphasis)
                        .padding(.horizontal, 18).frame(minHeight: 44)
                        .background(CurrentTheme.surface, in: Capsule())
                }.buttonStyle(CurrentPressStyle())
            }
            if ProcessInfo.processInfo.isiOSAppOnMac {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(CurrentTheme.muted)
                        TextField("搜索歌名、歌手", text: $search)
                            .textFieldStyle(.plain)
                            .focused($desktopSearchFocused)
                            .submitLabel(.search)
                            .onSubmit { desktopSearchFocused = false }
                            .accessibilityIdentifier("librarySearch")
                        if !search.isEmpty {
                            Button { search = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(CurrentTheme.muted)
                            }.buttonStyle(.plain).accessibilityLabel("清空搜索")
                        }
                    }.padding(.horizontal, 14).frame(minHeight: 44)
                        .background(CurrentTheme.surface, in: Capsule())
                    if desktopSearchFocused {
                        Button("取消") { search = ""; desktopSearchFocused = false }
                            .font(CurrentTheme.TypeScale.secondary).frame(minHeight: 44)
                    }
                }
            }
            NavigationLink { LyricsSearchView() } label: {
                HStack(spacing: 12) {
                    Text("歌词检索").font(CurrentTheme.TypeScale.emphasis).foregroundStyle(.primary)
                    Spacer()
                    Text("\(pool.lyricsCount) 首可检索").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                    Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure).foregroundStyle(CurrentTheme.muted)
                }.padding(.horizontal, 16).frame(minHeight: 56)
                    .background(CurrentTheme.surface, in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.card))
            }.buttonStyle(CurrentPressStyle())
            if songs.isEmpty {
                ContentUnavailableView("音乐库还是空的", systemImage: "music.note.list", description: Text("在管理中加入歌曲，分析完成后会出现在这里。"))
                if store.listener == nil && !store.demoMode {
                    PrimaryButton(title: "连接网易云") { showLogin = true }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            store.playLibrary(filtered.map(\.id), account: pool.account)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(CurrentTheme.accent, in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("播放全部").font(CurrentTheme.TypeScale.emphasis).foregroundStyle(.primary)
                                    Text("\(filtered.count) 首歌曲").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(CurrentPressStyle())
                            .disabled(filtered.isEmpty)
                            .opacity(filtered.isEmpty ? 0.45 : 1)
                            .accessibilityIdentifier("libraryPlayAll")
                            .accessibilityLabel("播放全部，\(filtered.count) 首歌曲")
                            .accessibilityHint("替换当前播放列表，从第一首开始播放")
                        Spacer()
                        Button { showFilters = true } label: {
                            Text(filters.count == 0 ? "筛选" : "筛选 · \(filters.count)")
                                .font(CurrentTheme.TypeScale.secondary.weight(.semibold))
                                .padding(.horizontal, 16).frame(minHeight: 44)
                                .foregroundStyle(filters.count == 0 ? Color.primary : CurrentTheme.accent)
                                .background(CurrentTheme.surface, in: Capsule())
                        }.buttonStyle(CurrentPressStyle()).accessibilityIdentifier("libraryFilters")
                    }
                    if filters.count > 0 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(filters.genres.sorted(), id: \.self) { value in
                                    removableChip(value) { filters.genres.remove(value) }
                                }
                                ForEach(filters.instruments.sorted(), id: \.self) { value in
                                    removableChip(value) { filters.instruments.remove(value) }
                                }
                                ForEach(filters.wikiGenres.sorted(), id: \.self) { value in
                                    removableChip("百科：" + value) { filters.wikiGenres.remove(value) }
                                }
                                if filters.hasBPM {
                                    removableChip(filters.bpmTitle) { filters.minimum = ""; filters.maximum = "" }
                                }
                            }
                        }
                    }
                }
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label("没有符合条件的歌曲", systemImage: "magnifyingglass")
                    } actions: {
                        if filters.count > 0 { Button("清空筛选") { filters = LibraryFilters() } }
                        if !search.isEmpty { Button("清空搜索") { search = "" } }
                    }
                }
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { song in
                        NavigationLink { PoolSongDetail(id: song.id) } label: {
                            HStack(spacing: 12) {
                                Artwork(track: song.track).frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.track.title).font(CurrentTheme.TypeScale.emphasis).foregroundStyle(.primary).lineLimit(1)
                                    Text(song.track.artist).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted).lineLimit(1)
                                    let summary = songSummary(song)
                                    if !summary.isEmpty {
                                        Text(summary).font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure).foregroundStyle(CurrentTheme.muted)
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(CurrentRowStyle())
                    }
                }
            }
        }
        .navigationTitle("音乐库").navigationBarTitleDisplayMode(.inline)
        .modifier(LibrarySearchCompatibility(text: $search))
        .sheet(isPresented: $showFilters) {
            LibraryFilterSheet(initial: filters, audioGenres: audioGenres, wikiGenres: wikiGenres, instruments: instruments,
                               resultCount: { matching($0).count }) { filters = $0 }
        }
        .onChange(of: pool.account) { _, _ in
            filters = LibraryFilters(); search = ""; showFilters = false
        }
    }
    private func removableChip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }.font(CurrentTheme.TypeScale.secondary)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(CurrentTheme.accent.opacity(0.08), in: Capsule())
                .foregroundStyle(CurrentTheme.accent)
        }.buttonStyle(CurrentPressStyle()).accessibilityLabel("移除筛选：" + title)
    }
    private func songSummary(_ song: PoolSong) -> String {
        var parts: [String] = []
        if let style = song.genres?.matches.first { parts.append(style.title) }
        if let bpm = song.resolvedBPM { parts.append("\(Int(bpm.rounded())) BPM") }
        return parts.joined(separator: " · ")
    }
}

/// UISearchController's navigation presentation can assert in iOS-on-Mac.
/// Keep the native search controller on iPhone; Mac uses the inline field above.
private struct LibrarySearchCompatibility: ViewModifier {
    @Binding var text: String
    @ViewBuilder func body(content: Content) -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            content
        } else {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索歌名、歌手")
        }
    }
}

private struct LibraryFilters {
    var genres: Set<String> = []
    var wikiGenres: Set<String> = []
    var instruments: Set<String> = []
    var minimum = ""
    var maximum = ""
    var hasBPM: Bool { !minimum.isEmpty || !maximum.isEmpty }
    var count: Int { genres.count + wikiGenres.count + instruments.count + (hasBPM ? 1 : 0) }
    var valid: Bool {
        let bounds = [minimum, maximum].filter { !$0.isEmpty }
        return bounds.allSatisfy { Int($0).map { (1...400).contains($0) } == true }
            && (Int(minimum) ?? 1) <= (Int(maximum) ?? 400)
    }
    var bpmTitle: String {
        if minimum.isEmpty { return "≤ \(maximum) BPM" }
        if maximum.isEmpty { return "≥ \(minimum) BPM" }
        return "\(minimum)–\(maximum) BPM"
    }
    // Alternatives within a category; intersect different categories.
    func matches(_ song: PoolSong) -> Bool {
        guard valid else { return false }
        let sounds = Set(song.features?.profile?.soundLabels.map(\.label) ?? [])
        return song.matchesGenreFilters(audio: genres, encyclopedia: wikiGenres)
            && (instruments.isEmpty || !instruments.isDisjoint(with: sounds))
            && (!hasBPM || song.resolvedBPM.map {
                $0 >= Double(Int(minimum) ?? 1) && $0 <= Double(Int(maximum) ?? 400)
            } == true)
    }
}

private struct LibraryFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LibraryFilters
    let audioGenres: [GenreChoiceGroup]
    let wikiGenres: [String]
    let instruments: [String]
    let resultCount: (LibraryFilters) -> Int
    let apply: (LibraryFilters) -> Void
    init(initial: LibraryFilters, audioGenres: [GenreChoiceGroup], wikiGenres: [String], instruments: [String],
         resultCount: @escaping (LibraryFilters) -> Int, apply: @escaping (LibraryFilters) -> Void) {
        _draft = State(initialValue: initial)
        self.audioGenres = audioGenres; self.wikiGenres = wikiGenres; self.instruments = instruments
        self.resultCount = resultCount; self.apply = apply
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    GenreHierarchyChoices(namespace: "libraryAudio", groups: audioGenres, selection: $draft.genres)
                } header: { Text("音频曲风") } footer: { Text("展开大类选择子风格；House 包含证据足够的 House 子风格。") }
                Section {
                    GenreHierarchyChoices(namespace: "libraryWiki", groups: GenreChoiceGroup.encyclopedia(Set(wikiGenres)), selection: $draft.wikiGenres)
                } header: { Text("百科曲风") } footer: {
                    Text("选择大类包含全部子类，也可展开细选。音频或百科任一命中即可，再同时满足乐器与节奏条件。百科标签准确性未验证。")
                }
                Section("乐器") { choices(instruments, selection: $draft.instruments) }
                Section {
                    HStack(spacing: 12) {
                        TextField("最低", text: $draft.minimum).accessibilityLabel("最低 BPM")
                        Text("—").foregroundStyle(CurrentTheme.muted)
                        TextField("最高", text: $draft.maximum).accessibilityLabel("最高 BPM")
                        Text("BPM").foregroundStyle(CurrentTheme.muted)
                    }.keyboardType(.numberPad).multilineTextAlignment(.center)
                        .padding(.vertical, 8)
                    if !draft.valid {
                        Text("请输入 1–400，最低值不能高于最高值。")
                            .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.accent)
                    }
                } header: { Text("节奏") } footer: { Text("留空不限") }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("筛选").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("重置") { draft = LibraryFilters() } }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: draft.valid ? "查看 \(resultCount(draft)) 首" : "检查 BPM 区间") {
                    apply(draft); dismiss()
                }.disabled(!draft.valid)
                    .padding(16).background(.bar)
            }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    private func choices(_ values: [String], selection: Binding<Set<String>>) -> some View {
        Group {
            if values.isEmpty {
                Text("暂无可用标签").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        let selected = selection.wrappedValue.contains(value)
                        Button {
                            if selected { selection.wrappedValue.remove(value) }
                            else { selection.wrappedValue.insert(value) }
                        } label: {
                            Text(value).font(CurrentTheme.TypeScale.secondary.weight(selected ? .semibold : .medium))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .padding(.horizontal, 8)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background(selected ? CurrentTheme.accent : Color.primary.opacity(0.06), in: Capsule())
                        }.buttonStyle(CurrentPressStyle())
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }.padding(.vertical, 4)
            }
        }
    }
}

/// Display the library genre families with their corresponding styles.
struct GenreHierarchyChoices: View {
    var namespace = "genre"
    let groups: [GenreChoiceGroup]
    @Binding var selection: Set<String>
    var body: some View {
        if groups.isEmpty {
            Text("暂无可用曲风").foregroundStyle(CurrentTheme.muted)
        }
        ForEach(groups) { group in
            if group.children.isEmpty {
                choice(group.title, id: group.id, group: group)
            } else {
                DisclosureGroup {
                    choice("全部子类", id: group.id, group: group)
                    ForEach(group.children) { option in
                        choice(option.title, id: option.id, group: group)
                    }
                } label: {
                    HStack {
                        Text(group.title)
                        Spacer()
                        if selection.contains(group.id) {
                            Text("全部").foregroundStyle(CurrentTheme.accent)
                        } else {
                            let count = group.children.filter { selection.contains($0.id) }.count
                            if count > 0 { Text("已选 \(count)").foregroundStyle(CurrentTheme.accent) }
                        }
                    }.frame(minHeight: 44)
                }.accessibilityIdentifier("\(namespace):family:\(group.id)")
            }
        }
    }
    private func choice(_ title: String, id: String, group: GenreChoiceGroup) -> some View {
        let selected = selection.contains(id)
        return Button {
            if selected { selection.remove(id) }
            else {
                if id == group.id { selection.subtract(group.children.map(\.id)) }
                else { selection.remove(group.id) }
                selection.insert(id)
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? CurrentTheme.accent : CurrentTheme.muted)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityIdentifier("\(namespace):option:\(id)")
            .accessibilityLabel("\(group.title)，\(title)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showLogin: Bool
    @State private var confirmLogout = false
    @State private var confirmClear = false
    var body: some View {
        CurrentPage {
            HStack(spacing: CurrentTheme.Space.group) {
                ZStack {
                    Circle().fill(CurrentTheme.surface)
                    if let url = store.listener?.avatar {
                        CachedArtwork(url: ArtworkCache.url(url, pixels: 160)) { Color.clear }
                    } else {
                        Image(systemName: "person.fill").font(CurrentTheme.Icon.avatar).foregroundStyle(CurrentTheme.muted)
                    }
                }.frame(width: 56, height: 56).clipShape(Circle())
                VStack(alignment: .leading, spacing: CurrentTheme.Space.tiny) {
                    Text(store.accountLabel).font(CurrentTheme.TypeScale.section).accessibilityIdentifier("accountName")
                    if let user = store.listener {
                        Text("网易云 ID · \(user.id)").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                    }
                }
            }
            if store.listener == nil {
                PrimaryButton(title: "连接网易云") { showLogin = true }
                HStack {
                    Button("恢复登录") { Task { await store.retryRestore() } }.disabled(store.restoring)
                    Spacer()
                    if !store.demoMode { Button("先体验一下") { store.enterDemo() } }
                }.font(CurrentTheme.TypeScale.secondary)
            }
            if store.listener != nil || store.demoMode {
                Divider()
                NavigationLink { SongPoolView() } label: {
                    HStack {
                        Text("歌曲池").font(CurrentTheme.TypeScale.body).foregroundStyle(.primary)
                        Spacer()
                        Text("管理分析").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                        Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure).foregroundStyle(CurrentTheme.muted)
                    }.frame(minHeight: 44)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: CurrentTheme.Space.group) {
                Text("最近听过").font(CurrentTheme.TypeScale.section)
                if store.visibleSessions.isEmpty {
                    Text("还没有听歌记录").font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
                }
                ForEach(store.visibleSessions.prefix(8)) { session in
                    Button { store.replay(session) } label: {
                        HStack(spacing: CurrentTheme.Space.row) {
                            if let track = session.tracks.first { Artwork(track: track).frame(width: 44, height: 44) }
                            VStack(alignment: .leading, spacing: CurrentTheme.Space.tiny) {
                                Text(session.prompt).font(CurrentTheme.TypeScale.emphasis).foregroundStyle(.primary).lineLimit(2)
                                Text("\(session.tracks.count) 首 · \(session.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(CurrentRowStyle())
                }
            }
            if !store.visibleFeedback.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: CurrentTheme.Space.group) {
                    Text("最近反馈").font(CurrentTheme.TypeScale.section)
                    ForEach(store.visibleFeedback.prefix(10)) { item in
                        HStack(spacing: CurrentTheme.Space.row) {
                            Text(item.trackTitle).font(CurrentTheme.TypeScale.body).lineLimit(1)
                            Spacer()
                            Text(item.kind.title).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                        }.padding(.vertical, 4)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: CurrentTheme.Space.page) {
                NavigationLink { AISettingsView() } label: {
                    HStack {
                        Text("AI 设置").font(CurrentTheme.TypeScale.body).foregroundStyle(.primary)
                        Spacer()
                        Text(store.deepSeekConfigured ? "已配置" : "填写个人 Key").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                        Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure).foregroundStyle(CurrentTheme.muted)
                    }
                }.accessibilityIdentifier("openAISettings")
                NavigationLink { AboutView() } label: {
                    HStack {
                        Text("关于 Current").font(CurrentTheme.TypeScale.body).foregroundStyle(.primary)
                        Spacer(); Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure).foregroundStyle(CurrentTheme.muted)
                    }
                }
                NavigationLink { DiagnosticsView() } label: {
                    HStack {
                        Text("诊断日志").font(CurrentTheme.TypeScale.body).foregroundStyle(.primary)
                        Spacer(); Image(systemName: "chevron.right").font(CurrentTheme.Icon.disclosure).foregroundStyle(CurrentTheme.muted)
                    }
                }
                Button("清除听歌记录", role: .destructive) { confirmClear = true }.font(CurrentTheme.TypeScale.body)
                if store.listener != nil || store.demoMode {
                    Button(store.listener != nil ? "退出网易云" : "退出演示", role: .destructive) { confirmLogout = true }
                        .font(CurrentTheme.TypeScale.body).accessibilityIdentifier("signOut")
                }
            }
        }
        .navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("退出并停止播放？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出", role: .destructive) { Task { await store.signOut() } }
        }
        .confirmationDialog("清除本机听歌记录和反馈？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除记录", role: .destructive) { store.clearHistory() }
        }
    }
}

struct AboutView: View {
    var body: some View {
        CurrentPage {
            VStack(alignment: .leading, spacing: CurrentTheme.Space.small) {
                Text("Current").font(CurrentTheme.TypeScale.title)
                Text("0.1.0 · 交互预览").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            }
            aboutSection("选歌", "通过个人 DeepSeek Key 理解听歌需求，再按 BPM 条件和歌曲池听感排序。一次加入全部匹配歌曲；听完后可手动再听一遍。")
            aboutSection("推荐偏好", "喜欢和不合适仅用于 Current 的推荐偏好，永不同步网易云收藏。当前只记录反馈，待接入推荐排序后生效。")
            aboutSection("演示音频", "8 首原创合成片段，用于体验播放操作。")
            aboutSection("CarPlay", "先在 iPhone 准备歌单。真机使用需要 Apple 音频授权。")
        }.navigationTitle("关于").navigationBarTitleDisplayMode(.inline)
    }
    private func aboutSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: CurrentTheme.Space.small) {
            Text(title).font(CurrentTheme.TypeScale.section)
            Text(text).font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted).lineSpacing(4)
        }
    }
}
