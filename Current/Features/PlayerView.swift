import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var feedbackTarget: FeedbackTarget?
    @State private var recentFeedback: FeedbackTarget?
    @State private var showQueue = false
    @State private var showTempo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toolsExpanded = false
    @GestureState(resetTransaction: Transaction(animation: .timingCurve(0.16, 1, 0.3, 1, duration: 0.36)))
    private var toolsDrag: CGFloat = 0
    @GestureState private var gestureOwnsTools = false
    private var toolsProgress: CGFloat {
        min(1, max(0, (toolsExpanded ? 1 : 0) - toolsDrag / 120))
    }
    private func revealTools(_ expanded: Bool) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .timingCurve(0.16, 1, 0.3, 1, duration: expanded ? 0.36 : 0.27)) {
            toolsExpanded = expanded
        }
    }
    private var toolsGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($gestureOwnsTools) { _, state, _ in
                // Keep this drag assigned to the tools until the finger lifts.
                state = state || toolsExpanded
            }
            .updating($toolsDrag) { value, state, _ in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                state = value.translation.height
            }
            .onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                let projected = value.predictedEndTranslation.height
                if value.translation.height < -35 || projected < -90 { revealTools(true) }
                else if value.translation.height > 35 || projected > 90 { revealTools(false) }
            }
    }
    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = geo.size.height < 650 ? 8 : 16
            Group {
                if let track = store.currentTrack {
                    VStack(spacing: spacing) {
                        HStack {
                            Button {
                                if toolsExpanded { revealTools(false) } else { dismiss() }
                            } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel(toolsExpanded ? "收起更多操作" : "收起播放器")
                            Spacer()
                            VStack(spacing: 4) {
                                Text("正在播放").font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                                Text(store.activePrompt).font(CurrentTheme.TypeScale.secondary).lineLimit(1)
                            }
                            Spacer()
                            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                        }.foregroundStyle(.primary)
                        // Artwork uses the height left after the controls are measured.
                        // Short screens and feedback messages shrink the cover, never scroll the page.
                        GeometryReader { artwork in
                            let side = max(0, min(320 - (reduceMotion ? 0 : 48 * toolsProgress), min(artwork.size.width, artwork.size.height)))
                            Artwork(track: track, radius: CurrentTheme.Radius.card, pixels: 768)
                                .frame(width: side, height: side)
                                .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .contentShape(Rectangle())
                        .accessibilityAction(named: toolsExpanded ? "收起更多操作" : "展开更多操作") {
                            revealTools(!toolsExpanded)
                        }
                        .frame(minHeight: 0)
                        .layoutPriority(-1)
                        .padding(.vertical, spacing)
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: CurrentTheme.Space.small) {
                                Text(track.title).font(CurrentTheme.TypeScale.section).lineLimit(2)
                                Text(track.artist).font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }.fixedSize(horizontal: false, vertical: true)
                        PlaybackScrubber(player: store.player)
                            .id(track.id)
                        HStack(spacing: 0) {
                            PlaybackOrderControl()
                            Spacer(minLength: 4)
                            Button { store.previous() } label: { Image(systemName: "backward.end.fill").font(CurrentTheme.Icon.control).frame(width: 48, height: 48) }.accessibilityLabel("上一首")
                            Spacer(minLength: 4)
                            Button {
                                if store.player.error != nil { store.play(at: store.currentIndex) }
                                else { store.player.toggle() }
                            } label: {
                                ZStack {
                                    Circle().fill(.primary).frame(width: 64, height: 64)
                                    Image(systemName: store.player.playing ? "pause.fill" : "play.fill")
                                        .font(CurrentTheme.Icon.play).foregroundStyle(CurrentTheme.background)
                                        .contentTransition(.identity)
                                        .animation(nil, value: store.player.playing)
                                    if store.player.showLoading {
                                        ProgressView().tint(CurrentTheme.accent).offset(x: 44)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(store.player.playing ? "暂停" : "播放").accessibilityIdentifier("playerToggle")
                            Spacer(minLength: 4)
                            Button { store.next() } label: { Image(systemName: "forward.end.fill").font(CurrentTheme.Icon.control).frame(width: 48, height: 48) }
                                .accessibilityLabel("下一首").accessibilityIdentifier("playerNext")
                            Spacer(minLength: 4)
                            Button { showQueue = true } label: {
                                Image(systemName: "list.bullet").font(.system(size: 20, weight: .medium))
                                    .frame(width: 44, height: 44)
                            }.accessibilityLabel("播放队列")
                        }.foregroundStyle(.primary)
                        if let error = store.player.error {
                            Text(error).font(CurrentTheme.TypeScale.secondary).foregroundStyle(.orange).multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        RecommendationContinuationView()
                        VStack(spacing: 0) {
                            Button { revealTools(!toolsExpanded) } label: {
                                Capsule().fill(CurrentTheme.muted.opacity(0.45))
                                    .frame(width: 28, height: 4)
                                    .frame(maxWidth: .infinity).frame(height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(toolsExpanded ? "收起更多操作" : "展开更多操作")
                            .accessibilityHint("也可在封面上滑或下滑")
                            .accessibilityIdentifier("playerToolsToggle")
                            HStack(spacing: 0) {
                                PlayerFeedbackButton(title: store.player.tempo.enabled ? PlaybackTempo.label(store.player.tempo.targetBPM) : "BPM",
                                                     symbol: "speedometer", selected: store.player.tempo.enabled) { showTempo = true }
                                    .accessibilityLabel("播放速度")
                                    .accessibilityValue(store.player.tempo.enabled ? "\(PlaybackTempo.label(store.player.tempo.targetBPM)) BPM" : "原速")
                                    .accessibilityIdentifier("playbackTempo")
                                    .frame(maxWidth: .infinity)
                                    .modifier(PlayerToolRipple(progress: toolsProgress, direction: -1,
                                                               expanded: toolsExpanded, reduceMotion: reduceMotion))
                                PlayerFeedbackButton(title: "不合适", symbol: "hand.thumbsdown") {
                                    let prompt = store.activePrompt
                                    let id = store.record(.notNow, track: track, prompt: prompt)
                                    recentFeedback = FeedbackTarget(id: id, track: track, prompt: prompt)
                                }
                                .accessibilityHint("跳过这首，仅调整此刻偏好，可撤销或修改范围")
                                .accessibilityIdentifier("openFeedback")
                                .frame(maxWidth: .infinity)
                                .modifier(PlayerToolRipple(progress: toolsProgress, direction: 0,
                                                           expanded: toolsExpanded, reduceMotion: reduceMotion))
                                PlayerFeedbackButton(title: store.liked(track) ? "已喜欢" : "喜欢", symbol: store.liked(track) ? "heart.fill" : "heart",
                                                     selected: store.liked(track)) {
                                    guard !store.liked(track) else { return }
                                    store.record(.fits, track: track)
                                }
                                .accessibilityLabel(store.liked(track) ? "已喜欢，仅用于 Current 推荐" : "喜欢，仅用于 Current 推荐")
                                .accessibilityHint("记录正向偏好，不同步网易云收藏")
                                .accessibilityAddTraits(store.liked(track) ? .isSelected : [])
                                .accessibilityIdentifier("likeTrack")
                                .frame(maxWidth: .infinity)
                                .modifier(PlayerToolRipple(progress: toolsProgress, direction: 1,
                                                           expanded: toolsExpanded, reduceMotion: reduceMotion))
                            }
                            .frame(height: 56)
                            .frame(height: 56 * toolsProgress, alignment: .top)
                            .clipped()
                            .allowsHitTesting(toolsExpanded && toolsDrag == 0)
                            .accessibilityHidden(!toolsExpanded)
                        }
                        .sensoryFeedback(.selection, trigger: toolsExpanded)
                        .sensoryFeedback(.success, trigger: store.liked(track))
                    }
                    .buttonStyle(CurrentPressStyle())
                    .frame(maxWidth: 480)
                    .padding(.horizontal, CurrentTheme.Space.page)
                    .padding(.vertical, spacing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .sheet(item: $feedbackTarget) { target in
                        FeedbackView(target: target).environmentObject(store).presentationDetents([.medium, .large])
                    }
                } else { ContentUnavailableView("还没有正在播放的歌", systemImage: "music.note", description: Text("先为此刻生成一个队列。")) }
            }
            .background {
                ZStack {
                    CurrentTheme.background
                    CurrentTheme.gradient(store.currentTrack?.id ?? 0).opacity(0.08).blur(radius: 80)
                }.ignoresSafeArea()
            }
        }
        .simultaneousGesture(toolsGesture)
        .interactiveDismissDisabled(toolsExpanded || gestureOwnsTools)
        .safeAreaInset(edge: .bottom) {
            if let target = recentFeedback {
                HStack(spacing: 12) {
                    Text("已跳过 · \(store.feedback.first(where: { $0.id == target.id })?.kind.title ?? "不适合此刻")")
                        .font(CurrentTheme.TypeScale.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("修改") { feedbackTarget = target }
                    Button("撤销") { store.undoFeedback(target.id); recentFeedback = nil }
                }
                .font(CurrentTheme.TypeScale.secondary).tint(CurrentTheme.accent)
                .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24).padding(.bottom, 8)
                .task(id: target.id) {
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled, recentFeedback?.id == target.id else { return }
                    recentFeedback = nil
                }
            }
        }
        .onChange(of: store.scope) { _, _ in recentFeedback = nil; feedbackTarget = nil; showTempo = false; toolsExpanded = false }
        .overlay {
            if showTempo {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.08).ignoresSafeArea()
                        .onTapGesture { showTempo = false }
                        .accessibilityLabel("关闭播放速度")
                        .accessibilityAddTraits(.isButton)
                    PlaybackTempoView(player: store.player)
                        .frame(maxWidth: 480)
                        .padding(.horizontal, 16).padding(.bottom, 20)
                        .accessibilityAction(.escape) { showTempo = false }
                }
            }
        }
        .sheet(isPresented: $showQueue) {
            NavigationStack {
                ScrollView {
                    QueueSection(showPlayer: .constant(false)).frame(maxWidth: CurrentTheme.Layout.readableWidth).padding(CurrentTheme.Space.page).frame(maxWidth: .infinity)
                }.background(CurrentTheme.background)
                    .navigationTitle("当前队列").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("完成") { showQueue = false } }
            }.environmentObject(store)
        }
    }
}

/// Local animation only: the surrounding layout always uses a bounded ease-out curve.
private struct PlayerToolRipple: ViewModifier {
    let progress: CGFloat
    let direction: CGFloat
    let expanded: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .modifier(PlayerToolRippleFrame(progress: progress, direction: direction, reduceMotion: reduceMotion))
            .animation(reduceMotion ? .easeOut(duration: 0.18) :
                .interpolatingSpring(mass: 1, stiffness: 330, damping: expanded ? 18.5 : 32)
                    .delay(expanded && direction != 0 ? 0.045 : 0), value: progress)
    }
}

