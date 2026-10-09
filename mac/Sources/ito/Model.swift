import AppKit
import Foundation
import ItoKit
import SwiftUI

struct PhoneInfo: Equatable {
    var name = "", model = "", android = "", number = "", fingerprint = ""
    var system = false
    var callAudio = "unknown"
    var smsOK = true
    var battery: Int?
    var plugged = true
    var charging = false
    var wifi = false
    var ims = "unknown"
}

struct CallInfo: Equatable {
    var id: String
    var state: String
    var number: String
    var name: String
    var dir: String
    var since: Int64
    var audio: Bool
    var full: Bool
    var title: String { name.isEmpty ? Numbers.pretty(number) : name }
}

/// A message you sent that the phone has not stored yet.
struct Echo: Equatable {
    var cid: String
    var thread: String
    var body: String
    var date: Int64
    var failed = false
}

enum Section: String { case messages, calls, phone }

@MainActor
final class AppModel: ObservableObject, LinkDelegate {
    let identity: Identity
    let link: LinkClient
    let store: Store
    let audio = CallAudio()
    let notifier = Notifier()

    @Published var linkState: LinkClient.State = .unpaired
    @Published var found: [LinkClient.Found] = []
    @Published var phone = PhoneInfo()
    @Published var threads: [ThreadSummary] = []
    @Published var section: Section = .messages
    @Published var selected: String? { didSet { markSelectedRead() } }
    @Published var call: CallInfo?
    @Published var callMuted = false { didSet { audio.muted = callMuted } }
    @Published var syncing = false
    @Published var notice: String?
    @Published var echoes: [Echo] = []
    @Published var photos: [String: NSImage] = [:]
    @Published var parts: [Int64: NSImage] = [:]
    @Published var manualHost: String = UserDefaults.standard.string(forKey: "manualHost") ?? "" {
        didSet {
            UserDefaults.standard.set(manualHost, forKey: "manualHost")
            link.manualHost = manualHost.isEmpty ? nil : manualHost
        }
    }

    /// Unsent text per thread. Not published: typing must not re-render the thread list.
    var drafts: [String: String] = [:]
    private(set) var built: [String: (numbers: [String], messages: [Message])] = [:]
    private var rebuildQueued = false
    private var smsIds = Set<Int64>()
    private var mmsIds = Set<Int64>()
    private var contactRows: [[String: Any]] = []
    private var partChunks: [Int64: [Int: Data]] = [:]
    private var wantAudio: String?
    private var selectNumberAfterSend: String?
    private var selectGroupCid: String?
    private var notifyAfterSms: Int64 = .max
    private var notifyAfterCall: Int64 = .max

