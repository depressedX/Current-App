import Foundation

@MainActor
final class NetEaseAPI {
    private var cookies: [String: String]
    private var epoch = UUID()
    private let ephemeral: Bool
    private let session: URLSession
    init(ephemeral: Bool = false, configuration: URLSessionConfiguration? = nil) {
        self.ephemeral = ephemeral
        cookies = ephemeral ? [:] : KeychainStore.load()
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }
    var hasCredentials: Bool { cookies["MUSIC_U"] != nil }
    func clear() { epoch = UUID(); cookies = [:]; if !ephemeral { KeychainStore.clear() } }
    func qrKey() async throws -> String {
        let body = try await request("/login/qrcode/unikey", ["type": 1])
        guard let key = body["unikey"] as? String else { throw CurrentError.message("未能生成登录二维码，请重试。") }
        return key
    }
    func qrCheck(_ key: String) async throws -> Int {
        let body = try await request("/login/qrcode/client/login", ["key": key, "type": 1], accepted: [800,801,802,803])
        return body["code"] as? Int ?? 800
    }
    func profile() async throws -> Listener {
        let body = try await request("/w/nuser/account/get")
        guard let p = body["profile"] as? [String: Any], let id = p["userId"] as? Int else { throw CurrentError.expired }
        return Listener(id: id, name: p["nickname"] as? String ?? "网易云用户", avatar: (p["avatarUrl"] as? String).flatMap(URL.init))
    }
    func logout() async {
        // Clear locally first. Detached credentials are used only for this revocation request.
        let old = cookies
        clear()
        _ = try? await request("/logout", cookieOverride: old, absorb: false)
    }
    func playlists(uid: Int) async throws -> [UserPlaylist] {
        let body = try await request("/user/playlist", ["uid": uid, "limit": 100, "offset": 0])
        return (body["playlist"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["id"] as? Int else { return nil }
            return UserPlaylist(id: id, title: p["name"] as? String ?? "歌单", count: p["trackCount"] as? Int ?? 0,
                                artwork: Self.artworkURL(p["coverImgUrl"] as? String ?? p["picUrl"] as? String))
        }
    }
    func tracks(playlistID: Int, limit: Int? = 60) async throws -> [Track] {
        let body = try await request("/v6/playlist/detail", ["id": playlistID, "n": 100, "s": 0])
        let playlist = body["playlist"] as? [String: Any] ?? [:]
        let refs = playlist["trackIds"] as? [[String: Any]] ?? []
        let allIDs = refs.compactMap { $0["id"] as? Int }
        let ids = limit.map { Array(allIDs.prefix(max(0, $0))) } ?? allIDs
        if ids.isEmpty { return Self.parseTracks(playlist["tracks"] as? [[String: Any]] ?? []) }
        var tracks: [Track] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            let detail = try await request("/v3/song/detail", ["c": String(data: try JSONSerialization.data(withJSONObject: batch.map { ["id": $0] }), encoding: .utf8)!])
            tracks.append(contentsOf: Self.parseTracks(detail["songs"] as? [[String: Any]] ?? []))
        }
        return tracks
    }

