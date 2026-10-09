import Foundation
import XCTest
@testable import ItoKit

/// Pins our Noise to the cacophony vector. The Kotlin suite reads the same file.
final class NoiseVectorTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("vectors/noise_xx_25519_chachapoly_sha256.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func key(_ v: [String: Any], _ k: String) throws -> DhKey {
        try DhKey(privData: Data(hex: v[k] as! String)!)
    }

    func testMatchesCacophonyVector() throws {
        let v = try vector()
        let initiator = XXHandshake(initiator: true, s: try key(v, "init_static"),
                                    prologue: Data(hex: v["init_prologue"] as! String)!,
                                    fixedEphemeral: try key(v, "init_ephemeral"))
        let responder = XXHandshake(initiator: false, s: try key(v, "resp_static"),
                                    prologue: Data(hex: v["resp_prologue"] as! String)!,
                                    fixedEphemeral: try key(v, "resp_ephemeral"))
        let messages = v["messages"] as! [[String: String]]
        for i in 0..<3 {
            let (w, r) = i % 2 == 0 ? (initiator, responder) : (responder, initiator)
            let payload = Data(hex: messages[i]["payload"]!)!
            let ct = try w.writeMessage(payload)
            XCTAssertEqual(ct.hex, messages[i]["ciphertext"], "handshake message \(i)")
            XCTAssertEqual(try r.readMessage(ct), payload)
        }
        XCTAssertEqual(initiator.handshakeHash.hex, v["handshake_hash"] as? String)
        XCTAssertEqual(responder.handshakeHash.hex, v["handshake_hash"] as? String)
        XCTAssertEqual(initiator.remoteStatic, try key(v, "resp_static").pub)

        let ti = try initiator.split(), tr = try responder.split()
        for i in 3..<messages.count {
            let (tx, rx) = i % 2 == 0 ? (ti, tr) : (tr, ti)
            let payload = Data(hex: messages[i]["payload"]!)!
            let ct = try tx.seal(payload)
            XCTAssertEqual(ct.hex, messages[i]["ciphertext"], "transport message \(i)")
            XCTAssertEqual(try rx.open(ct), payload)
        }
    }

    func testTamperedTransportIsRejected() throws {
        let a = XXHandshake(initiator: true, s: DhKey()), b = XXHandshake(initiator: false, s: DhKey())
        _ = try b.readMessage(try a.writeMessage())
        _ = try a.readMessage(try b.writeMessage())
        _ = try b.readMessage(try a.writeMessage())
        var ct = try a.split().seal(Data("hi".utf8))
        ct[0] ^= 1
        XCTAssertThrowsError(try b.split().open(ct))
    }
}
