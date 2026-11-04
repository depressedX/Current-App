import SwiftUI

struct PlaybackTempoButton: View {
    @ObservedObject var player: PlaybackController
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                Text(player.tempo.enabled ? PlaybackTempo.label(player.tempo.targetBPM) : "BPM")
            }
            .font(CurrentTheme.TypeScale.emphasis)
            .foregroundStyle(player.tempo.enabled ? CurrentTheme.accent : Color.primary)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(CurrentTheme.surface, in: Capsule())
        }
        .accessibilityLabel("播放速度")
        .accessibilityValue(player.tempo.enabled ? "\(PlaybackTempo.label(player.tempo.targetBPM)) BPM" : "原速")
        .accessibilityIdentifier("playbackTempo")
    }
}

struct PlaybackTempoView: View {
    @ObservedObject var player: PlaybackController
    @GestureState private var previewBPM: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("播放速度").font(CurrentTheme.TypeScale.body).foregroundStyle(.secondary)
                Text((previewBPM ?? player.tempo.displayBPM).map { "\(PlaybackTempo.label($0)) BPM" } ?? "— BPM")
                    .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("tempoTarget")
                Spacer(minLength: 0)
                if player.tempo.enabled {
                    Button { player.setTempoEnabled(false) } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(CurrentTheme.TypeScale.body)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).debugHitArea()
                    .tint(.primary).accessibilityLabel("还原原速")
                    .accessibilityIdentifier("resetTempo")
                }
            }
            .frame(minHeight: 44)
            BPMRuler(value: Binding(get: { player.tempo.displayBPM ?? player.tempo.targetBPM }, set: player.setTargetBPM),
                     original: player.tempo.originalBPM, enabled: player.tempo.enabled, preview: $previewBPM,
                     onEditingBegan: player.beginTempoEditing, onCommit: player.endTempoEditing)
            if let issue = player.tempoAdjustmentIssue ?? player.tempo.issue {
                Text(issue).font(CurrentTheme.TypeScale.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: previewBPM != nil) { _, active in
            if !active { player.cancelTempoEditing() }
        }
        .onDisappear { player.cancelTempoEditing() }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
    }
}

/// The colored line marks the exact original BPM; only the selected target snaps to five.
struct BPMRuler: View {
    @Binding var value: Double
    let original: Double?
    let enabled: Bool
    let preview: GestureState<Double?>
    let onEditingBegan: () -> Void
    let onCommit: (Double) -> Void
    private var displayedValue: Double { preview.wrappedValue ?? value }
    private let inset: CGFloat = 12
    private func fraction(_ bpm: Double) -> Double {
        (bpm - PlaybackTempo.targetRange.lowerBound) / (PlaybackTempo.targetRange.upperBound - PlaybackTempo.targetRange.lowerBound)
    }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - inset * 2)
            ZStack(alignment: .topLeading) {
                ForEach(PlaybackTempo.targets, id: \.self) { tick in
                    let major = Int(tick) % 20 == 0
                    Capsule().fill(Color.primary.opacity(major ? 0.33 : 0.15))
                        .frame(width: major ? 2.5 : 2, height: major ? 22 : 12)
                        .position(x: inset + fraction(tick) * width, y: 23)
                    if Int(tick) % 40 == 0 {
                        Text("\(Int(tick))").font(CurrentTheme.TypeScale.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .position(x: inset + fraction(tick) * width, y: 62)
                    }
                }
                if let original, PlaybackTempo.targetRange.contains(original) {
                    Capsule().fill(CurrentTheme.accent).frame(width: 3, height: 30)
                        .position(x: inset + fraction(original) * width, y: 23)
                }
                if enabled || preview.wrappedValue != nil {
                    Capsule().fill(Color.primary).frame(width: 5, height: 34)
                        .position(x: inset + min(1, max(0, fraction(displayedValue))) * width, y: 23)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .debugHitArea()
                .gesture(DragGesture(minimumDistance: 0)
                .updating(preview) { event, draft, _ in
                    guard original != nil else { return }
                    draft = target(at: event.location.x, width: width)
                }
                .onChanged { _ in
                    guard original != nil else { return }
                    onEditingBegan()
                }
                .onEnded { event in
                    guard original != nil else { return }
                    onCommit(target(at: event.location.x, width: width))
                })
            .opacity(original == nil ? 0.4 : 1)
        }
        .frame(height: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放 BPM，每格 5")
        .accessibilityValue(valueDescription)
        .accessibilityAdjustableAction { direction in
            guard original != nil else { return }
            switch direction {
            case .increment: value = PlaybackTempo.snappedTarget(value + 5)
            case .decrement: value = PlaybackTempo.snappedTarget(value - 5)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("bpmRuler")
        .sensoryFeedback(.selection, trigger: displayedValue)
    }
    private func target(at x: CGFloat, width: CGFloat) -> Double {
        let position = min(1, max(0, (x - inset) / width))
        return PlaybackTempo.snappedTarget(PlaybackTempo.targetRange.lowerBound + position *
            (PlaybackTempo.targetRange.upperBound - PlaybackTempo.targetRange.lowerBound))
    }
    private var valueDescription: String {
        guard let original else { return "BPM 未识别" }
        return "\(PlaybackTempo.label(displayedValue)) BPM，原曲 \(PlaybackTempo.label(original)) BPM"
    }
}
