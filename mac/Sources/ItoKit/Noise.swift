import CryptoKit
import Foundation

// Noise_XX_25519_ChaChaPoly_SHA256 from the Noise spec (revision 34) on CryptoKit.
// The Kotlin side is the same spec on JCA; both are pinned to the cacophony
// vector in /vectors so they cannot drift apart silently.

public let noiseProtocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
public let noisePrologue = Data("ito/1".utf8)

public enum NoiseError: Error {
    case notOurTurn, shortMessage, notComplete, nonceExhausted
}

public struct DhKey {
    public let priv: Curve25519.KeyAgreement.PrivateKey
    public var pub: Data { priv.publicKey.rawRepresentation }
    public var privData: Data { priv.rawRepresentation }

    public init(_ priv: Curve25519.KeyAgreement.PrivateKey = .init()) { self.priv = priv }
    public init(privData: Data) throws { priv = try .init(rawRepresentation: privData) }

    func dh(_ remote: Data) throws -> Data {
        let secret = try priv.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: remote))
        return secret.withUnsafeBytes { Data($0) }
    }
}

func sha256(_ parts: Data...) -> Data {
    var h = SHA256()
    parts.forEach { h.update(data: $0) }
    return Data(h.finalize())
}

private func hmac(_ key: Data, _ parts: Data...) -> Data {
    var m = HMAC<SHA256>(key: SymmetricKey(data: key))
    parts.forEach { m.update(data: $0) }
    return Data(m.finalize())
}

private func hkdf2(_ ck: Data, _ ikm: Data) -> (Data, Data) {
    let temp = hmac(ck, ikm)
    let out1 = hmac(temp, Data([1]))
    let out2 = hmac(temp, out1, Data([2]))
    return (out1, out2)
}

public final class CipherState {
    private var k: SymmetricKey?
    private var n: UInt64 = 0

    init(_ key: Data? = nil) { k = key.map { SymmetricKey(data: $0) } }

    var hasKey: Bool { k != nil }

    func initializeKey(_ key: Data) {
        k = SymmetricKey(data: key)
        n = 0
    }

    private func nonce() throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    func encrypt(_ ad: Data, _ pt: Data) throws -> Data {
        guard let k else { return pt }
        guard n != .max else { throw NoiseError.nonceExhausted }
        let box = try ChaChaPoly.seal(pt, using: k, nonce: nonce(), authenticating: ad)
        n += 1
        // ciphertext is a slice of the sealed box; rebase so callers can index from 0.
        var out = Data(box.ciphertext)
        out.append(box.tag)
        return out
    }

    // A failed open throws before the counter moves, per the spec.
    func decrypt(_ ad: Data, _ ct: Data) throws -> Data {
        guard let k else { return ct }
        guard n != .max else { throw NoiseError.nonceExhausted }
        guard ct.count >= 16 else { throw NoiseError.shortMessage }
        let box = try ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: ct.prefix(ct.count - 16), tag: ct.suffix(16))
        let pt = try ChaChaPoly.open(box, using: k, authenticating: ad)
        n += 1
        return pt
    }
}

private final class SymmetricState {
    var h: Data
    var ck: Data
    let cs = CipherState()

    init() {
        let name = Data(noiseProtocolName.utf8)
        h = name.count <= 32 ? name + Data(count: 32 - name.count) : sha256(name)
        ck = h
    }

    func mixKey(_ ikm: Data) {
        let (a, b) = hkdf2(ck, ikm)
        ck = a
        cs.initializeKey(b)
    }

    func mixHash(_ data: Data) { h = sha256(h, data) }

    func encryptAndHash(_ pt: Data) throws -> Data {
        let ct = try cs.encrypt(h, pt)
        mixHash(ct)
        return ct
    }

    func decryptAndHash(_ ct: Data) throws -> Data {
        let pt = try cs.decrypt(h, ct)
        mixHash(ct)
        return pt
    }

    func split() -> (CipherState, CipherState) {
        let (a, b) = hkdf2(ck, Data())
        return (CipherState(a), CipherState(b))
    }
}

/// The two directions of an established session. Not thread-safe; callers serialize.
public final class Transport {
    private let tx: CipherState
    private let rx: CipherState
    init(tx: CipherState, rx: CipherState) { self.tx = tx; self.rx = rx }
    public func seal(_ pt: Data) throws -> Data { try tx.encrypt(Data(), pt) }
    public func open(_ ct: Data) throws -> Data { try rx.decrypt(Data(), ct) }
}

/// XX:  -> e
///      <- e, ee, s, es
///      -> s, se
/// `fixedEphemeral` exists for the test vector only.
public final class XXHandshake {
    private let initiator: Bool
    private let s: DhKey
    private let fixedEphemeral: DhKey?
    private let ss = SymmetricState()
    private var e: DhKey?
    private var re: Data?
    private var step = 0

    /// Known after message 2 (initiator) or 3 (responder).
    public private(set) var remoteStatic: Data?

    public init(initiator: Bool, s: DhKey, prologue: Data = noisePrologue, fixedEphemeral: DhKey? = nil) {
        self.initiator = initiator
        self.s = s
        self.fixedEphemeral = fixedEphemeral
        ss.mixHash(prologue)
    }

    public var isComplete: Bool { step == 3 }
    /// Valid once complete: identical on both ends, binds everything exchanged.
    public var handshakeHash: Data { ss.h }
    private var myTurn: Bool { (step % 2 == 0) == initiator }

    public func writeMessage(_ payload: Data = Data()) throws -> Data {
        guard !isComplete, myTurn else { throw NoiseError.notOurTurn }
        var out = Data()
        switch step {
        case 0:
            out += writeE()
        case 1:
            out += writeE()
            ss.mixKey(try e!.dh(re!))                 // ee
            out += try ss.encryptAndHash(s.pub)       // s
            ss.mixKey(try s.dh(re!))                  // es (responder side)
        default:
            out += try ss.encryptAndHash(s.pub)       // s
            ss.mixKey(try s.dh(re!))                  // se (initiator side)
        }
        out += try ss.encryptAndHash(payload)
        step += 1
        return out
    }

    public func readMessage(_ message: Data) throws -> Data {
        guard !isComplete, !myTurn else { throw NoiseError.notOurTurn }
        let msg = Data(message)
        var off = 0
        func take(_ n: Int) throws -> Data {
            guard msg.count >= off + n else { throw NoiseError.shortMessage }
            defer { off += n }
            return msg.subdata(in: off..<(off + n))
        }
        switch step {
        case 0:
            readE(try take(32))
        case 1:
            readE(try take(32))
            ss.mixKey(try e!.dh(re!))                         // ee
            remoteStatic = try ss.decryptAndHash(try take(48)) // s
            ss.mixKey(try e!.dh(remoteStatic!))               // es (initiator side)
        default:
            remoteStatic = try ss.decryptAndHash(try take(48)) // s
            ss.mixKey(try e!.dh(remoteStatic!))               // se (responder side)
        }
        let payload = try ss.decryptAndHash(msg.subdata(in: off..<msg.count))
        step += 1
        return payload
    }

    public func split() throws -> Transport {
        guard isComplete else { throw NoiseError.notComplete }
        let (c1, c2) = ss.split()
        return initiator ? Transport(tx: c1, rx: c2) : Transport(tx: c2, rx: c1)
    }

    private func writeE() -> Data {
        let key = fixedEphemeral ?? DhKey()
        e = key
        ss.mixHash(key.pub)
        return key.pub
    }

    private func readE(_ pub: Data) {
        re = pub
        ss.mixHash(pub)
    }
}

public extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
