import Foundation
import SQLite3

// MARK: rows, as the phone sends them

public struct Sms: Equatable {
    public var id: Int64, th: Int64, a: String, b: String, d: Int64, ds: Int64
    public var ty: Int, st: Int, r: Int
    public var g: String?, gm: String?, rl: Bool, ito: Bool

    public var incoming: Bool { ty == 1 }
    public var failed: Bool { ty == 5 || st == 64 }
    public var pending: Bool { ty == 4 || ty == 6 }
    public var delivered: Bool { ty == 2 && st == 0 }

    init?(_ o: [String: Any]) {
        guard let id = (o["id"] as? NSNumber)?.int64Value else { return nil }
        self.id = id
        th = (o["th"] as? NSNumber)?.int64Value ?? 0
        a = o["a"] as? String ?? ""
        b = o["b"] as? String ?? ""
        d = (o["d"] as? NSNumber)?.int64Value ?? 0
        ds = (o["ds"] as? NSNumber)?.int64Value ?? 0
        ty = (o["ty"] as? NSNumber)?.intValue ?? 1
        st = (o["st"] as? NSNumber)?.intValue ?? -1
        r = (o["r"] as? NSNumber)?.intValue ?? 1
        g = o["g"] as? String
        gm = o["gm"] as? String
        rl = o["rl"] as? Bool ?? false
        ito = o["ito"] as? Bool ?? false
    }

    init(id: Int64, th: Int64, a: String, b: String, d: Int64, ds: Int64, ty: Int, st: Int, r: Int, g: String?, gm: String?, rl: Bool, ito: Bool) {
        self.id = id; self.th = th; self.a = a; self.b = b; self.d = d; self.ds = ds
        self.ty = ty; self.st = st; self.r = r; self.g = g; self.gm = gm; self.rl = rl; self.ito = ito
    }
}

public struct Mms: Equatable {
    public struct Part: Equatable, Codable { public var pid: Int64; public var ct: String; public var name: String }
    public var id: Int64, th: Int64, d: Int64, box: Int, r: Int
    public var undl: Bool, from: String, to: [String], b: String, parts: [Part]

    public var incoming: Bool { box == 1 }

    init?(_ o: [String: Any]) {
        guard let id = (o["id"] as? NSNumber)?.int64Value else { return nil }
        self.id = id
        th = (o["th"] as? NSNumber)?.int64Value ?? 0
        d = (o["d"] as? NSNumber)?.int64Value ?? 0
        box = (o["box"] as? NSNumber)?.intValue ?? 1
        r = (o["r"] as? NSNumber)?.intValue ?? 1
        undl = o["undl"] as? Bool ?? false
        from = o["from"] as? String ?? ""
        to = o["to"] as? [String] ?? []
        b = o["b"] as? String ?? ""
        parts = (o["parts"] as? [[String: Any]] ?? []).compactMap { p in
            guard let pid = (p["pid"] as? NSNumber)?.int64Value else { return nil }
            return Part(pid: pid, ct: p["ct"] as? String ?? "", name: p["name"] as? String ?? "")
        }
    }

    init(id: Int64, th: Int64, d: Int64, box: Int, r: Int, undl: Bool, from: String, to: [String], b: String, parts: [Part]) {
        self.id = id; self.th = th; self.d = d; self.box = box; self.r = r
        self.undl = undl; self.from = from; self.to = to; self.b = b; self.parts = parts
    }
}

public struct Contact: Equatable {
    public var k: String, n: String, p: [String], ph: Bool
}

public struct CallRow: Equatable {
    public var id: Int64, n: String, nm: String, ty: Int, d: Int64, dur: Int64
    /// CallLog types: 1 in, 2 out, 3 missed, 4 voicemail, 5 rejected, 6 blocked.
    public var missed: Bool { ty == 3 || ty == 5 }
}

public struct GroupDef: Equatable {
    public var id: String, name: String, members: [String], relay: Bool, created: Int64
    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String else { return nil }
        self.id = id
        name = o["name"] as? String ?? "group"
        members = o["members"] as? [String] ?? []
        relay = o["relay"] as? Bool ?? false
        created = (o["created"] as? NSNumber)?.int64Value ?? 0
    }
    public init(id: String, name: String, members: [String], relay: Bool, created: Int64) {
        self.id = id; self.name = name; self.members = members; self.relay = relay; self.created = created
    }
}

public enum Numbers {
    /// Same rule as android/link/Numbers.kt: digits; 10+ digits collapse to the last 10.
    public static func key(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        if digits.count >= 10 { return String(digits.suffix(10)) }
        if !digits.isEmpty { return digits }
        return raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static func pretty(_ raw: String) -> String {
        let d = raw.filter(\.isNumber)
        let ten = d.count == 11 && d.hasPrefix("1") ? String(d.dropFirst()) : d
        guard ten.count == 10 else { return raw }
        let a = Array(ten)
        return "(\(String(a[0..<3]))) \(String(a[3..<6]))-\(String(a[6..<10]))"
    }
}

// MARK: the local mirror

/// What the Mac keeps of the phone, in one SQLite file under Application
/// Support. The phone stays the source of truth; this is a cache that lets
/// the window open instantly and history stay readable while the phone is away.
/// Not thread-safe: the app touches it from the main actor only.
public final class Store {
    private var db: OpaquePointer?

