import Foundation

/// One bubble on screen. A group message you sent is ONE bubble even though
/// it went out as an SMS per member; relay copies are never bubbles at all.
public struct Message: Identifiable, Equatable {
    public enum Status: Equatable { case none, pending, sent, delivered, failed }
    public enum Kind: Equatable { case text, mms, mmsUndownloaded }

    public let id: String
    public let incoming: Bool
    /// The phone's own read flag (set when read in the phone's messaging app).
    public let read: Bool
    public let sender: String
    public let body: String
    public let date: Int64
    public let status: Status
    public let kind: Kind
    /// For received texts: the phone row, so it can be moved in or out of a group.
    public let smsId: Int64?
    public let parts: [Mms.Part]
    /// A group message you sent: how many people it went to, and who it failed for.
    public let recipients: Int
    public let failedTo: [String]
    /// A received group message: how many members it was relayed to.
    public let relayedTo: Int
}

public struct ThreadSummary: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let numbers: [String]
    public let group: GroupDef?
    public let last: Message?
    public let unread: Int
    public var lastDate: Int64 { last?.date ?? group?.created ?? 0 }
}

public enum Conversations {
    static let introPrefix = "(group text with "

    /// Strip the one-time "(group text with …)" line ito puts on a member's first group text.
    public static func stripIntro(_ body: String) -> String {
        guard body.hasPrefix(introPrefix), let nl = body.firstIndex(of: "\n") else { return body }
        return String(body[body.index(after: nl)...])
    }

    private struct Bucket {
        var messages: [Message] = []
        var numbers: [String] = []
    }

    /// Everything, bucketed per thread, in date order.
    public static func build(_ store: Store, ownNumber: String = "") -> [String: (numbers: [String], messages: [Message])] {
        let own = Numbers.key(ownNumber)
        let liveGroups = Set(store.groups.map(\.id))
        var buckets: [String: Bucket] = [:]
        var relayed: [String: Int] = [:]
        var outGroup: [String: [Sms]] = [:]

        func add(_ key: String, _ m: Message, numbers: [String]) {
            var b = buckets[key] ?? Bucket()
            b.messages.append(m)
            for n in numbers where !n.isEmpty && Numbers.key(n) != own && !b.numbers.contains(where: { Numbers.key($0) == Numbers.key(n) }) {
                b.numbers.append(n)
            }
            buckets[key] = b
        }

        for s in store.sms.values {
            if s.rl {
                if let gm = s.gm { relayed[gm, default: 0] += 1 }
                continue
            }
            if let g = s.g, liveGroups.contains(g) {
                if !s.incoming, let gm = s.gm {
                    outGroup[g + "|" + gm, default: []].append(s)
                    continue
                }
                add("g:" + g, message(s), numbers: [s.a])
            } else {
                add("t:\(s.th)", message(s), numbers: [s.a])
            }
        }

        for (key, copies) in outGroup {
            let g = String(key.split(separator: "|")[0])
            let first = copies.min { $0.d < $1.d }!
            let failed = copies.filter(\.failed).map(\.a)
            let status: Message.Status =
                !failed.isEmpty ? .failed :
                copies.contains(where: \.pending) ? .pending :
                copies.allSatisfy(\.delivered) ? .delivered : .sent
            let body = copies.map { stripIntro($0.b) }.min { $0.count < $1.count } ?? first.b
            add("g:" + g, Message(id: "gm:" + (first.gm ?? "\(first.id)"), incoming: false, read: true, sender: "", body: body, date: first.d,
                                  status: status, kind: .text, smsId: nil, parts: [], recipients: copies.count,
                                  failedTo: failed, relayedTo: 0), numbers: [])
        }

        for m in store.mms.values {
            let kind: Message.Kind = m.undl ? .mmsUndownloaded : .mms
            let body = m.undl ? "" : m.b
            add("t:\(m.th)", Message(id: "m\(m.id)", incoming: m.incoming, read: m.r == 1, sender: m.from, body: body, date: m.d,
                                     status: .none, kind: kind, smsId: nil, parts: m.parts, recipients: 0, failedTo: [], relayedTo: 0),
                numbers: [m.from] + m.to)
        }

        var out: [String: (numbers: [String], messages: [Message])] = [:]
        for (k, b) in buckets {
            let msgs = b.messages.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }.map { m -> Message in
                guard m.incoming, let gm = groupMessageId(m, store), let n = relayed[gm] else { return m }
                return Message(id: m.id, incoming: true, read: m.read, sender: m.sender, body: m.body, date: m.date, status: m.status,
                               kind: m.kind, smsId: m.smsId, parts: m.parts, recipients: 0, failedTo: [], relayedTo: n)
            }
            out[k] = (b.numbers, msgs)
        }
        return out
    }

    public static func threads(_ store: Store, built: [String: (numbers: [String], messages: [Message])]) -> [ThreadSummary] {
        var list: [ThreadSummary] = []
        var seenGroups = Set<String>()
        for (key, t) in built {
            let mark = store.readMarks[key] ?? 0
            // Unread = not read on the phone AND not seen here. History read on the phone stays read.
            let unread = t.messages.filter { $0.incoming && !$0.read && $0.date > mark }.count
            var group: GroupDef?
            if key.hasPrefix("g:") {
                let gid = String(key.dropFirst(2))
                group = store.groups.first { $0.id == gid }
                seenGroups.insert(gid)
            }
            let numbers = group?.members ?? t.numbers
            list.append(ThreadSummary(id: key, title: group?.name ?? title(numbers, store), numbers: numbers,
                                      group: group, last: t.messages.last, unread: unread))
        }
        for g in store.groups where !seenGroups.contains(g.id) {
            list.append(ThreadSummary(id: "g:" + g.id, title: g.name, numbers: g.members, group: g, last: nil, unread: 0))
        }
        return list.sorted { $0.lastDate > $1.lastDate }
    }

    public static func title(_ numbers: [String], _ store: Store) -> String {
        if numbers.isEmpty { return "unknown" }
        let names = numbers.map { store.name(for: $0) ?? Numbers.pretty($0) }
        if names.count == 1 { return names[0] }
        return names.map { $0.split(separator: " ").first.map(String.init) ?? $0 }.joined(separator: ", ")
    }

    private static func message(_ s: Sms) -> Message {
        let status: Message.Status = s.incoming ? .none : s.failed ? .failed : s.pending ? .pending : s.delivered ? .delivered : .sent
        return Message(id: "s\(s.id)", incoming: s.incoming, read: s.r == 1, sender: s.incoming ? s.a : "", body: s.b, date: s.d,
                       status: status, kind: .text, smsId: s.id, parts: [], recipients: 0, failedTo: [], relayedTo: 0)
    }

    private static func groupMessageId(_ m: Message, _ store: Store) -> String? {
        guard let id = m.smsId else { return nil }
        return store.sms[id]?.gm
    }
}
