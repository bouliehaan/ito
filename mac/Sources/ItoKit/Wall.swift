import Foundation

/// A secondbrain wall the phone tells who has texted (android/link/Wall.kt has the whole
/// story). The Mac only carries the wall's address and key to the phone, shows how it is
/// going, and tells the phone what has been read here so those cards come down.
public struct WallInfo: Equatable {
    public var url: String
    /// How the phone's last post went; all nil before its first.
    public var ok: Bool?
    public var cards: Int?
    public var error: String?

    /// `wall` from the phone's hello or a "wall" message: nil when no wall is set.
    public init?(_ any: Any?) {
        guard let o = any as? [String: Any], let url = o["url"] as? String else { return nil }
        self.url = url
        let state = o["state"] as? [String: Any]
        ok = state?["ok"] as? Bool
        cards = (state?["cards"] as? NSNumber)?.intValue
        error = state?["err"] as? String
    }

    /// The line enable-ito prints on the wall, `http://192.168.1.50:43761 <key>`, split into
    /// what the phone wants. Nil when it is not that line. The phone checks it again.
    public static func parse(line: String) -> (url: String, key: String)? {
        let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let url = words.first(where: { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }),
              let host = URLComponents(string: url)?.host, !host.isEmpty,
              let key = words.first(where: isKey)
        else { return nil }
        return (url, key)
    }

    /// 32 bytes as base64url without padding: 43 of A-Z a-z 0-9 - _.
    static func isKey(_ s: String) -> Bool {
        s.count == 43 && s.unicodeScalars.allSatisfy { c in
            ("A"..."Z").contains(c) || ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "-" || c == "_"
        }
    }
}
