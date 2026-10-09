import CryptoKit
import Foundation

/// Numeric comparison with a commitment, run inside the Noise channel.
/// Same construction as android/link/Pairing.kt, which has the full reasoning:
///   phone -> pair.commit  C = SHA256("ito/commit" || Np)
///   mac   -> pair.nonce   Nm
///   phone -> pair.reveal  Np   (we check C)
///   code  =  SHA256("ito/sas" || h || Nm || Np) mod 10^6
public enum Sas {
    public static func nonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no randomness")
        return Data(bytes)
    }

    public static func commit(_ nonce: Data) -> Data { sha256(Data("ito/commit".utf8), nonce) }

    public static func code(handshakeHash: Data, macNonce: Data, phoneNonce: Data) -> String {
        let d = sha256(Data("ito/sas".utf8), handshakeHash, macNonce, phoneNonce)
        var v: UInt64 = 0
        for b in d.prefix(8) { v = (v << 8) | UInt64(b) }
        return String(format: "%06llu", v % 1_000_000)
    }

    /// The fingerprint the phone advertises over mDNS and shows in hello.
    public static func fingerprint(_ pub: Data) -> String { String(sha256(pub).hex.prefix(8)) }
}