    public private(set) var sms: [Int64: Sms] = [:]
    public private(set) var mms: [Int64: Mms] = [:]
    public private(set) var contacts: [Contact] = []
    public private(set) var calls: [Int64: CallRow] = [:]
    public private(set) var groups: [GroupDef] = []
    public private(set) var readMarks: [String: Int64] = [:]
    public private(set) var contactsHash = ""
    private var nameIndex: [String: String] = [:]

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw StoreError.open }
        try exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS sms(id INTEGER PRIMARY KEY, th INT, a TEXT, b TEXT, d INT, ds INT, ty INT, st INT, r INT, g TEXT, gm TEXT, rl INT, ito INT);
        CREATE TABLE IF NOT EXISTS mms(id INTEGER PRIMARY KEY, th INT, d INT, box INT, r INT, undl INT, sender TEXT, recips TEXT, b TEXT, parts TEXT);
        CREATE TABLE IF NOT EXISTS contacts(k TEXT PRIMARY KEY, n TEXT, p TEXT, ph INT);
        CREATE TABLE IF NOT EXISTS calls(id INTEGER PRIMARY KEY, n TEXT, nm TEXT, ty INT, d INT, dur INT);
        CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY, name TEXT, members TEXT, relay INT, created INT);
        CREATE TABLE IF NOT EXISTS reads(k TEXT PRIMARY KEY, d INT);
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
        """)
        chmod(path.path, 0o600)
        load()
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ito/ito.sqlite")
    }

    deinit { sqlite3_close(db) }

    public var maxSms: Int64 { sms.keys.max() ?? 0 }
    public var maxMms: Int64 { mms.keys.max() ?? 0 }
    public var maxCall: Int64 { calls.keys.max() ?? 0 }

    // MARK: apply what the phone sent

    public func upsertSms(_ rows: [[String: Any]]) {
        transaction {
            for o in rows {
                guard let s = Sms(o) else { continue }
                sms[s.id] = s
                run("INSERT OR REPLACE INTO sms VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    s.id, s.th, s.a, s.b, s.d, s.ds, s.ty, s.st, s.r, s.g, s.gm, s.rl ? 1 : 0, s.ito ? 1 : 0)
            }
        }
    }

    public func upsertMms(_ rows: [[String: Any]]) {
        transaction {
            for o in rows {
                guard let m = Mms(o) else { continue }
                mms[m.id] = m
                let to = (try? JSONSerialization.data(withJSONObject: m.to)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let parts = (try? JSONEncoder().encode(m.parts)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                run("INSERT OR REPLACE INTO mms VALUES(?,?,?,?,?,?,?,?,?,?)",
                    m.id, m.th, m.d, m.box, m.r, m.undl ? 1 : 0, m.from, to, m.b, parts)
            }
        }
    }

    /// The phone's complete id list arrived: whatever we have that it does not, it deleted.
    public func keepOnlySms(_ ids: Set<Int64>) {
        let gone = Set(sms.keys).subtracting(ids)
        guard !gone.isEmpty else { return }
        transaction { for id in gone { sms[id] = nil; run("DELETE FROM sms WHERE id=?", id) } }
    }

    public func keepOnlyMms(_ ids: Set<Int64>) {
        let gone = Set(mms.keys).subtracting(ids)
        guard !gone.isEmpty else { return }
        transaction { for id in gone { mms[id] = nil; run("DELETE FROM mms WHERE id=?", id) } }
    }

    public func replaceContacts(_ rows: [[String: Any]], hash: String?) {
        let list = rows.compactMap { o -> Contact? in
            guard let k = o["k"] as? String else { return nil }
            return Contact(k: k, n: o["n"] as? String ?? "", p: o["p"] as? [String] ?? [], ph: o["ph"] as? Bool ?? false)
        }
        contacts = list
        reindex()
        transaction {
            run("DELETE FROM contacts")
            for c in list {
                let p = (try? JSONSerialization.data(withJSONObject: c.p)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                run("INSERT OR REPLACE INTO contacts VALUES(?,?,?,?)", c.k, c.n, p, c.ph ? 1 : 0)
            }
            if let hash { contactsHash = hash; run("INSERT OR REPLACE INTO meta VALUES('contacts', ?)", hash) }
        }
    }

    public func upsertCalls(_ rows: [[String: Any]]) {
        transaction {
            for o in rows {
                guard let id = (o["id"] as? NSNumber)?.int64Value else { continue }
                let c = CallRow(id: id, n: o["n"] as? String ?? "", nm: o["nm"] as? String ?? "",
                                ty: (o["ty"] as? NSNumber)?.intValue ?? 1, d: (o["d"] as? NSNumber)?.int64Value ?? 0,
                                dur: (o["dur"] as? NSNumber)?.int64Value ?? 0)
                calls[id] = c
                run("INSERT OR REPLACE INTO calls VALUES(?,?,?,?,?,?)", c.id, c.n, c.nm, c.ty, c.d, c.dur)
            }
        }
    }

    public func replaceGroups(_ rows: [[String: Any]]) {
        groups = rows.compactMap(GroupDef.init)
        transaction {
            run("DELETE FROM groups")
            for g in groups {
                let m = (try? JSONSerialization.data(withJSONObject: g.members)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                run("INSERT INTO groups VALUES(?,?,?,?,?)", g.id, g.name, m, g.relay ? 1 : 0, g.created)
            }
        }
    }

    public func markRead(_ key: String, upTo d: Int64) {
        guard d > (readMarks[key] ?? 0) else { return }
        readMarks[key] = d
        run("INSERT OR REPLACE INTO reads VALUES(?,?)", key, d)
    }

    /// A different phone was paired: nothing of the old one survives.
    public func wipe() {
        sms = [:]; mms = [:]; contacts = []; calls = [:]; groups = []; readMarks = [:]; contactsHash = ""
        nameIndex = [:]
        try? exec("DELETE FROM sms; DELETE FROM mms; DELETE FROM contacts; DELETE FROM calls; DELETE FROM groups; DELETE FROM reads; DELETE FROM meta;")
    }

    // MARK: names

    public func name(for number: String) -> String? { nameIndex[Numbers.key(number)] }

    public func contact(for number: String) -> Contact? {
        let k = Numbers.key(number)
        return contacts.first { $0.p.contains { Numbers.key($0) == k } }
    }

    private func reindex() {
        var idx: [String: String] = [:]
        for c in contacts { for p in c.p where idx[Numbers.key(p)] == nil { idx[Numbers.key(p)] = c.n } }
        nameIndex = idx
    }

    // MARK: load

    private func load() {
        query("SELECT id,th,a,b,d,ds,ty,st,r,g,gm,rl,ito FROM sms") { s in
            let row = Sms(id: s.i64(0), th: s.i64(1), a: s.str(2), b: s.str(3), d: s.i64(4), ds: s.i64(5),
                          ty: s.int(6), st: s.int(7), r: s.int(8), g: s.opt(9), gm: s.opt(10), rl: s.int(11) == 1, ito: s.int(12) == 1)
            sms[row.id] = row
        }
        query("SELECT id,th,d,box,r,undl,sender,recips,b,parts FROM mms") { s in
            let to = (try? JSONSerialization.jsonObject(with: Data(s.str(7).utf8))) as? [String] ?? []
            let parts = (try? JSONDecoder().decode([Mms.Part].self, from: Data(s.str(9).utf8))) ?? []
            let m = Mms(id: s.i64(0), th: s.i64(1), d: s.i64(2), box: s.int(3), r: s.int(4), undl: s.int(5) == 1,
                        from: s.str(6), to: to, b: s.str(8), parts: parts)
            mms[m.id] = m
        }
        query("SELECT k,n,p,ph FROM contacts") { s in
            let p = (try? JSONSerialization.jsonObject(with: Data(s.str(2).utf8))) as? [String] ?? []
            contacts.append(Contact(k: s.str(0), n: s.str(1), p: p, ph: s.int(3) == 1))
        }
        reindex()
        query("SELECT id,n,nm,ty,d,dur FROM calls") { s in
            calls[s.i64(0)] = CallRow(id: s.i64(0), n: s.str(1), nm: s.str(2), ty: s.int(3), d: s.i64(4), dur: s.i64(5))
        }
        query("SELECT id,name,members,relay,created FROM groups") { s in
            let m = (try? JSONSerialization.jsonObject(with: Data(s.str(2).utf8))) as? [String] ?? []
            groups.append(GroupDef(id: s.str(0), name: s.str(1), members: m, relay: s.int(3) == 1, created: s.i64(4)))
        }
        query("SELECT k,d FROM reads") { s in readMarks[s.str(0)] = s.i64(1) }
        query("SELECT v FROM meta WHERE k='contacts'") { s in contactsHash = s.str(0) }
    }

    // MARK: sqlite

    public enum StoreError: Error { case open, exec(String) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw StoreError.exec(msg)
        }
    }

    private func transaction(_ body: () -> Void) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        body()
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func run(_ sql: String, _ args: Any?...) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, idx)
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as String: sqlite3_bind_text(st, idx, v, -1, Store.transient)
            case let v as String?: if let v { sqlite3_bind_text(st, idx, v, -1, Store.transient) } else { sqlite3_bind_null(st, idx) }
            default: sqlite3_bind_null(st, idx)
            }
        }
        sqlite3_step(st)
    }

    private struct Row {
        let st: OpaquePointer?
        func i64(_ i: Int32) -> Int64 { sqlite3_column_int64(st, i) }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
        func str(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        func opt(_ i: Int32) -> String? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : str(i) }
    }

    private func query(_ sql: String, _ each: (Row) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { each(Row(st: st)) }
    }
}
