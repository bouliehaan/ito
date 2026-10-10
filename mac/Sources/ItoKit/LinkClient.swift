import Foundation
import Network
import os

private let log = Logger(subsystem: "app.ito", category: "link")

/// Always called on the main queue.
@MainActor
public protocol LinkDelegate: AnyObject {
    func linkStateChanged(_ state: LinkClient.State)
    func linkReceived(_ message: [String: Any])
    func linkAudio(_ frame: Data)
    func linkFound(_ phones: [LinkClient.Found])
}

/// The Mac end of the wire: finds the phone on the LAN, runs Noise XX as
/// initiator, pairs (numeric comparison) or checks the pinned key, then keeps
/// the session alive and reconnects when it drops. Everything runs on one
/// serial queue; the delegate hears about it on the main queue.
///
/// The rule that keeps it from ever getting stuck: every connection attempt ends
/// within `attemptTimeout`, linked or failed, and every failure schedules the next
/// attempt. A network change or the Mac waking up skips the wait.
public final class LinkClient {
    public enum State: Equatable {
        case unpaired
        case searching
        case connecting(String)
        case pairing(code: String?, phone: String, confirmed: Bool)
        case linked(phone: String)
        case failed(String)
    }

    public struct Found: Hashable {
        public let name: String
        public let fingerprint: String?
        let endpoint: NWEndpoint

        /// A phone typed in by address, for networks where Bonjour does not get through.
        public static func manual(_ hostPort: String) -> Found? {
            guard let ep = LinkClient.endpoint(hostPort) else { return nil }
            return Found(name: hostPort, fingerprint: nil, endpoint: ep)
        }
    }

    public weak var delegate: LinkDelegate?
    public let identity: Identity
    /// Optional "host:port" tried before Bonjour, e.g. a Tailscale address when away from home.
    public var manualHost: String? {
        didSet { queue.async { self.kick() } }
    }

    private let queue = DispatchQueue(label: "ito.link")
    private var browser: NWBrowser?
    private var found: [String: Found] = [:]
    private var conn: NWConnection?
    private var hs: XXHandshake?
    private var transport: Transport?
    private var phoneName = "phone"
    private var remoteStatic: Data?
    private var handshakeHash = Data()
    private var trusted = false

    private var pairTarget: Found?
    private var macNonce: Data?
    private var phoneCommit: Data?
    private var pairConfirmed = false

    private var ping: DispatchSourceTimer?
    private var lastHeard = Date()
    private var retry: DispatchWorkItem?
    private var backoff: TimeInterval = 1
    private var stopped = true

    private var monitor: NWPathMonitor?
    private var lastPath = ""
    private var localNetworkDenied = false
    private var attempts = 0
    private var viaLastAddress = false

    /// Long enough for a slow Wi-Fi handshake, short enough that a stall is noticed.
    var attemptTimeout: TimeInterval = 10
    static let localNetworkHelp = "macOS is blocking ito from the local network. System Settings → Privacy & Security → Local Network → turn ito on."

    /// Where the phone last answered (IPv4, or IPv6 with its interface), tried when Bonjour
    /// can't see it: some networks, and some phones with the screen off, drop multicast.
    private var lastAddress: NWEndpoint? {
        get {
            let d = UserDefaults.standard
            guard let host = d.string(forKey: "ito.lastHost"), let port = NWEndpoint.Port(rawValue: UInt16(clamping: d.integer(forKey: "ito.lastPort"))),
                  port.rawValue != 0 else { return nil }
            return .hostPort(host: NWEndpoint.Host(host), port: port)
        }
        set {
            let d = UserDefaults.standard
            if case let .hostPort(host, port)? = newValue {
                d.set("\(host)", forKey: "ito.lastHost")
                d.set(Int(port.rawValue), forKey: "ito.lastPort")
            } else {
                d.removeObject(forKey: "ito.lastHost")
                d.removeObject(forKey: "ito.lastPort")
            }
        }
    }

    public private(set) var state: State = .unpaired {
        didSet {
            let s = state
            if s != oldValue {
                log.info("state: \(String(describing: s), privacy: .public)")
                DispatchQueue.main.async { self.delegate?.linkStateChanged(s) }
            }
        }
    }

    public init(identity: Identity) {
        self.identity = identity
    }

    // MARK: public

    public func start() {
        queue.async {
            self.stopped = false
            self.browse()
            self.watchNetwork()
            self.kick()
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.retry?.cancel()
            self.drop()
            self.browser?.cancel()
            self.browser = nil
            self.monitor?.cancel()
            self.monitor = nil
        }
    }