    init() {
        // The debug-only snapshot run (see App.swift) must not touch the real Keychain or history.
        #if DEBUG
        let scratch = ProcessInfo.processInfo.environment["ITO_SNAPSHOT"] != nil
        #else
        let scratch = false
        #endif
        identity = scratch ? Identity(inMemory: true) : Identity()
        let path = scratch
            ? FileManager.default.temporaryDirectory.appendingPathComponent("ito-snapshot-\(UUID().uuidString)/ito.sqlite")
            : Store.defaultURL()
        store = (try? Store(path: path)) ?? { fatalError("cannot open the local store at \(path.path)") }()
        link = LinkClient(identity: identity)
        link.delegate = self
        link.manualHost = manualHost.isEmpty ? nil : manualHost
        audio.onFrame = { [weak link] frame in link?.sendAudio(frame) }
        notifier.model = self
        if identity.phone == nil { section = .phone }
        rebuild()
        link.start()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markSelectedRead() }
        }
    }

    var linked: Bool { if case .linked = linkState { return true } else { return false } }
    var unreadTotal: Int { threads.reduce(0) { $0 + $1.unread } }
    var missedCalls: [CallRow] { store.calls.values.filter(\.missed).sorted { $0.d > $1.d } }

    // MARK: LinkDelegate

    func linkStateChanged(_ state: LinkClient.State) {
        let wasPaired = identity.phone != nil
        linkState = state
        if case .linked = state {
            syncing = true
            // Notify only for what arrives after this sync, never for history.
            notifyAfterSms = .max
            notifyAfterCall = .max
            link.send(["t": "sync", "sms": store.maxSms, "mms": store.maxMms, "calls": store.maxCall, "contacts": store.contactsHash])
            if section == .phone && !wasPaired { section = .messages }
        }
    }

    func linkFound(_ phones: [LinkClient.Found]) { found = phones }

    func linkAudio(_ frame: Data) { audio.play(frame) }

    func linkReceived(_ m: [String: Any]) {
        switch m["t"] as? String ?? "" {
        case "hello":
            phone.name = m["name"] as? String ?? ""
            phone.model = m["model"] as? String ?? ""
            phone.android = m["android"] as? String ?? ""
            phone.number = m["number"] as? String ?? ""
            phone.fingerprint = m["fp"] as? String ?? ""
            phone.system = m["system"] as? Bool ?? false
            phone.callAudio = m["callAudio"] as? String ?? "unknown"
            phone.smsOK = m["sms"] as? Bool ?? true
        case "status":
            phone.battery = (m["batt"] as? NSNumber)?.intValue
            phone.plugged = m["plugged"] as? Bool ?? true
            phone.charging = m["charging"] as? Bool ?? false
            phone.wifi = m["wifi"] as? Bool ?? false
            phone.ims = m["ims"] as? String ?? "unknown"
        case "sms":
            let rows = m["rows"] as? [[String: Any]] ?? []
            store.upsertSms(rows)
            if !syncing { notifyNewTexts(rows) }
            settleEchoes(rows)
            rebuild()
        case "sms.ids":
            (m["ids"] as? [NSNumber] ?? []).forEach { smsIds.insert($0.int64Value) }
            if m["done"] as? Bool == true { store.keepOnlySms(smsIds); smsIds = []; rebuild() }
        case "mms":
            store.upsertMms(m["rows"] as? [[String: Any]] ?? [])
            rebuild()
        case "mms.ids":
            (m["ids"] as? [NSNumber] ?? []).forEach { mmsIds.insert($0.int64Value) }
            if m["done"] as? Bool == true { store.keepOnlyMms(mmsIds); mmsIds = []; rebuild() }
        case "contacts":
            contactRows += m["rows"] as? [[String: Any]] ?? []
            if m["done"] as? Bool == true {
                store.replaceContacts(contactRows, hash: m["hash"] as? String)
                contactRows = []
                rebuild()
            }
        case "calls":
            let rows = m["rows"] as? [[String: Any]] ?? []
            store.upsertCalls(rows)
            if !syncing {
                for r in rows {
                    guard let id = (r["id"] as? NSNumber)?.int64Value, id > notifyAfterCall, let c = store.calls[id] else { continue }
                    notifyAfterCall = id
                    if c.missed { notifier.missedCall(from: c.nm.isEmpty ? displayName(c.n) : c.nm) }
                }
            }
            objectWillChange.send()
        case "groups":
            store.replaceGroups(m["groups"] as? [[String: Any]] ?? [])
            rebuild()
        case "group.saved":
            if let cid = m["cid"] as? String, cid == selectGroupCid, let id = m["id"] as? String {
                selectGroupCid = nil
                section = .messages
                selected = "g:" + id
            }
        case "sent":
            if m["ok"] as? Bool == false, let cid = m["cid"] as? String {
                if let i = echoes.firstIndex(where: { $0.cid == cid }) { echoes[i].failed = true }
                let to = m["to"] as? String ?? ""
                notice = "not sent to \(store.name(for: to) ?? Numbers.pretty(to))"
            }
        case "call":
            onCall(m)
        case "photo":
            if let k = m["k"] as? String, let b64 = m["jpeg"] as? String, let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
                photos[k] = img
            }
        case "mmspart":
            onPart(m)
        case "synced":
            syncing = false
            notifyAfterSms = store.maxSms
            notifyAfterCall = store.maxCall
        case "error":
            notice = (m["msg"] as? String) ?? "the phone could not do that"
        default:
            break
        }
    }

    // MARK: threads

    func rebuild() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async { [self] in
            rebuildQueued = false
            built = Conversations.build(store, ownNumber: phone.number)
            threads = Conversations.threads(store, built: built)
            if let n = selectNumberAfterSend, let t = threads.first(where: { $0.group == nil && $0.numbers.contains { Numbers.key($0) == n } }) {
                selectNumberAfterSend = nil
                selected = t.id
            }
            markSelectedRead()
        }
    }

    func messages(_ key: String) -> [Message] { built[key]?.messages ?? [] }

    func thread(_ key: String) -> ThreadSummary? { threads.first { $0.id == key } }

    func displayName(_ number: String) -> String { store.name(for: number) ?? Numbers.pretty(number) }

    private func markSelectedRead() {
        guard NSApp?.isActive == true, section == .messages, let key = selected, let last = messages(key).last else { return }
        store.markRead(key, upTo: last.date)
        if let i = threads.firstIndex(where: { $0.id == key }), threads[i].unread > 0 {
            threads = Conversations.threads(store, built: built)
        }
        notifier.clear(thread: key)
    }

    /// Only what arrives after the first sync of this launch: history never notifies.
    private func notifyNewTexts(_ rows: [[String: Any]]) {
        for r in rows {
            guard let id = (r["id"] as? NSNumber)?.int64Value, id > notifyAfterSms else { continue }
            notifyAfterSms = id
            guard let s = store.sms[id], s.incoming, !s.rl else { continue }
            let key = s.g.map { "g:" + $0 } ?? "t:\(s.th)"
            if NSApp?.isActive == true && selected == key && section == .messages { continue }
            let who = displayName(s.a)
            let title = s.g.flatMap { g in store.groups.first { $0.id == g }?.name }.map { "\(who) · \($0)" } ?? who
            notifier.text(title: title, body: s.b, thread: key)
        }
    }

    // MARK: sending

    func send(_ text: String, to key: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let cid = UUID().uuidString
        if key.hasPrefix("g:") {
            link.send(["t": "gsend", "g": String(key.dropFirst(2)), "body": body, "cid": cid])
        } else if key.hasPrefix("new:") {
            let n = String(key.dropFirst(4))
            link.send(["t": "send", "to": [n], "body": body, "cid": cid])
            selectNumberAfterSend = Numbers.key(n)
        } else {
            guard let numbers = built[key]?.numbers, numbers.count == 1 else { return }
            link.send(["t": "send", "to": numbers, "body": body, "cid": cid])
        }
        echoes.append(Echo(cid: cid, thread: key, body: body, date: Int64(Date().timeIntervalSince1970 * 1000)))
    }

    /// Drop the local echo once the phone's stored copy shows up.
    private func settleEchoes(_ rows: [[String: Any]]) {
        guard !echoes.isEmpty else { return }
        let sent = rows.filter { ($0["ty"] as? NSNumber)?.intValue != 1 }.compactMap { $0["b"] as? String }.map(Conversations.stripIntro)
        echoes.removeAll { e in sent.contains(e.body) || Int64(Date().timeIntervalSince1970 * 1000) - e.date > 120_000 }
    }

    /// Open (or start) the one-to-one thread with a number.
    func open(number: String) {
        let k = Numbers.key(number)
        section = .messages
        if let t = threads.first(where: { $0.group == nil && $0.numbers.count == 1 && Numbers.key($0.numbers[0]) == k }) {
            selected = t.id
        } else {
            selected = "new:" + number
        }
    }

    func saveGroup(id: String?, name: String, members: [String], relay: Bool) {
        let cid = UUID().uuidString
        if id == nil { selectGroupCid = cid }
        var g: [String: Any] = ["name": name, "members": members, "relay": relay]
        if let id { g["id"] = id }
        link.send(["t": "group.save", "cid": cid, "g": g])
    }

    func deleteGroup(_ id: String) {
        link.send(["t": "group.delete", "id": id])
        if selected == "g:" + id { selected = nil }
    }

    func refile(_ smsId: Int64, to group: String?) {
        link.send(["t": "refile", "id": smsId, "g": group as Any? ?? NSNull()])
    }

    func loadPart(_ pid: Int64) {
        guard parts[pid] == nil, partChunks[pid] == nil else { return }
        partChunks[pid] = [:]
        link.send(["t": "mmspart", "pid": pid])
    }

    private func onPart(_ m: [String: Any]) {
        guard let pid = (m["pid"] as? NSNumber)?.int64Value else { return }
        if m["missing"] as? Bool == true { partChunks[pid] = nil; return }
        guard let i = (m["i"] as? NSNumber)?.intValue, let n = (m["n"] as? NSNumber)?.intValue,
              let data = (m["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return }
        partChunks[pid, default: [:]][i] = data
        if partChunks[pid]?.count == n {
            let whole = (0..<n).reduce(into: Data()) { $0.append(partChunks[pid]?[$1] ?? Data()) }
            partChunks[pid] = nil
            parts[pid] = NSImage(data: whole)
        }
    }

    // MARK: calls

    func dial(_ number: String) {
        let n = number.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        guard !n.isEmpty else { return }
        wantAudio = "dial"
        callMuted = false
        link.send(["t": "dial", "n": n])
    }

    func answer() {
        guard let c = call else { return }
        wantAudio = c.id
        callMuted = false
        link.send(["t": "answer", "id": c.id])
    }

    func decline() { if let c = call { link.send(["t": "decline", "id": c.id]) } }
    func hangup() { if let c = call { link.send(["t": "hangup", "id": c.id]) } }
    func hold(_ on: Bool) { if let c = call { link.send(["t": "hold", "id": c.id, "on": on]) } }
    func dtmf(_ d: String) { if let c = call { link.send(["t": "dtmf", "id": c.id, "d": d]) } }

    /// Pull a call that was answered on the phone itself over to this Mac.
    func takeCallHere() {
        guard let c = call else { return }
        wantAudio = c.id
        link.send(["t": "audio", "id": c.id, "on": true])
    }

    private func onCall(_ m: [String: Any]) {
        let info = CallInfo(id: m["id"] as? String ?? "", state: m["state"] as? String ?? "ended", number: m["n"] as? String ?? "",
                            name: (m["nm"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? store.name(for: m["n"] as? String ?? "") ?? "",
                            dir: m["dir"] as? String ?? "in", since: (m["since"] as? NSNumber)?.int64Value ?? 0,
                            audio: m["audio"] as? Bool ?? false, full: m["full"] as? Bool ?? false)
        if wantAudio == "dial", info.dir == "out" { wantAudio = info.id }

        if info.state == "ended" {
            if call?.id == info.id || call == nil {
                stopAudio()
                notifier.clearCall()
                call = info
                wantAudio = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    if self?.call?.state == "ended" { self?.call = nil }
                }
            }
            return
        }
        let wasRinging = call?.id == info.id && call?.state == "ringing"
        call = info
        if info.state == "ringing" && !wasRinging { notifier.ringing(from: info.title) }
        if info.state != "ringing" { notifier.clearCall() }
        if info.audio && wantAudio == info.id { startAudio() } else if !info.audio { stopAudio() }
    }

    private func startAudio() {
        guard !audio.running else { return }
        CallAudio.requestMic { [weak self] ok in
            guard let self else { return }
            guard ok else { self.notice = "ito needs the microphone for calls (system settings → privacy → microphone)"; return }
            do { try self.audio.start() } catch { self.notice = "audio failed: \(error.localizedDescription)" }
        }
    }

    private func stopAudio() { audio.stop() }

    // MARK: pairing

    func forgetPhone() {
        link.forgetPhone()
        store.wipe()
        phone = PhoneInfo()
        rebuild()
        section = .phone
    }
}
