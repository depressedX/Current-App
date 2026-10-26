import SwiftUI
import AVKit

struct PlayerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var feedbackTarget: FeedbackTarget?
    @State private var recentFeedback: FeedbackTarget?
    @State private var showQueue = false
    @State private var seekPosition: Double = 0
    @State private var seeking = false
    var body: some View {
        GeometryReader { geo in
            let coverSide = min(320, min(max(0, geo.size.width - 48), max(128, geo.size.height * 0.34)))
            ScrollView {
                if let track = store.currentTrack {
                    VStack(spacing: CurrentTheme.Space.group) {
                        HStack {
                            Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("收起播放器")
                            Spacer()
                            VStack(spacing: 4) {
                                Text("正在播放").font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                                Text(store.activePrompt).font(CurrentTheme.TypeScale.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("播放队列")
                        }.foregroundStyle(.primary)
                        Artwork(track: track, radius: CurrentTheme.Radius.card, pixels: 768)
                            .frame(width: coverSide, height: coverSide)
                            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
                            .padding(.vertical, CurrentTheme.Space.small)
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: CurrentTheme.Space.small) {
                                Text(track.title).font(CurrentTheme.TypeScale.section).lineLimit(2)
                                Text(track.artist).font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
                            }
                            Spacer()
                        }
                        VStack(spacing: 0) {
                            Slider(value: Binding(get: { seeking ? seekPosition : min(store.player.position, max(1, store.player.duration)) }, set: { seekPosition = $0 }),
                                   in: 0...max(1, store.player.duration)) { editing in
                                seeking = editing
                                if !editing { store.player.seek(seekPosition) }
                            }.accessibilityLabel("播放进度")
                            HStack {
                                Text((seeking ? seekPosition : store.player.position).clock)
                                Spacer(); Text(store.player.duration.clock)
                            }.font(CurrentTheme.TypeScale.caption).monospacedDigit().foregroundStyle(CurrentTheme.muted)
                        }
                        HStack(spacing: 40) {
                            Button { store.previous() } label: { Image(systemName: "backward.end.fill").font(CurrentTheme.Icon.control).frame(width: 48, height: 48) }.accessibilityLabel("上一首")
                            Button {
                                if store.player.error != nil { store.play(at: store.currentIndex) }
                                else { store.player.toggle() }
                            } label: {
                                ZStack {
                                    Circle().fill(.primary).frame(width: 64, height: 64)
                                    Image(systemName: store.player.playing ? "pause.fill" : "play.fill")
                                        .font(CurrentTheme.Icon.play).foregroundStyle(CurrentTheme.background)
                                    if store.player.showLoading {
                                        ProgressView().tint(CurrentTheme.accent).offset(x: 44)
                                    }
                                }
                            }.accessibilityLabel(store.player.playing ? "暂停" : "播放").accessibilityIdentifier("playerToggle")
                            Button { store.next() } label: { Image(systemName: "forward.end.fill").font(CurrentTheme.Icon.control).frame(width: 48, height: 48) }
                                .accessibilityLabel("下一首").accessibilityIdentifier("playerNext")
                        }.foregroundStyle(.primary)
                        if let error = store.player.error {
                            Text(error).font(CurrentTheme.TypeScale.secondary).foregroundStyle(.orange).multilineTextAlignment(.center)
                        }
                        RecommendationContinuationView()
                        HStack(spacing: CurrentTheme.Space.row) {
                            FeedbackChoiceButton(title: "不合适", symbol: "hand.thumbsdown") {
                                let prompt = store.activePrompt
                                let id = store.record(.notNow, track: track, prompt: prompt)
                                recentFeedback = FeedbackTarget(id: id, track: track, prompt: prompt)
                            }
                            .accessibilityHint("跳过这首，仅调整此刻偏好，可撤销或修改范围")
                            .accessibilityIdentifier("openFeedback")
                            FeedbackChoiceButton(title: store.liked(track) ? "已喜欢" : "喜欢", symbol: store.liked(track) ? "heart.fill" : "heart",
                                                 selected: store.liked(track)) {
                                guard !store.liked(track) else { return }
                                store.record(.fits, track: track)
                            }
                            .accessibilityLabel(store.liked(track) ? "已喜欢，仅用于 Current 推荐" : "喜欢，仅用于 Current 推荐")
                            .accessibilityHint("记录正向偏好，不同步网易云收藏")
                            .accessibilityAddTraits(store.liked(track) ? .isSelected : [])
                            .accessibilityIdentifier("likeTrack")
                        }
                        .sensoryFeedback(.success, trigger: store.liked(track))
                        HStack {
                            Text(track.isDemo ? "演示音频" : "网易云音乐").font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                            Spacer(); RoutePicker().frame(width: 44, height: 44).accessibilityLabel("音频输出设备")
                        }
                    }.buttonStyle(CurrentPressStyle()).frame(maxWidth: 480).padding(.horizontal, CurrentTheme.Space.page).padding(.bottom, CurrentTheme.Space.page).frame(maxWidth: .infinity)
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
        .onChange(of: store.scope) { _, _ in recentFeedback = nil; feedbackTarget = nil }
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

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.tintColor = .secondaryLabel; view.activeTintColor = UIColor(CurrentTheme.accent)
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private struct FeedbackTarget: Identifiable {
    let id: UUID
    let track: Track
    let prompt: String
}
