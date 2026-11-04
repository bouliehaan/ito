import XCTest
@testable import ItoKit

/// The line pasted from the wall, and what the phone says about it.
final class WallTests: XCTestCase {
    private let key = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"

    func testTakesTheLineEnableItoPrints() {
        let w = WallInfo.parse(line: "  http://192.168.1.50:43761 \(key)\n")
        XCTAssertEqual(w?.url, "http://192.168.1.50:43761")
        XCTAssertEqual(w?.key, key)
    }

    func testRefusesAnythingElse() {
        XCTAssertNil(WallInfo.parse(line: "http://192.168.1.50:43761"), "no key")
        XCTAssertNil(WallInfo.parse(line: key), "no address")
        XCTAssertNil(WallInfo.parse(line: "192.168.1.50:43761 \(key)"), "no scheme")
        XCTAssertNil(WallInfo.parse(line: "http://192.168.1.50:43761 \(key.dropLast())"), "short key")
        XCTAssertNil(WallInfo.parse(line: "http://192.168.1.50:43761 \(key.dropLast())+"), "not base64url")
    }

    func testReadsWhatThePhoneSays() {
        XCTAssertNil(WallInfo(NSNull()), "no wall set")
        let fresh = WallInfo(["url": "http://10.0.0.5:43761"] as [String: Any])
        XCTAssertEqual(fresh?.url, "http://10.0.0.5:43761")
        XCTAssertNil(fresh?.ok)
        let upState: [String: Any] = ["at": 1, "ok": true, "cards": 2, "err": NSNull()]
        let up = WallInfo(["url": "http://10.0.0.5:43761", "state": upState] as [String: Any])
        XCTAssertEqual(up?.ok, true)
        XCTAssertEqual(up?.cards, 2)
        XCTAssertNil(up?.error)
        let downState: [String: Any] = ["at": 1, "ok": false, "cards": NSNull(), "err": "not answering"]
        let down = WallInfo(["url": "http://10.0.0.5:43761", "state": downState] as [String: Any])
        XCTAssertEqual(down?.ok, false)
        XCTAssertEqual(down?.error, "not answering")
    }
}
