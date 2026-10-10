import Foundation
import Security

/// The Mac's Noise key and the one phone it trusts, both in the login Keychain.
/// The private key never touches a file.
public final class Identity {
    public struct Phone: Codable, Equatable {
        public var key: Data
        public var name: String
        public var fingerprint: String { Sas.fingerprint(key) }
    }

    private let service: String
    private var memory: [String: Data]?

    /// `inMemory` is for tests: nothing touches the Keychain.
    public init(service: String = "app.ito.mac", inMemory: Bool = false) {
        self.service = service
        memory = inMemory ? [:] : nil
    }

    public lazy var staticKey: DhKey = {
        if let raw = read("mac-static"), let key = try? DhKey(privData: raw) { return key }
        let key = DhKey()
        write("mac-static", key.privData)
        return key
    }()

    /// Read from the Keychain once, then served from memory: a Keychain read is a round
    /// trip to securityd, and the first one after an app update can sit behind a password
    /// prompt. Thread-safe; only the very first read can block.
    public var phone: Phone? {
        get {
            lock.lock(); defer { lock.unlock() }
            if !phoneLoaded {
                cachedPhone = read("phone").flatMap { try? JSONDecoder().decode(Phone.self, from: $0) }
                phoneLoaded = true
            }
            return cachedPhone
        }
        set {
            lock.lock(); defer { lock.unlock() }
            if let newValue, let data = try? JSONEncoder().encode(newValue) { write("phone", data) } else { delete("phone") }
            cachedPhone = newValue
            phoneLoaded = true
        }
    }

    private let lock = NSLock()
    private var cachedPhone: Phone?
    private var phoneLoaded = false

    // MARK: Keychain

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> Data? {
        if let memory { return memory[account] }
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private func write(_ account: String, _ data: Data) {
        if memory != nil { memory![account] = data; return }
        delete(account)
        var q = base(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrLabel as String] = "ito (\(account))"
        SecItemAdd(q as CFDictionary, nil)
    }

    private func delete(_ account: String) {
        if memory != nil { memory![account] = nil; return }
        SecItemDelete(base(account) as CFDictionary)
    }
}
