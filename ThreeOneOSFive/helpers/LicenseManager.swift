import Combine
import Foundation
import Security

@MainActor
final class LicenseManager: ObservableObject {
    static let accessKey = "AzTuT"

    @Published private(set) var expirationDate: Date?
    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var contactOwner: String?
    @Published var rememberKey = true

    private let service = "com.AzTuT.external-ios.activation"
    private let keyAccount = "license-key"
    private var lastAttemptAt: Date?

    init() {
        isActive = hasRememberedKey
    }

    var hasRememberedKey: Bool { string(for: keyAccount) == Self.accessKey }

    func beginLaunchSession() {
        isActive = hasRememberedKey
        message = isActive ? "已激活，可以直接使用" : "需要激活码 — 请输入访问密钥"
    }

    func activate(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        if let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < 1 {
            message = "请稍候再试"
            return
        }
        lastAttemptAt = Date()
        isBusy = true
        message = "正在验证激活码…"

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isBusy = false
            guard trimmed == Self.accessKey else {
                self.isActive = false
                self.message = "激活码无效"
                return
            }
            if self.rememberKey { self.save(Self.accessKey, for: self.keyAccount) }
            self.isActive = true
            self.message = "激活成功"
        }
    }

    func rememberedKey() -> String? { string(for: keyAccount) }

    func refresh() {
        isActive = hasRememberedKey
        message = isActive ? "已激活，可以直接使用" : "需要激活码 — 请输入访问密钥"
    }

    func deactivate() {
        delete(keyAccount)
        isActive = false
        message = "已从此设备移除激活"
    }

    private func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
