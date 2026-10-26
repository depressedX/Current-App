import SwiftUI

/// A small, semantic system shared by every screen. Colors follow system appearance.
enum CurrentTheme {
    static let background = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let accent = Color(red: 0.925, green: 0.286, blue: 0.286)
    static let accentDeep = Color(red: 0.788, green: 0.161, blue: 0.161)
    static let muted = Color.secondary
    static let accentGradient = LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    enum TypeScale {
        static let title = Font.system(.title, design: .default).weight(.bold)
        static let section = Font.system(.title3, design: .default).weight(.semibold)
        static let body = Font.system(.subheadline, design: .default)
        static let emphasis = body.weight(.semibold)
        static let secondary = Font.system(.footnote, design: .default)
        static let caption = Font.system(.caption, design: .default)
    }
    enum Icon {
        static let disclosure = Font.system(size: 12, weight: .medium)
        static let status = Font.system(size: 14, weight: .regular)
        static let selection = Font.system(size: 16, weight: .semibold)
        static let standard = Font.system(size: 18, weight: .regular)
        static let control = Font.system(size: 22, weight: .regular)
        static let avatar = Font.system(size: 24, weight: .regular)
        static let play = Font.system(size: 28, weight: .regular)
    }
    enum Space {
        static let tiny: CGFloat = 4
        static let small: CGFloat = 8
        static let row: CGFloat = 12
        static let group: CGFloat = 16
        static let page: CGFloat = 24
        static let section: CGFloat = 32
    }
    enum Radius {
        static let small: CGFloat = 6
        static let standard: CGFloat = 8
        static let card: CGFloat = 12
        static let panel: CGFloat = 20
    }
    enum Layout {
        static let readableWidth: CGFloat = 640
        static let artwork: CGFloat = 48
        static let control: CGFloat = 44
    }
    enum Motion {
        static let press = Animation.easeOut(duration: 0.15)
        static let change = Animation.easeInOut(duration: 0.25)
    }
    static func gradient(_ index: Int) -> LinearGradient {
        let colors: [[Color]] = [
            [Color(red: 0.39, green: 0.54, blue: 0.50), Color(red: 0.15, green: 0.28, blue: 0.30)],
            [Color(red: 0.70, green: 0.46, blue: 0.36), Color(red: 0.33, green: 0.28, blue: 0.35)],
            [Color(red: 0.44, green: 0.46, blue: 0.65), Color(red: 0.21, green: 0.25, blue: 0.39)],
            [Color(red: 0.70, green: 0.46, blue: 0.52), Color(red: 0.36, green: 0.24, blue: 0.33)]
        ]
        return LinearGradient(colors: colors[abs(index % colors.count)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct CurrentPage<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CurrentTheme.Space.page, content: content)
                .frame(maxWidth: CurrentTheme.Layout.readableWidth, alignment: .leading)
                .padding(CurrentTheme.Space.page)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(CurrentTheme.background)
        .font(CurrentTheme.TypeScale.body)
        .lineSpacing(4)
        .foregroundStyle(.primary)
    }
}

struct Artwork: View {
    let track: Track
    var radius: CGFloat = CurrentTheme.Radius.standard
    var pixels = 160
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CurrentTheme.gradient(track.id)
                if let url = track.artwork {
                    CachedArtwork(url: ArtworkCache.url(url, pixels: pixels)) { abstractArt }
                } else { abstractArt }
            }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
    private var abstractArt: some View {
        GeometryReader { geo in
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: geo.size.width * 0.09)
                    .frame(width: geo.size.width * 0.72).offset(x: geo.size.width * 0.16, y: -geo.size.height * 0.12)
                Circle().fill(.white.opacity(0.10)).frame(width: geo.size.width * 0.9)
                    .offset(x: -geo.size.width * 0.28, y: geo.size.height * 0.38)
            }.frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Real playlist artwork, with a neutral loading/missing state rather than invented colors.
struct PlaylistArtwork: View {
    let url: URL?
    var body: some View {
        GeometryReader { geometry in
            CachedArtwork(url: ArtworkCache.url(url, pixels: 160)) {
                ZStack {
                    CurrentTheme.surface
                    Image(systemName: "music.note.list")
                        .font(CurrentTheme.Icon.standard).foregroundStyle(CurrentTheme.muted)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: CurrentTheme.Radius.standard, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var busy = false
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: CurrentTheme.Space.small) {
                if busy { ProgressView().tint(.white) }
                else if let symbol { Image(systemName: symbol).font(CurrentTheme.TypeScale.body.weight(.semibold)) }
                Text(title).font(CurrentTheme.TypeScale.emphasis)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.white)
            .background(enabled && !busy ? AnyShapeStyle(CurrentTheme.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.28)), in: Capsule())
        }.buttonStyle(CurrentPressStyle()).disabled(busy)
    }
}

struct CurrentPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : CurrentTheme.Motion.press, value: configuration.isPressed)
    }
}

struct CurrentRowStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed || hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: CurrentTheme.Radius.standard))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : CurrentTheme.Motion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : CurrentTheme.Motion.press, value: hovering)
    }
}

extension Double {
    var clock: String { guard isFinite else { return "0:00" }; return "\(Int(max(0, self)) / 60):\(String(format: "%02d", Int(max(0, self)) % 60))" }
}

/// Two explicit, equally reachable preference actions; never a streaming-service favorite.
struct FeedbackChoiceButton: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: CurrentTheme.Space.small) {
                Image(systemName: symbol).font(CurrentTheme.Icon.standard)
                Text(title).font(CurrentTheme.TypeScale.emphasis)
            }
            .foregroundStyle(selected ? CurrentTheme.accent : Color.primary)
            .frame(minWidth: 112, minHeight: 44)
            .padding(.horizontal, CurrentTheme.Space.row)
            .background(selected ? CurrentTheme.accent.opacity(0.09) : Color.clear, in: Capsule())
            .animation(reduceMotion ? nil : CurrentTheme.Motion.press, value: selected)
            .contentShape(RoundedRectangle(cornerRadius: CurrentTheme.Radius.card))
        }.buttonStyle(CurrentPressStyle())
    }
}