private struct PlayerToolRippleFrame: AnimatableModifier {
    var progress: CGFloat
    let direction: CGFloat
    let reduceMotion: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let visible = min(1, max(0, progress))
        content
            .opacity(Double(min(1, max(0, (visible - 0.08) / 0.75))))
            .scaleEffect(reduceMotion ? 1 : 1 - 0.055 * (1 - visible))
            .offset(x: reduceMotion ? 0 : direction * 10 * (1 - progress),
                    y: reduceMotion ? 0 : 42 * (1 - progress))
    }
}

private struct PlayerFeedbackButton: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(CurrentTheme.TypeScale.caption).lineLimit(1)
            }
            .foregroundStyle(selected ? CurrentTheme.accent : .primary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(CurrentPressStyle())
    }
}

private struct FeedbackView: View {
    let target: FeedbackTarget
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: CurrentTheme.Space.group) {
            Capsule().fill(.secondary.opacity(0.25)).frame(width: 36, height: 4).frame(maxWidth: .infinity).padding(.top, 10)
            Text("减少推荐的范围").font(CurrentTheme.TypeScale.section)
            Text(target.track.title).font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
            ForEach([FeedbackKind.notNow, .snooze, .dislike]) { kind in
                Button {
                    store.updateFeedback(target.id, kind: kind); dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.title).font(CurrentTheme.TypeScale.body)
                            Text(kind == .notNow ? "只影响这次听歌" : kind == .snooze ? "标记为暂时减少这首歌" : "标记为长期降低推荐权重")
                                .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                        }
                        if store.feedback.first(where: { $0.id == target.id })?.kind == kind {
                            Image(systemName: "checkmark").foregroundStyle(CurrentTheme.accent)
                        }
                        Spacer()
                    }.padding(.vertical, 10).contentShape(Rectangle()).foregroundStyle(.primary)
                }.buttonStyle(CurrentRowStyle()).accessibilityIdentifier("feedback-\(kind.rawValue)")
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, CurrentTheme.Space.page).frame(maxWidth: CurrentTheme.Layout.readableWidth).frame(maxWidth: .infinity).background(CurrentTheme.background)
    }
}