    nonisolated static func artworkURL(_ text: String?) -> URL? {
        guard let text, var parts = URLComponents(string: text), parts.host != nil else { return nil }
        if parts.scheme?.lowercased() == "http" { parts.scheme = "https" }
        guard parts.scheme?.lowercased() == "https" else { return nil }
        return parts.url
    }
    static func parseTracks(_ values: [[String: Any]]) -> [Track] {
        values.compactMap { song in
            guard let id = song["id"] as? Int else { return nil }
            let album = song["al"] as? [String: Any] ?? [:]
            let artists = song["ar"] as? [[String: Any]] ?? []
            return Track(id: id, title: song["name"] as? String ?? "未知歌曲",
                         artist: artists.compactMap { $0["name"] as? String }.joined(separator: " / "),
                         album: album["name"] as? String ?? "", artwork: Self.artworkURL(album["picUrl"] as? String),
                         duration: ((song["dt"] as? NSNumber)?.doubleValue ?? 0) / 1000, demoIndex: nil)
        }
    }
    func songBPM(id: Int) async throws -> Double? {
        let body = try await request("/song/play/about/block/page", ["songId": id], eapi: true, timeout: 8)
        return Self.parseWikiBPM(body)
    }
    nonisolated static func parseWikiBPM(_ body: [String: Any]) -> Double? {
        guard let data = body["data"] as? [String: Any], let blocks = data["blocks"] as? [[String: Any]] else { return nil }
        for block in blocks {
            for creative in block["creatives"] as? [[String: Any]] ?? [] {
                let ui = creative["uiElement"] as? [String: Any] ?? [:]
                let title = (ui["mainTitle"] as? [String: Any])?["title"] as? String ?? ""
                let kind = creative["creativeType"] as? String ?? ""
                guard kind.lowercased() == "bpm" || title.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "BPM" else { continue }
                for link in ui["textLinks"] as? [[String: Any]] ?? [] {
                    guard let text = link["text"] as? String else { continue }
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value.range(of: #"^\d{1,3}(?:\.\d{1,2})?\s*(?:BPM)?$"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                    let numeric = value.replacingOccurrences(of: "BPM", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let bpm = Double(numeric), bpm.isFinite, (20...400).contains(bpm) { return bpm }
                }
            }
        }
        return nil
    }
    func playbackURL(id: Int) async throws -> URL {
        let body = try await request("/song/enhance/player/url/v1", ["ids": "[\(id)]", "level": "standard", "encodeType": "aac"], eapi: true)
        guard let song = (body["data"] as? [[String: Any]])?.first else { throw CurrentError.message("暂无播放资源。") }
        guard song["freeTrialInfo"] == nil || song["freeTrialInfo"] is NSNull else {
            throw CurrentError.message("这首歌仅提供试听，请在网易云确认账号播放权限。")
        }
        guard let text = song["url"] as? String, var parts = URLComponents(string: text) else {
            throw CurrentError.message("这首歌暂不可播放，可以换一首。")
        }
        if parts.scheme == "http" { parts.scheme = "https" }
        guard let url = parts.url, url.scheme == "https" else { throw CurrentError.message("播放地址无效。") }
        return url
    }
    func request(_ path: String, _ payload: [String: Any] = [:], eapi: Bool = false,
                 accepted: Set<Int> = [200], cookieOverride: [String: String]? = nil, absorb: Bool = true, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let span = UUID(), began = Date(), operation = LogOperation.api(path)
        var transportStatus: Int?, businessCode: Int?
        AppLog.shared.record(.api, .started, operation: operation, span: span)
        do {
            let generation = epoch
            var body = payload
            let jar = cookieOverride ?? cookies
            body["csrf_token"] = jar["__csrf"] ?? ""
            if eapi {
                var header = jar
                header["os"] = "pc"; header["appver"] = "3.1.17"
                body["header"] = header
            }
            let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let fields = try eapi ? NetEaseCrypto.eapi(path: path, payload: json) : NetEaseCrypto.weapi(json)
            let host = eapi ? "https://interface.music.163.com/eapi" : "https://music.163.com/weapi"
            let url = URL(string: host + path)!
            var request = URLRequest(url: url)
            if let timeout { request.timeoutInterval = timeout }
            request.httpMethod = "POST"; request.httpBody = NetEaseCrypto.form(fields)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            var requestCookies = jar
            requestCookies["os"] = "pc"; requestCookies["appver"] = "3.1.17"
            request.setValue(requestCookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard generation == epoch else { throw CancellationError() }
            transportStatus = (response as? HTTPURLResponse)?.statusCode
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CurrentError.message("网易云服务暂不可用，请稍后重试。")
            }
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CurrentError.message("服务返回了无法识别的数据。")
            }
            let code = value["code"] as? Int ?? 200
            businessCode = code
            if code == 301 { throw CurrentError.expired }
            guard accepted.contains(code) else {
                throw CurrentError.message(value["message"] as? String ?? value["msg"] as? String ?? "请求失败（\(code)）。")
            }
            if absorb {
                let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                    result[String(describing: pair.key)] = String(describing: pair.value)
                }
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
                    if !cookie.value.isEmpty { cookies[cookie.name] = cookie.value }
                }
                if !ephemeral, cookies["MUSIC_U"] != nil { try KeychainStore.save(cookies) }
            }
            AppLog.shared.record(.api, .succeeded, operation: operation, span: span,
                                 status: transportStatus, serviceCode: businessCode, elapsed: Date().timeIntervalSince(began))
            return value
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            AppLog.shared.record(.api, cancelled ? .cancelled : .failed, level: cancelled ? .info : .error,
                                 operation: operation, span: span, status: transportStatus, serviceCode: businessCode,
                                 elapsed: Date().timeIntervalSince(began), error: error)
            throw error
        }
    }
}
