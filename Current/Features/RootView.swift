import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab = 0
    @State private var showPlayer = false
    @State private var showLogin = false
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { ListenView(showLogin: $showLogin, showPlayer: $showPlayer) }
                .tabItem { Label("此刻", systemImage: "house") }.tag(0)
            NavigationStack { LibraryView(showLogin: $showLogin) }
                .tabItem { Label("音乐库", systemImage: "square.stack") }.tag(1)
            NavigationStack { ProfileView(showLogin: $showLogin) }
                .tabItem { Label("我的", systemImage: "person") }.tag(2)
        }
        .environmentObject(store.pool)
        .onAppear {
            store.pool.activate(account: store.listener.map { "netease:\($0.id)" } ?? "demo")
            store.pool.setForeground(scenePhase == .active)
            store.pool.setPlaybackBusy(store.player.playing || store.player.loading)
        }
        .onChange(of: store.scope) { _, value in
            store.pool.activate(account: value.map { "netease:\($0)" } ?? "demo")
        }
        .onChange(of: scenePhase) { _, value in
            AppLog.shared.record(.app, .stateChanged, operation: .scene,
                                 reason: value == .active ? .active : value == .background ? .background : .inactive)
            store.pool.setForeground(value == .active)
        }
        .onChange(of: store.player.playing || store.player.loading) { _, value in store.pool.setPlaybackBusy(value) }
        .toolbarBackground(CurrentTheme.background, for: .tabBar)
        .overlay(alignment: .bottom) {
            if let track = store.currentTrack {
                HStack(spacing: CurrentTheme.Space.small) {
                    Button { showPlayer = true } label: {
                        HStack(spacing: CurrentTheme.Space.row) {
                            Artwork(track: track).frame(width: 42, height: 42)
                            VStack(alignment: .leading, spacing: CurrentTheme.Space.tiny) {
                                Text(track.title).font(CurrentTheme.TypeScale.emphasis).lineLimit(1)
                                Text(store.player.loading ? "正在加载…" : track.artist)
                                    .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("miniPlayer")
                    Button { store.player.toggle() } label: {
                        Image(systemName: store.player.playing ? "pause.fill" : "play.fill")
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel(store.player.playing ? "暂停" : "播放")
                    Button { store.next() } label: {
                        Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                    }.accessibilityLabel("下一首")
                }
                .font(CurrentTheme.Icon.standard).foregroundStyle(.primary)
                .buttonStyle(CurrentPressStyle())
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.panel))
                .overlay(RoundedRectangle(cornerRadius: CurrentTheme.Radius.panel).stroke(.primary.opacity(0.06)))
                .frame(maxWidth: CurrentTheme.Layout.readableWidth)
                .padding(.horizontal, 16).padding(.bottom, 62)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : CurrentTheme.Motion.change, value: store.currentTrack != nil)
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(store) }
        .sheet(isPresented: $showPlayer) { PlayerView().environmentObject(store) }
        .alert("暂时无法完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .overlay(alignment: .top) {
            if let message = store.message {
                Text(message).font(CurrentTheme.TypeScale.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding(.top, 8)
                    .onTapGesture { store.message = nil }
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(3))
                        if store.message == message { store.message = nil }
                    }.accessibilityIdentifier("feedbackToast")
            }
        }
    }
}

