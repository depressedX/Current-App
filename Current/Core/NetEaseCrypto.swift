import Foundation
import CommonCrypto
import CryptoKit

/// Service wire protocol. Independent Swift implementation; not an authentication secret store.
enum NetEaseCrypto {
    static func weapi(_ payload: Data) throws -> [String: String] {
        let stage = try encrypt(payload, key: "0CoJUm6Qyw8W8jud", iv: "0102030405060708")
        let final = try encrypt(stage.base64EncodedData(), key: "current2026abcDE", iv: "0102030405060708")
        return ["params": final.base64EncodedString(), "encSecKey": "208ab36be1e7d9fa04b1f7678104e3246ac3512c856a19f05e1390b056214c1ac51c2297d2678c9fd39d28523dfad3232d358781044a6c3536aafc68b5db9c8f59012b7be2e26dab9084774d721ac3c6f7dd7b40c7063f30c8e4b00f8ee9dd7741df8508ba57444c3cded2ebba284a3fb1717054dc5706324f0410040a286cc3"]
    }
    static func eapi(path: String, payload: Data) throws -> [String: String] {
        let json = String(decoding: payload, as: UTF8.self)
        let digest = Insecure.MD5.hash(data: Data("nobody/api\(path)use\(json)md5forencrypt".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let text = "/api\(path)-36cd479b6b5-\(json)-36cd479b6b5-\(digest)"
        let encrypted = try encrypt(Data(text.utf8), key: "e82ckenh8dichen8", iv: nil)
        return ["params": encrypted.map { String(format: "%02X", $0) }.joined()]
    }
    private static func encrypt(_ input: Data, key: String, iv: String?) throws -> Data {
        let bytes = Array(input), keyBytes = Array(key.utf8), ivBytes = Array((iv ?? "").utf8)
        var output = [UInt8](repeating: 0, count: bytes.count + kCCBlockSizeAES128)
        var length = 0
        let options = CCOptions(kCCOptionPKCS7Padding | (iv == nil ? kCCOptionECBMode : 0))
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                             keyBytes, keyBytes.count, iv == nil ? nil : ivBytes,
                             bytes, bytes.count, &output, output.count, &length)
        guard status == kCCSuccess else { throw CurrentError.message("请求加密失败。") }
        return Data(output.prefix(length))
    }
    static func form(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
}
