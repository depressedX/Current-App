import Foundation
import Security

enum KeychainStore {
    private static let service = "com.liupenghao.current.netease"
    static func load() -> [String: String] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    static func save(_ cookies: [String: String]) throws {
        let data = try JSONEncoder().encode(cookies)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw CurrentError.message("无法安全保存登录状态（\(added)）") }
        } else if status != errSecSuccess {
            throw CurrentError.message("无法更新登录状态（\(status)）")
        }
    }
    static func clear() { SecItemDelete(baseQuery as CFDictionary) }
    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "cookies"]
    }
}

/// Song-level resource decisions. Transport/server/decoder errors remain retryable.
enum TrackUnavailability: String, Codable {
    case noResource, trialOnly
    var message: String {
        switch self {
        case .noResource: return "网易云暂无可用音源，可能已下架或受地区限制；已排除歌单生成与播放。"
        case .trialOnly: return "网易云仅提供试听，当前账号无完整播放权限；已排除歌单生成与播放。"
        }
    }
}

enum CurrentError: LocalizedError {
    case message(String)
    case expired
    case unavailable(TrackUnavailability)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .expired: return "登录已过期，请重新扫码。"
        case .unavailable(let reason): return reason.message
        }
    }
}


extension CurrentError: SafeLogError {
    var logFailure: LogFailure {
        switch self {
        case .expired: return .authExpired
        case .message, .unavailable: return .application
        }
    }
}