private struct PlaybackScrubber: View {
    @ObservedObject var player: PlaybackController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragging = false
    @State private var origin: Double?
    @State private var preview: Double?

    private var duration: Double { player.duration.isFinite ? max(0, player.duration) : 0 }
    private var position: Double { min(duration, max(0, preview ?? player.position)) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.10))
                    Rectangle().fill(.primary.opacity(dragging ? 0.65 : 0.38))
                        .frame(width: width * (duration > 0 ? position / duration : 0))
                }
                .frame(height: dragging ? 8 : 4)
                .clipShape(Capsule())
                .frame(maxHeight: .infinity)
                .frame(width: geometry.size.width)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        guard duration > 0 else { return }
                        if origin == nil { origin = position }
                        preview = min(duration, max(0, (origin ?? position) + value.translation.width / width * duration))
                    }
                    .onEnded { value in
                        if let origin, duration > 0 {
                            player.seek(min(duration, max(0, origin + value.translation.width / width * duration)))
                        }
                        origin = nil; preview = nil
                    })
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: dragging)
            }
            .frame(height: 44)
            .accessibilityRepresentation {
                Slider(value: Binding(get: { position }, set: { player.seek($0) }), in: 0...max(1, duration))
                    .disabled(duration <= 0)
                    .accessibilityLabel("播放进度")
                    .accessibilityValue("已播放 \(position.clock)，剩余 \(max(0, duration - position).clock)")
            }
            HStack {
                Text(position.clock).accessibilityIdentifier("playerElapsedTime")
                Spacer()
                Text("−" + max(0, duration - position).clock).accessibilityIdentifier("playerRemainingTime")
            }
            .font(.system(size: 12)).monospacedDigit().foregroundStyle(CurrentTheme.muted)
        }
        .onChange(of: dragging) { _, active in
            // GestureState also resets when the system cancels a touch.
            if !active { origin = nil; preview = nil }
        }
    }
}

private struct FeedbackTarget: Identifiable {
    let id: UUID
    let track: Track
    let prompt: String
}
