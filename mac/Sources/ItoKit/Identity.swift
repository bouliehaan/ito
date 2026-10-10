import Foundation
import Security

/// The Mac's Noise key and the one phone it trusts, both in the login Keychain.
/// The private key never touches a file.
/// Thread-safe: every mutable field sits behind a lock.
public final class Identity: @unchecked Sendable {
    public struct Phone: Codable, Equatable {
        public var key: Data
        public var name: String
        public var fingerprint: String { Sas.fingerprint(key) }
    }

    public struct KeychainRefused: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            "the Keychain didn't hand over ito's keys (\(status)). quit and reopen ito, enter your Mac password and choose Always Allow."
        }
    }

    private let service: String
    private var memory: [String: Data]?

    /// `inMemory` is for tests: nothing touches the Keychain.
    public init(service: String = "app.ito.mac", inMemory: Bool = false) {
        self.service = service
        memory = inMemory ? [:] : nil
    }

    /// Set when the Keychain refused a read: the password prompt was denied, or could not
    /// be shown. Cleared by the next read that works.
    public var refused: KeychainRefused? {
        lock.lock(); defer { lock.unlock() }
        return lastRefusal
    }

    /// The phone as last read, without touching the Keychain, so it never waits behind a
    /// password prompt. Safe on the main thread.
    public var knownPhone: Phone? {
        lock.lock(); defer { lock.unlock() }
        return cachedPhone
    }

    /// Both reads up front, so the password prompts after an update come together at launch
    /// rather than one now and one at the first handshake.
    public func preload() {
        _ = phone
        _ = try? staticKey()
    }

    /// The Mac's Noise key, made on the very first run. A Keychain that refuses to answer is
    /// an error, never a reason to make a new key: that would silently unpair this Mac.
    public func staticKey() throws -> DhKey {
        reading.lock(); defer { reading.unlock() }
        if let key = cached({ cachedKey }) { return key }
        let key: DhKey
        switch read("mac-static") {
        case .found(let raw):
            key = try DhKey(privData: raw)
        case .missing:
            key = DhKey()
            write("mac-static", key.privData)
        case .refused(let status):
            throw KeychainRefused(status: status)
        }
        cached { cachedKey = key }
        return key
    }

    /// Read from the Keychain once, then served from memory: a Keychain read is a round
    /// trip to securityd, and the first one after an app update can sit behind a password
    /// prompt. A refused read is not remembered, so the next access asks again.
    public var phone: Phone? {
        get {
            reading.lock(); defer { reading.unlock() }
            if cached({ phoneLoaded }) { return knownPhone }
            switch read("phone") {
            case .found(let data):
                let p = try? JSONDecoder().decode(Phone.self, from: data)
                cached { cachedPhone = p; phoneLoaded = true }
                return p
            case .missing:
                cached { cachedPhone = nil; phoneLoaded = true }
                return nil
            case .refused:
                return nil
            }
        }
        set {
            reading.lock(); defer { reading.unlock() }
            if let newValue, let data = try? JSONEncoder().encode(newValue) { write("phone", data) } else { delete("phone") }
            cached { cachedPhone = newValue; phoneLoaded = true }
        }
    }

    /// One Keychain call at a time; may be held across a password prompt.
    private let reading = NSLock()
    /// The values below; never held across a Keychain call.
    private let lock = NSLock()
    private var cachedPhone: Phone?
    private var phoneLoaded = false
    private var cachedKey: DhKey?
    private var lastRefusal: KeychainRefused?

    private func cached<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: Keychain

    private enum Read {
        case found(Data)
        case missing
        case refused(OSStatus)
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Called with `reading` held.
    private func read(_ account: String) -> Read {
        if let memory { return memory[account].map(Read.found) ?? .missing }
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess where out is Data:
            cached { lastRefusal = nil }
            return .found(out as! Data)
        case errSecItemNotFound:
            cached { lastRefusal = nil }
            return .missing
        default:
            cached { lastRefusal = KeychainRefused(status: status) }
            return .refused(status)
        }
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
