import Foundation
import Security

/// API Key 存储（CHAT-08 §4.2）：App 自建专属条目，创建者天然获得 ACL 访问权。
/// 命名空间与旧 service=dashvoice-key（Oracle 共用）完全隔离，不删除/不修改旧条目。
public enum KeychainStore {
    public static let service = "com.dashvoice2.app.credentials"
    public static let account = "asr.default"
    public static let label = "DashVoice ASR"

    public enum KeyError: Error, Equatable {
        case notFound
        case denied              // 用户取消/拒绝
        case interactionFailed   // 需要 UI 交互但不可呈现
        case internalError(OSStatus)
        var category: String {
            switch self {
            case .notFound: return "not_found"
            case .denied: return "denied"
            case .interactionFailed: return "interaction_not_allowed"
            case .internalError(let s): return "internal_\(s)"
            }
        }
    }

    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// 读自有条目（精确 identity 匹配）
    public static func read() throws -> String {
        var q = identity
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let d = item as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else {
                throw KeyError.notFound
            }
            return s
        case errSecItemNotFound: throw KeyError.notFound
        case errSecUserCanceled, errSecAuthFailed: throw KeyError.denied
        case errSecInteractionNotAllowed: throw KeyError.interactionFailed
        default: throw KeyError.internalError(status)
        }
    }

    /// 保存（Add → 若已存在则 Update），成功后**立即读回校验**（CHAT-08 §4.2 要求）
    @discardableResult
    public static func save(_ secret: String) throws -> String {
        let data = Data(secret.utf8)
        var attrs = identity
        attrs[kSecAttrLabel as String] = label
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(attrs as CFDictionary, nil)
        let status: OSStatus
        if added == errSecDuplicateItem {
            status = SecItemUpdate(identity as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        } else {
            status = added
        }
        guard status == errSecSuccess else { throw KeyError.internalError(status) }
        // 读回校验（不打印值/长度/摘要）
        let readBack = try read()
        guard readBack == secret else { throw KeyError.internalError(errSecInternalError) }
        return readBack
    }

    /// 删除仅限自有条目（精确 identity）
    @discardableResult
    public static func deleteOwned() -> Bool {
        SecItemDelete(identity as CFDictionary) == errSecSuccess
    }

    public static func exists() -> Bool {
        var q = identity
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
}
