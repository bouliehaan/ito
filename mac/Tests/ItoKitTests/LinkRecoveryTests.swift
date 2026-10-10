import Foundation
import Network
import XCTest
@testable import ItoKit

/// The link must never sit on "connecting" forever. A phone that accepts and then says
/// nothing (or a connection Network.framework never finishes, as after a Mac update) ends
/// the attempt, and the next attempt follows.
final class LinkRecoveryTests: XCTestCase, LinkDelegate {
    private var onState: ((LinkClient.State) -> Void)?

    func linkStateChanged(_ state: LinkClient.State) { onState?(state) }
    func linkReceived(_ message: [String: Any]) {}
    func linkAudio(_ frame: Data) {}
    func linkFound(_ phones: [LinkClient.Found]) {}

    func testSilentPhoneEndsTheAttemptAndRetries() throws {
        // A "phone" that accepts the connection and never answers the handshake.
        let listener = try NWListener(using: .tcp, on: .any)
        var held: [NWConnection] = []
        listener.newConnectionHandler = { c in held.append(c); c.start(queue: .main) }
        let up = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { up.fulfill() } }
        listener.start(queue: .main)
        wait(for: [up], timeout: 5)
        defer { listener.cancel(); held.forEach { $0.cancel() } }

        let identity = Identity(inMemory: true)
        identity.phone = .init(key: Data(repeating: 7, count: 32), name: "phone")
        let link = LinkClient(identity: identity)
        link.attemptTimeout = 1
        link.delegate = self
        link.manualHost = "127.0.0.1:\(listener.port!.rawValue)"

        let gaveUp = expectation(description: "attempt ended")
        let retried = expectation(description: "next attempt started")
        retried.assertForOverFulfill = false
        var failed = false
        onState = { s in
            if case .failed(let why) = s, !failed {
                failed = true
                XCTAssertFalse(why.isEmpty)
                gaveUp.fulfill()
            }
            if case .connecting = s, failed { retried.fulfill() }
        }
        link.start()
        wait(for: [gaveUp, retried], timeout: 8)
        XCTAssertFalse(held.isEmpty, "the attempt reached the listener")
    }
}
