import SwiftUI

struct LyricsSearchView: View {
    @EnvironmentObject private var pool: SongPoolStore
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var searched = ""
    @State private var results: LyricsSearchResults?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var searching = false
    @FocusState private var focused: Bool
    private var matches: [LyricsSearchMatch] {
        results?.matches.filter { match in pool.songs.contains { $0.id == match.id } } ?? []
    }
    var body: some View {
        CurrentPage {
            Text("\(pool.lyricsCount) 首歌曲可检索").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
            HStack(spacing: 12) {
                TextField("例如：分别、离别", text: $query).debugHitArea()
                    .font(CurrentTheme.TypeScale.body).submitLabel(.search).focused($focused)
                    .onSubmit { search() }.accessibilityIdentifier("lyricsQuery")
                Button("查找") { search() }
                    .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("searchLyrics")
            }.padding(16).background(CurrentTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            if searching { ProgressView("匹配歌词中") }
            if let failure { Text(failure).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted) }
            if let results {
                Text("“\(searched)”的候选").font(CurrentTheme.TypeScale.section)
                if results.unavailableCount > 0 {
                    Text("\(results.unavailableCount) 首索引无法读取，可在歌曲详情更新。")
                        .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                }
                if matches.isEmpty { Text("暂无可展示的结果").foregroundStyle(CurrentTheme.muted) }
                ForEach(matches) { match in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Artwork(track: match.track).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(match.track.title).font(CurrentTheme.TypeScale.emphasis)
                                Text(match.track.artist).font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                            }
                            Spacer()
                            Button("播放") { store.playLyrics(matches, selected: match.id, query: searched, account: pool.account) }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(match.lines.indices, id: \.self) { index in
                                Text(match.lines[index].text)
                                    .font(CurrentTheme.TypeScale.secondary).textSelection(.enabled)
                            }
                        }
                        HStack {
                            Text(match.source.title + time(match.lines.first?.second))
                            Spacer()
                            Text(String(format: "相似度 %.3f", match.similarity)).monospacedDigit()
                        }.font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
                    }.padding(.vertical, 12)
                    Divider()
                }
                Text("仅按歌词匹配，排序分数不代表准确概率。")
                    .font(CurrentTheme.TypeScale.caption).foregroundStyle(CurrentTheme.muted)
            } else if !searching {
                Text("按中文原词或网易云中文译词查找主题。")
                    .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                if pool.lyricsCount == 0 {
                    Button("补全歌词") { pool.indexMissingLyrics() }
                }
            }
        }
        .navigationTitle("搜歌词").navigationBarTitleDisplayMode(.inline)
        .onDisappear { task?.cancel() }
        .onChange(of: pool.account) { _, _ in task?.cancel(); results = nil; failure = nil; query = ""; searched = "" }
    }
    private func search() {
        guard !searching else { return }
        focused = false; failure = nil; results = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searched = text; searching = true
        task = Task { @MainActor in
            defer { searching = false }
            do { results = try await pool.searchLyrics(text) }
            catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
    private func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds <= 86_400 else { return "" }
        return " · \(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }
}
