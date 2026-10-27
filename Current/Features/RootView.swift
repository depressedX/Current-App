import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var playerTransition
    @State private var tab = 0
    @State private var showPlayer = false
    @State private var showLogin = false
    @State private var keyboardVisible = false
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { ListenView(showLogin: $showLogin, showPlayer: $showPlayer) }
                .modifier(LegacyMiniPlayerInset(isVisible: !keyboardVisible, showPlayer: $showPlayer,
                                                transition: tab == 0 ? playerTransition : nil))
                .tabItem { Label("此刻", systemImage: "house") }.tag(0)
            NavigationStack { LibraryView(showLogin: $showLogin) }
                .modifier(LegacyMiniPlayerInset(isVisible: !keyboardVisible, showPlayer: $showPlayer,
                                                transition: tab == 1 ? playerTransition : nil))
                .tabItem { Label("音乐库", systemImage: "square.stack") }.tag(1)
            NavigationStack { ProfileView(showLogin: $showLogin) }
                .modifier(LegacyMiniPlayerInset(isVisible: !keyboardVisible, showPlayer: $showPlayer,
                                                transition: tab == 2 ? playerTransition : nil))
                .tabItem { Label("我的", systemImage: "person") }.tag(2)
        }
        .modifier(NativeMiniPlayerAccessory(isVisible: !keyboardVisible, showPlayer: $showPlayer,
                                           transition: playerTransition))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .environmentObject(store.pool)
        .environmentObject(store.companion)
        .onAppear {
            store.pool.activate(account: store.listener.map { "netease:\($0.id)" } ?? "demo")
            store.pool.setForeground(scenePhase == .active)
            store.companion.setForeground(scenePhase == .active)
            store.pool.setPlaybackBusy(store.player.playing || store.player.loading)
        }
        .onChange(of: store.scope) { _, value in
            store.pool.activate(account: value.map { "netease:\($0)" } ?? "demo")
            store.companion.sendSession()
        }
        .onChange(of: scenePhase) { _, value in
            AppLog.shared.record(.app, .stateChanged, operation: .scene,
                                 reason: value == .active ? .active : value == .background ? .background : .inactive)
            store.pool.setForeground(value == .active)
            store.companion.setForeground(value == .active)
        }
        .onChange(of: store.player.playing || store.player.loading) { _, value in store.pool.setPlaybackBusy(value) }
        .toolbarBackground(CurrentTheme.background, for: .tabBar)
        .animation(reduceMotion ? nil : CurrentTheme.Motion.change, value: store.currentTrack != nil)
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(store) }
        .modifier(PlayerPresentation(isPresented: $showPlayer, namespace: playerTransition))
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

// Keep the player identity stable when the song changes while the sheet is open.
private enum PlayerTransition {
    static let sourceID = "current-player"
}

private struct PlayerPresentation: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresented: Bool
    let namespace: Namespace.ID

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            // A sheet adds its own detent/dismiss gesture; let zoom own the full-screen interaction.
            content.fullScreenCover(isPresented: $isPresented) {
                PlayerView().environmentObject(store)
                    .navigationTransition(.zoom(sourceID: PlayerTransition.sourceID, in: namespace))
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                PlayerView().environmentObject(store)
            }
        }
    }
}

private struct MiniPlayerTransitionSource: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let namespace: Namespace.ID?

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace, !reduceMotion {
            content.matchedTransitionSource(id: PlayerTransition.sourceID, in: namespace)
        } else {
            content
        }
    }
}

/// The system positions the accessory with the tab bar instead of moving a page overlay above the keyboard.
private struct NativeMiniPlayerAccessory: ViewModifier {
    @EnvironmentObject private var store: AppStore
    let isVisible: Bool
    @Binding var showPlayer: Bool
    let transition: Namespace.ID

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isVisible && store.currentTrack != nil) {
                NativeMiniPlayerContent(showPlayer: $showPlayer, transition: transition)
            }
        } else if #available(iOS 26.0, *), isVisible && store.currentTrack != nil {
            content.tabViewBottomAccessory { NativeMiniPlayerContent(showPlayer: $showPlayer, transition: transition) }
        } else {
            content
        }
    }
}