struct ListenView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showLogin: Bool
    @Binding var showPlayer: Bool
    @State private var prompt = ""
    @FocusState private var composing: Bool
    private let suggestions = ["阴郁的摇滚", "下班路上，轻快一点", "120–128 BPM", "安静的人声"]
    private var empty: Bool { prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        CurrentPage {
            VStack(alignment: .leading, spacing: CurrentTheme.Space.small) {
                Text("此刻想听什么？").font(CurrentTheme.TypeScale.title)
                Text("写下心情、风格，或一个场景。")
                    .font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
            }.padding(.top, CurrentTheme.Space.small)
            VStack(alignment: .leading, spacing: CurrentTheme.Space.group) {
                TextField("比如，阴郁的摇滚，别太激烈", text: $prompt, axis: .vertical)
                    .font(CurrentTheme.TypeScale.body).lineSpacing(4).lineLimit(3...5)
                    .focused($composing).accessibilityIdentifier("promptInput")
                    .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { composing = false } } }
                PrimaryButton(title: store.generating ? "正在准备…" : "生成歌单", busy: store.generating) {
                    composing = false
                    if store.listener == nil && !store.demoMode { showLogin = true }
                    else { store.generate(prompt: prompt) }
                }.disabled(empty).accessibilityIdentifier("generateQueue")
            }
            .padding(CurrentTheme.Space.group)
            .background(CurrentTheme.surface, in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.card))
            if store.listener == nil && !store.demoMode {
                HStack {
                    Button("连接网易云") { showLogin = true }
                    Spacer()
                    Button("先体验一下") { store.enterDemo() }
                        .foregroundStyle(CurrentTheme.muted).accessibilityIdentifier("enterDemo")
                }.font(CurrentTheme.TypeScale.body).buttonStyle(CurrentPressStyle())
            } else {
                Text("模拟意图 · 按歌曲池听感匹配，尚未理解文本")
                    .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
            }
            VStack(alignment: .leading, spacing: CurrentTheme.Space.row) {
                Text("试试这些").font(CurrentTheme.TypeScale.section)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: CurrentTheme.Space.small) {
                    ForEach(suggestions, id: \.self) { text in
                        Button { prompt = text; composing = false } label: {
                            Text(text).font(CurrentTheme.TypeScale.secondary)
                                .foregroundStyle(prompt == text ? CurrentTheme.accent : .primary)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 12)
                                .background(prompt == text ? CurrentTheme.accent.opacity(0.08) : CurrentTheme.surface,
                                            in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.standard))
                        }.buttonStyle(CurrentPressStyle())
                    }
                }
            }
            if !store.queue.isEmpty {
                Divider().padding(.vertical, CurrentTheme.Space.small)
                QueueSection(showPlayer: $showPlayer)
            }
        }
        .navigationTitle("Current").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(store.accountLabel).font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
            }
        }
        .onChange(of: store.queue) { _, _ in if !store.queue.isEmpty { composing = false } }
    }
}

struct QueueSection: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showPlayer: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: CurrentTheme.Space.group) {
            HStack(alignment: .firstTextBaseline) {
                Text("当前歌单").font(CurrentTheme.TypeScale.section)
                Spacer(); Text("\(store.queue.count) 首").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            }
            Text(store.activePrompt).font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
            LazyVStack(spacing: CurrentTheme.Space.tiny) {
                ForEach(Array(store.queue.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, active: store.currentTrack?.id == track.id, liked: store.liked(track)) {
                        store.play(at: index); showPlayer = true
                    }
                }
            }
        }
    }
}

struct TrackRow: View {
    let track: Track
    var active = false
    var liked = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: CurrentTheme.Space.row) {
                Artwork(track: track).frame(width: CurrentTheme.Layout.artwork, height: CurrentTheme.Layout.artwork)
                VStack(alignment: .leading, spacing: CurrentTheme.Space.tiny) {
                    Text(track.title).font(CurrentTheme.TypeScale.emphasis)
                        .foregroundStyle(active ? CurrentTheme.accent : .primary).lineLimit(1)
                    Text(track.artist).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if liked { Image(systemName: "heart.fill").font(CurrentTheme.Icon.status).foregroundStyle(CurrentTheme.accent) }
                Text(track.duration.clock).font(CurrentTheme.TypeScale.caption).monospacedDigit().foregroundStyle(CurrentTheme.muted)
            }
            .padding(.vertical, 8).padding(.horizontal, 8)
            .background(active ? CurrentTheme.surface : .clear, in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.standard))
            .contentShape(Rectangle())
        }.buttonStyle(CurrentRowStyle())
    }
}