    /// Pair with a phone the user picked from the list of ones on the network.
    public func pair(with phone: Found) {
        queue.async {
            self.drop()
            self.pairTarget = phone
            self.pairConfirmed = false
            self.connect(to: phone.endpoint, label: phone.name)
        }
    }

    /// The user compared the codes.
    public func confirmPairing(_ ok: Bool) {
        queue.async {
            guard case .pairing(let code?, let name, _) = self.state else { return }
            if ok {
                self.pairConfirmed = true
                self.state = .pairing(code: code, phone: name, confirmed: true)
                self.sendNow(["t": "pair.ok"])
            } else {
                self.sendNow(["t": "pair.no"])
                self.pairTarget = nil
                self.drop()
                self.state = .unpaired
            }
        }
    }

    public func cancelPairing() {
        queue.async {
            self.pairTarget = nil
            self.drop()
            self.state = self.identity.phone == nil ? .unpaired : .searching
            self.kick()
        }
    }

    public func forgetPhone() {
        queue.async {
            self.identity.phone = nil
            self.drop()
            self.state = .unpaired
        }
    }

    /// The Mac woke up, the network changed, or the user asked: find out now whether the
    /// link is alive instead of waiting out a ping or a backoff.
    public func reconnectNow() {
        queue.async { self.checkNow() }
    }

    public func send(_ message: [String: Any]) {
        queue.async { if self.trusted { self.sendNow(message) } }
    }

    /// One 20 ms frame of microphone: u32 sequence + 640 bytes of s16le @ 16 kHz.
    public func sendAudio(_ frame: Data) {
        queue.async {
            guard self.trusted else { return }
            self.sendKind(2, frame)
        }
    }

    // MARK: discovery