@available(iOS 26.0, *)
private struct NativeMiniPlayerContent: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Binding var showPlayer: Bool
    let transition: Namespace.ID
    var body: some View {
        MiniPlayerBar(showPlayer: $showPlayer, compact: placement == .inline)
            .modifier(MiniPlayerTransitionSource(namespace: transition))
    }
}

private struct LegacyMiniPlayerInset: ViewModifier {
    @EnvironmentObject private var store: AppStore
    let isVisible: Bool
    @Binding var showPlayer: Bool
    let transition: Namespace.ID?

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if isVisible && store.currentTrack != nil {
                    MiniPlayerBar(showPlayer: $showPlayer)
                        .background(.bar, in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.card))
                        // Only the selected tab owns a source in the shared namespace.
                        .modifier(MiniPlayerTransitionSource(namespace: transition))
                        .padding(.horizontal, 8).padding(.bottom, 4)
                }
            }
        }
    }
}

private struct MiniPlayerBar: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showPlayer: Bool
    var compact = false

    var body: some View {
        if let track = store.currentTrack {
            HStack(spacing: 4) {
                Button { showPlayer = true } label: {
                    HStack(spacing: 10) {
                        Artwork(track: track).frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if !compact {
                                Text(store.player.showLoading ? "正在加载…" : track.artist)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.accessibilityIdentifier("miniPlayer")
                    .accessibilityLabel("正在播放：\(track.title)")
                    .accessibilityHint("打开播放器")
                Button { store.player.toggle() } label: {
                    Image(systemName: store.player.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .accessibilityLabel(store.player.playing ? "暂停" : "播放")
                if !compact {
                    Button { store.next() } label: {
                        Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                    }.accessibilityLabel("下一首")
                }
            }
            .font(.system(size: 18)).foregroundStyle(.primary).buttonStyle(.plain)
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 4)
        }
    }
}

struct ListenView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showLogin: Bool
    @Binding var showPlayer: Bool
    @State private var prompt = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composing: Bool
    private var empty: Bool { prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        ScrollViewReader { scroll in
            CurrentPage {
                VStack(alignment: .leading, spacing: CurrentTheme.Space.small) {
                    Text("此刻想听什么？").font(CurrentTheme.TypeScale.title)
                    Text("写下心情、风格，或一个场景。")
                        .font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
                }.padding(.top, CurrentTheme.Space.small)
                    .contentShape(Rectangle()).onTapGesture { composing = false }
                VStack(alignment: .leading, spacing: CurrentTheme.Space.group) {
                    TextField("比如，阴郁的摇滚，别太激烈", text: $prompt, axis: .vertical)
                        .font(CurrentTheme.TypeScale.body).lineSpacing(4).lineLimit(3...5)
                        .focused($composing).accessibilityIdentifier("promptInput")
                        .submitLabel(.done)
                        .onSubmit { composing = false }
                    PrimaryButton(title: store.generating ? "正在准备歌单…" : store.generatedPlaylist == nil ? "生成歌单" : "重新生成", busy: store.generating) {
                        composing = false
                        if store.listener == nil && !store.demoMode { showLogin = true }
                        else { store.generate(prompt: prompt) }
                    }.disabled(empty).accessibilityIdentifier("generateQueue")
                    if store.generating {
                        Button("取消生成") { store.cancelGeneration() }
                            .frame(maxWidth: .infinity).accessibilityIdentifier("cancelGeneration")
                    }
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
                }
                if let issue = store.generationError {
                    VStack(alignment: .leading, spacing: CurrentTheme.Space.small) {
                        Text("暂时没有生成歌单").font(CurrentTheme.TypeScale.section)
                        Text(issue).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                        if !store.deepSeekConfigured {
                            NavigationLink("前往 AI 设置") { AISettingsView() }
                                .accessibilityIdentifier("generationAISettings")
                        } else {
                            Button("修改需求") { store.dismissGenerationError(); composing = true }
                                .accessibilityIdentifier("editGenerationPrompt")
                        }
                    }
                    .id("generationIssue")
                }
                if let playlist = store.generatedPlaylist {
                    Divider().padding(.vertical, CurrentTheme.Space.small)
                    GeneratedPlaylistSection(playlist: playlist)
                        .id(playlist.id)
                } else if !store.queue.isEmpty {
                    Divider().padding(.vertical, CurrentTheme.Space.small)
                    QueueSection(showPlayer: $showPlayer)
                }
            }
            .onChange(of: store.generatedPlaylist?.id) { _, id in
                guard let id else { return }
                composing = false
                withAnimation(reduceMotion ? nil : CurrentTheme.Motion.change) { scroll.scrollTo(id, anchor: .top) }
            }
            .onChange(of: store.generationError) { _, issue in
                if issue != nil {
                    withAnimation(reduceMotion ? nil : CurrentTheme.Motion.change) { scroll.scrollTo("generationIssue", anchor: .center) }
                }
            }
        }
        .navigationTitle("Current").navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.activePrompt) { _, _ in composing = false }
        .onAppear {
            if prompt.isEmpty, let playlist = store.generatedPlaylist { prompt = playlist.prompt }
        }
    }
}

private struct GeneratedPlaylistSection: View {
    @EnvironmentObject private var store: AppStore
    let playlist: ListeningSession
    @State private var showConditions = false
    private var subtitle: String {
        let minutes = Int(playlist.tracks.reduce(0) { $0 + $1.duration } / 60)
        return "\(playlist.tracks.count) 首" + (minutes > 0 ? " · 约 \(minutes) 分钟" : "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: CurrentTheme.Space.group) {
            Text("为此刻准备").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            Text(playlist.prompt).font(CurrentTheme.TypeScale.title).lineLimit(3)
                .accessibilityIdentifier("generatedPlaylistTitle")
            Text(subtitle).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                .accessibilityIdentifier("generatedPlaylistCount")
            PrimaryButton(title: "播放全部", symbol: "play.fill") { store.playGeneratedPlaylist() }
                .accessibilityIdentifier("playGeneratedPlaylist")
            if let query = playlist.recommendationQuery {
                DisclosureGroup("查看匹配条件", isExpanded: $showConditions) {
                    Text(query.displaySummary(concepts: store.pool.intentConcepts))
                        .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        .accessibilityIdentifier("recommendationConditions")
                }.font(CurrentTheme.TypeScale.secondary)
            }
            if store.generatedPlaylistIsActive { RecommendationContinuationView() }
            VStack(spacing: CurrentTheme.Space.tiny) {
                ForEach(Array(playlist.tracks.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track, active: store.generatedPlaylistIsActive && store.currentIndex == index, liked: store.liked(track)) {
                        store.playGeneratedPlaylist(at: index)
                    }.accessibilityIdentifier("generatedTrack:\(index)")
                }
            }
            .accessibilityElement(children: .contain)
        }
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
            if let conditions = store.activeRecommendationSummary {
                Text("筛选条件：\(conditions)")
                    .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                    .accessibilityIdentifier("recommendationConditions")
            }
            RecommendationContinuationView()
            LazyVStack(spacing: CurrentTheme.Space.tiny) {
                ForEach(Array(store.queue.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track, active: store.currentIndex == index, liked: store.liked(track)) {
                        store.play(at: index); showPlayer = true
                    }
                }
            }
        }
    }
}

struct RecommendationContinuationView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        if store.queueEnded && store.canRepeatRecommendation {
            VStack(alignment: .leading, spacing: CurrentTheme.Space.row) {
                Text("本歌单已听完").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                PrimaryButton(title: "再听一遍", symbol: "repeat") { store.continueWithRepeats() }
                    .accessibilityIdentifier("continueWithRepeats")
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
