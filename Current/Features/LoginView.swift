import SwiftUI
import CoreImage.CIFilterBuiltins

struct LoginView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var key: String?
    @State private var status = "正在准备二维码…"
    @State private var error: String?
    @State private var loading = false
    @State private var refresh = UUID()
    var body: some View {
        NavigationStack {
            CurrentPage {
                VStack(alignment: .leading, spacing: CurrentTheme.Space.small) {
                    Text("扫码登录").font(CurrentTheme.TypeScale.title)
                    Text("使用网易云音乐 App 扫描二维码。")
                        .font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
                }
                VStack(spacing: CurrentTheme.Space.group) {
                    ZStack {
                        RoundedRectangle(cornerRadius: CurrentTheme.Radius.card).fill(.white)
                        if let key, let image = qrImage(key: key) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().padding(16)
                        } else { ProgressView().tint(.black) }
                    }
                    .frame(width: 220, height: 220)
                    .overlay(RoundedRectangle(cornerRadius: CurrentTheme.Radius.card).stroke(.black.opacity(0.06)))
                    Text(status).font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
                    Button("刷新二维码") { refresh = UUID() }
                        .font(CurrentTheme.TypeScale.body).disabled(loading)
                }.frame(maxWidth: .infinity).padding(.vertical, CurrentTheme.Space.group)
                DisclosureGroup("同一台手机怎么扫码？") {
                    Text("截图二维码，在网易云扫一扫中从相册选择，确认后返回 Current。")
                        .font(CurrentTheme.TypeScale.secondary).foregroundStyle(CurrentTheme.muted)
                        .lineSpacing(4).padding(.top, 8)
                }.font(CurrentTheme.TypeScale.body)
                if let error {
                    Text(error).font(CurrentTheme.TypeScale.secondary).foregroundStyle(.red)
                }
                if store.listener == nil {
                    Button("先体验一下") { store.enterDemo(); dismiss() }
                        .font(CurrentTheme.TypeScale.body).foregroundStyle(CurrentTheme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("网易云音乐").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .task(id: refresh) { await poll() }
        }
    }
    @MainActor private func poll() async {
        key = nil; error = nil; loading = true; status = "正在准备二维码…"
        do {
            let value = try await store.api.qrKey()
            try Task.checkCancellation(); key = value; loading = false
            for _ in 0..<100 {
                let code: Int
                do { code = try await store.api.qrCheck(value) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    status = "连接中断，正在重试…"
                    try await Task.sleep(for: .seconds(3))
                    continue
                }
                switch code {
                case 800: status = "二维码已过期"; return
                case 801: status = "等待扫码"
                case 802: status = "已扫码，请在网易云确认"
                case 803:
                    status = "正在连接你的账号…"
                    try await store.finishLogin()
                    dismiss(); return
                default: break
                }
                try await Task.sleep(for: .seconds(2))
            }
            status = "二维码已过期，请刷新"
        } catch is CancellationError {} catch {
            self.error = error.localizedDescription; status = "连接暂时中断，请刷新重试"
        }
        loading = false
    }
    private func qrImage(key: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("https://music.163.com/login?codekey=\(key)".utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
