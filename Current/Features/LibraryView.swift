import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showLogin: Bool
    var body: some View {
        CurrentPage {
            if store.listener != nil {
                HStack {
                    Text("我的歌单").font(CurrentTheme.TypeScale.section)
                    Spacer()
                    Button("刷新") { Task { await store.loadPlaylists() } }
                        .font(CurrentTheme.TypeScale.body).disabled(store.libraryLoading)
                }
                if store.libraryLoading { ProgressView("正在加载…").font(CurrentTheme.TypeScale.secondary) }
                if store.playlists.isEmpty && !store.libraryLoading {
                    Text("暂无歌单，下拉刷新试试。")
                        .font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
                }
                LazyVStack(spacing: CurrentTheme.Space.tiny) {
                    ForEach(store.playlists) { playlist in
                        HStack(spacing: CurrentTheme.Space.row) {
                            PlaylistArtwork(url: playlist.artwork)
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: CurrentTheme.Space.tiny) {
                                Text(playlist.title).font(CurrentTheme.TypeScale.emphasis).foregroundStyle(.primary).lineLimit(2)
                                Text("\(playlist.count) 首").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                            }
                            Spacer()
                        }.padding(8).contentShape(Rectangle())
                    }
                }
            } else if store.demoMode {
                HStack {
                    Text("演示曲库").font(CurrentTheme.TypeScale.section)
                    Spacer(); Text("8 首").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                }
                Text("原创短音频").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                LazyVStack(spacing: CurrentTheme.Space.group) {
                    ForEach(DemoCatalog.tracks) { track in
                        HStack(spacing: CurrentTheme.Space.row) {
                            Artwork(track: track).frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: CurrentTheme.Space.tiny) {
                                Text(track.title).font(CurrentTheme.TypeScale.emphasis)
                                Text("Current Studio").font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                            }
                            Spacer()
                            Text(track.duration.clock).font(CurrentTheme.TypeScale.caption).monospacedDigit().foregroundStyle(CurrentTheme.muted)
                        }
                    }
                }
                Divider()
                Button("连接网易云，使用我的歌单") { showLogin = true }.font(CurrentTheme.TypeScale.body)
            } else {
                VStack(alignment: .leading, spacing: CurrentTheme.Space.row) {
                    Text("你的音乐，在这里").font(CurrentTheme.TypeScale.section)
                    Text("连接网易云，带入收藏的歌单。")
                        .font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
                }
                PrimaryButton(title: "连接网易云") { showLogin = true }
            }
        }
        .navigationTitle("音乐库").navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.loadPlaylists() }
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
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
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
            aboutSection("选歌", "当前随机选歌。输入的文字会保留为歌单名称，尚未接入情绪、风格或 BPM 算法。")
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
