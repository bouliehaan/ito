import Foundation
import Network
import XCTest
@testable import ItoKit

/// The Swift client against the Kotlin server, over a real socket: the two
/// Noise implementations, the pairing commitment, sync and group fan-out all
/// have to agree. Needs the fake phone built:
///   (cd android && ./gradlew :fakephone:installDist)
final class InteropTests: XCTestCase, LinkDelegate {
    private var states: [LinkClient.State] = []
    private var messages: [[String: Any]] = []
    private var onState: ((LinkClient.State) -> Void)?
    private var onMessage: (([String: Any]) -> Void)?

    func linkStateChanged(_ state: LinkClient.State) { states.append(state); onState?(state) }
    func linkReceived(_ message: [String: Any]) { messages.append(message); onMessage?(message) }
    func linkAudio(_ frame: Data) {}
    func linkFound(_ phones: [LinkClient.Found]) {}

    private var phone: Process?
    private var dir: URL!

    override func tearDown() {
        phone?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func startFakePhone(port: Int) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bin = root.appendingPathComponent("android/fakephone/build/install/fakephone/bin/fakephone")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw XCTSkip("fake phone not built: (cd android && ./gradlew :fakephone:installDist)")
        }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ito-interop-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = bin
        p.arguments = ["--port", "\(port)", "--auto", "--no-mdns", "--dir", dir.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardInput = Pipe()
        let ready = expectation(description: "fake phone up")
        var buffer = ""
        out.fileHandleForReading.readabilityHandler = { h in
            buffer += String(decoding: h.availableData, as: UTF8.self)
            if buffer.contains("fake phone on") { ready.fulfill(); h.readabilityHandler = nil }
        }
        try p.run()
        phone = p
        wait(for: [ready], timeout: 30)
    }

    func testPairSyncAndGroupSend() throws {
        let port = Int.random(in: 40000...50000)
        try startFakePhone(port: port)

        let identity = Identity(inMemory: true)
        let link = LinkClient(identity: identity)
        link.delegate = self
        link.start()

        // Pair: wait for the code, accept it, end up linked and pinned.
        let coded = expectation(description: "code shown")
        let linked = expectation(description: "linked")
        onState = { s in
            if case .pairing(let code?, _, false) = s {
                XCTAssertEqual(code.count, 6)
                coded.fulfill()
                link.confirmPairing(true)
            }
            if case .linked = s { linked.fulfill() }
        }
        link.pair(with: .init(name: "fake", fingerprint: nil, endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: UInt16(port))!)))
        wait(for: [coded, linked], timeout: 15)
        XCTAssertNotNil(identity.phone, "phone key pinned after pairing")

        // Sync.
        let synced = expectation(description: "synced")
        onMessage = { m in if m["t"] as? String == "synced" { synced.fulfill() } }
        link.send(["t": "sync", "sms": 0, "mms": 0, "calls": 0, "contacts": ""])
        wait(for: [synced], timeout: 15)
        let smsRows = messages.filter { $0["t"] as? String == "sms" }.flatMap { $0["rows"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(smsRows.count, 10)
        let contacts = messages.filter { $0["t"] as? String == "contacts" }.flatMap { $0["rows"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(contacts.count, 5)

        // Make a relay group and send to it: three copies, one group-message id, intro on each.
        let saved = expectation(description: "group saved")
        var gid = ""
        onMessage = { m in
            if m["t"] as? String == "group.saved" { gid = m["id"] as? String ?? ""; saved.fulfill() }
        }
        link.send(["t": "group.save", "cid": "g1", "g": ["name": "trip", "members": ["+15550100001", "+15550100002", "+15550100003"], "relay": true]])
        wait(for: [saved], timeout: 10)
        XCTAssertFalse(gid.isEmpty)

        var copies: [[String: Any]] = []
        let fanned = expectation(description: "three copies")
        onMessage = { m in
            guard m["t"] as? String == "sms" else { return }
            copies += (m["rows"] as? [[String: Any]] ?? []).filter { $0["g"] as? String == gid }
            if copies.count == 3 { fanned.fulfill() }
        }
        link.send(["t": "gsend", "g": gid, "body": "dinner at 8?", "cid": "m1"])
        wait(for: [fanned], timeout: 10)
        XCTAssertEqual(Set(copies.compactMap { $0["gm"] as? String }).count, 1)
        XCTAssertTrue(copies.allSatisfy { ($0["b"] as? String ?? "").hasPrefix("(group text with ") })

        // And the Mac collapses them to one bubble with the intro stripped.
        let store = try Store(path: dir.appendingPathComponent("mac.sqlite"))
        store.replaceGroups([["id": gid, "name": "trip", "members": ["+15550100001", "+15550100002", "+15550100003"], "relay": true]])
        store.upsertSms(copies)
        let built = Conversations.build(store)
        let bubbles = built["g:" + gid]?.messages ?? []
        XCTAssertEqual(bubbles.count, 1)
        XCTAssertEqual(bubbles.first?.body, "dinner at 8?")
        XCTAssertEqual(bubbles.first?.recipients, 3)
    }
}