    private func browse() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_ito._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var next: [String: Found] = [:]
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                var fp: String?
                if case let .bonjour(txt) = r.metadata { fp = txt["fp"] }
                next[name] = Found(name: name, fingerprint: fp, endpoint: r.endpoint)
            }
            self.found = next
            let list = Array(next.values).sorted { $0.name < $1.name }
            DispatchQueue.main.async { self.delegate?.linkFound(list) }
            self.kick()
        }
        b.stateUpdateHandler = { [weak self, weak b] st in
            guard let self, let b, b === self.browser else { return }
            switch st {
            case .ready:
                self.localNetworkDenied = false
            case .waiting(let e):
                log.error("browse waiting: \(String(describing: e), privacy: .public)")
                self.localNetworkDenied = Self.policyDenied(e)
                if self.localNetworkDenied, !self.trusted, self.conn == nil { self.state = .failed(Self.localNetworkHelp) }
            case .failed(let e):
                // A dead browser would never report the phone again: start a fresh one.
                log.error("browse failed: \(String(describing: e), privacy: .public)")
                self.restartBrowse(after: 2)
            default:
                break
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func restartBrowse(after delay: TimeInterval) {
        browser?.cancel()
        browser = nil
        found = [:]
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.browse()
        }
    }

    /// Wi-Fi rejoined, Ethernet plugged in, the Mac woke: a fresh look and a fresh attempt.
    private func watchNetwork() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let key = path.status == .satisfied ? path.availableInterfaces.map(\.name).sorted().joined(separator: ",") : "down"
            guard key != self.lastPath else { return }
            let first = self.lastPath.isEmpty
            self.lastPath = key
            guard !first, path.status == .satisfied else { return }
            log.info("network changed: \(key, privacy: .public)")
            self.restartBrowse(after: 0)
            self.checkNow()
        }
        m.start(queue: queue)
        monitor = m
    }

    private func checkNow() {
        backoff = 1
        if trusted {
            let asked = Date()
            sendNow(["t": "ping"])
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.trusted, self.lastHeard < asked else { return }
                self.fail("phone stopped answering")
            }
        } else if pairTarget == nil {
            retry?.cancel()
            drop()
            kick()
        }
    }

    static func policyDenied(_ e: NWError) -> Bool {
        if case .dns(let code) = e { return code == -65570 }   // kDNSServiceErr_PolicyDenied
        return false
    }

    /// If we have a phone and no connection, go and get it.
    private func kick() {
        guard !stopped, conn == nil, pairTarget == nil else { return }
        guard let phone = identity.phone else {
            state = identity.refused.map { .failed($0.description) } ?? .unpaired
            return
        }
        attempts += 1
        viaLastAddress = false
        if let host = manualHost, let ep = Self.endpoint(host) {
            connect(to: ep, label: host)
            return
        }
        let seen = found.values.first(where: { $0.fingerprint == phone.fingerprint })
            ?? found.values.first(where: { $0.fingerprint == nil })
        // Bonjour first. When it sees nothing, or on every other retry, the last address.
        if let ep = lastAddress, seen == nil || attempts % 2 == 0 {
            viaLastAddress = true
            connect(to: ep, label: phone.name)
        } else if let seen {
            connect(to: seen.endpoint, label: phone.name)
        } else {
            state = localNetworkDenied ? .failed(Self.localNetworkHelp) : .searching
        }
    }

    static func endpoint(_ s: String) -> NWEndpoint? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard let host = parts.first, !host.isEmpty else { return nil }
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 6969 : 6969
        return .hostPort(host: NWEndpoint.Host(String(host)), port: NWEndpoint.Port(rawValue: port)!)
    }

    // MARK: connection

    private func connect(to endpoint: NWEndpoint, label: String) {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 20
        }
        let c = NWConnection(to: endpoint, using: params)
        conn = c
        trusted = false
        transport = nil
        state = .connecting(label)
        log.info("connecting: \(String(describing: endpoint), privacy: .public)")
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, c === self.conn else { return }
            switch st {
            case .ready: self.handshake(c)
            case .failed(let e): self.fail(self.unreachable(c, e))
            case .waiting(let e): self.fail(self.unreachable(c, e))
            case .cancelled: break
            default: break
            }
        }
        c.start(queue: queue)
        // Network.framework can sit in .preparing forever without saying why (it did when
        // macOS refused the first connection of a freshly updated build), and a phone can
        // accept and then never answer. Either way this attempt ends here and the next one
        // is scheduled. Comparing codes during pairing takes as long as it takes.
        queue.asyncAfter(deadline: .now() + attemptTimeout) { [weak self, weak c] in
            guard let self, let c, c === self.conn, !self.trusted else { return }
            if case .pairing = self.state { return }
            self.fail(self.unreachable(c, nil))
        }
    }

    private func unreachable(_ c: NWConnection, _ e: NWError?) -> String {
        if localNetworkDenied || c.currentPath?.unsatisfiedReason == .localNetworkDenied || e.map(Self.policyDenied) == true {
            return Self.localNetworkHelp
        }
        if let e { return "phone unreachable: \(e.localizedDescription)" }
        return "the phone didn't answer"
    }

    private func handshake(_ c: NWConnection) {
        let key: DhKey
        do { key = try identity.staticKey() } catch { return fail("\(error)", retry: false) }
        let h = XXHandshake(initiator: true, s: key)
        hs = h
        do {
            writeFrame(try h.writeMessage())
        } catch { return fail("handshake: \(error)") }
        readFrame { [weak self] msg2 in
            guard let self else { return }
            do {
                let hello = try JSONSerialization.jsonObject(with: try h.readMessage(msg2)) as? [String: Any] ?? [:]
                self.phoneName = (hello["name"] as? String) ?? "phone"
                guard let rs = h.remoteStatic else { return self.fail("no phone key") }
                self.remoteStatic = rs
                if let pinned = self.identity.phone {
                    guard pinned.key == rs else {
                        // An ito phone with a different key now has the remembered address
                        // (the router handed it out again): forget the address, keep looking.
                        if self.viaLastAddress {
                            self.lastAddress = nil
                            return self.fail("the phone moved to a new address")
                        }
                        // Somebody answered as our phone with a different key. Never talk to it.
                        return self.fail("refusing \(self.phoneName): its key does not match the paired phone. if you reinstalled ito on the phone, forget it here and pair again.", retry: false)
                    }
                } else if self.pairTarget == nil {
                    return self.drop()
                }
                let macHello: [String: Any] = ["name": Host.current().localizedName ?? "mac", "v": 1]
                self.writeFrame(try h.writeMessage(try JSONSerialization.data(withJSONObject: macHello)))
                self.transport = try h.split()
                self.handshakeHash = h.handshakeHash
                self.hs = nil
                self.lastHeard = Date()
                self.readLoop()
            } catch {
                self.fail("handshake failed: \(error)")
            }
        }
    }

    private func readLoop() {
        readFrame { [weak self] frame in
            guard let self, let t = self.transport else { return }
            do {
                let pt = try t.open(frame)
                self.lastHeard = Date()
                guard let kind = pt.first else { return self.fail("empty frame") }
                let body = pt.dropFirst()
                if kind == 1 {
                    let obj = try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] ?? [:]
                    self.onJson(obj)
                } else if kind == 2, self.trusted {
                    let frame = Data(body)
                    DispatchQueue.main.async { self.delegate?.linkAudio(frame) }
                }
                if self.conn != nil { self.readLoop() }
            } catch {
                self.fail("link broken: \(error)")
            }
        }
    }

    private func onJson(_ m: [String: Any]) {
        let t = m["t"] as? String ?? ""
        switch t {
        case "auth":
            switch m["state"] as? String {
            case "trusted":
                if identity.phone == nil || pairTarget != nil {
                    guard pairConfirmed, let rs = remoteStatic else { return fail("phone trusted us before we confirmed") }
                    identity.phone = Identity.Phone(key: rs, name: phoneName)
                    pairTarget = nil
                }
                trusted = true
                backoff = 1
                attempts = 0
                if case .hostPort? = conn?.currentPath?.remoteEndpoint { lastAddress = conn?.currentPath?.remoteEndpoint }
                state = .linked(phone: phoneName)
                startPing()
            case "pairing":
                guard pairTarget != nil else { return drop() }
                state = .pairing(code: nil, phone: phoneName, confirmed: false)
            default:
                let why = m["why"] as? String ?? "refused"
                fail(why, retry: identity.phone != nil)
            }
        case "pair.commit":
            guard pairTarget != nil, let c = (m["c"] as? String).flatMap(Data.init(hex:)) else { return fail("unexpected pairing message") }
            phoneCommit = c
            let n = Sas.nonce()
            macNonce = n
            sendNow(["t": "pair.nonce", "n": n.hex])
        case "pair.reveal":
            guard let np = (m["n"] as? String).flatMap(Data.init(hex:)), let c = phoneCommit, let nm = macNonce else {
                return fail("unexpected pairing message")
            }
            guard Sas.commit(np) == c else {
                return fail("pairing aborted: the phone's answer did not match its commitment. something may be intercepting.", retry: false)
            }
            state = .pairing(code: Sas.code(handshakeHash: handshakeHash, macNonce: nm, phoneNonce: np), phone: phoneName, confirmed: false)
        case "pair.no":
            pairTarget = nil
            fail(m["why"] as? String ?? "the phone said no", retry: false)
        case "pong":
            break
        default:
            guard trusted else { return }
            DispatchQueue.main.async { self.delegate?.linkReceived(m) }
        }
    }

    private func startPing() {
        ping?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, self.trusted else { return }
            if Date().timeIntervalSince(self.lastHeard) > 45 { return self.fail("phone stopped answering") }
            self.sendNow(["t": "ping"])
        }
        timer.resume()
        ping = timer
    }

    // MARK: frames

    private func sendNow(_ m: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: m) else { return }
        sendKind(1, data)
    }

    private func sendKind(_ kind: UInt8, _ body: Data) {
        guard let t = transport else { return }
        var pt = Data([kind])
        pt.append(body)
        do { writeFrame(try t.seal(pt)) } catch { fail("encrypt: \(error)") }
    }

    private func writeFrame(_ msg: Data) {
        guard let c = conn, msg.count <= 65535 else { return }
        var out = Data([UInt8(msg.count >> 8), UInt8(msg.count & 0xff)])
        out.append(msg)
        c.send(content: out, completion: .contentProcessed { [weak self] err in
            if let err { self?.fail("send failed: \(err.localizedDescription)") }
        })
    }

    private func readFrame(_ done: @escaping (Data) -> Void) {
        guard let c = conn else { return }
        c.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] head, _, complete, err in
            guard let self, c === self.conn else { return }
            guard err == nil, let head, head.count == 2 else {
                return self.fail(complete ? "phone closed the link" : "read failed")
            }
            let h = [UInt8](head)
            let len = Int(h[0]) << 8 | Int(h[1])
            if len == 0 { return done(Data()) }
            c.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, complete, err in
                guard c === self.conn else { return }
                guard err == nil, let body, body.count == len else {
                    return self.fail(complete ? "phone closed the link" : "read failed")
                }
                done(Data(body))
            }
        }
    }

    // MARK: teardown

    private func drop() {
        ping?.cancel()
        ping = nil
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
        transport = nil
        hs = nil
        trusted = false
        phoneCommit = nil
        macNonce = nil
    }

    private func fail(_ why: String, retry shouldRetry: Bool = true) {
        let wasPairing = pairTarget != nil
        log.error("link failed: \(why, privacy: .public)")
        drop()
        state = .failed(why)
        // A failed pairing is over; the user starts a new one from the list.
        if wasPairing { pairTarget = nil }
        guard shouldRetry, !stopped, identity.phone != nil, !wasPairing else { return }
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.conn == nil else { return }
            self.kick()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + backoff, execute: work)
        backoff = min(backoff * 2, 30)
    }
}
