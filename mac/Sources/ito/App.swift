import AppKit
import CoreAudio
import ItoKit
import SwiftUI

@main
struct ItoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() { Theme.registerFonts() }

    var body: some Scene {
        Window("ito", id: "main") {
            RootView()
                .environmentObject(delegate.model)
                .frame(minWidth: 1020, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuContent().environmentObject(delegate.model)
        } label: {
            MenuLabel().environmentObject(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = AppModel()
    private var panel: CallPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Before the model exists, so this never touches the link or the real store.
        if ProcessInfo.processInfo.environment["ITO_AUDIOTEST"] != nil { return AudioTest.run() }
        #endif
        panel = CallPanelController(model: model)
        watchDigits()
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let dir = env["ITO_SNAPSHOT"], let host = env["ITO_HOST"] { Snapshot.run(model: model, dir: dir, host: host) }
        if let host = env["ITO_CALLTEST"] { CallTest.run(model: model, host: host) }
        #endif
    }

    /// During a call, digits typed anywhere in ito go to the call as keypad tones,
    /// except into a text field (the composer keeps its digits). The call panel
    /// handles its own keys.
    private func watchDigits() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let c = self.model.call, c.full, c.state == "active" || c.state == "dialing",
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers, key.count == 1, "0123456789*#".contains(key),
                  let window = NSApp.keyWindow, !(window is CallNSPanel),
                  !(window.firstResponder is NSText) else { return event }
            self.model.dtmf(key)
            return nil
        }
    }

    // Closing the window keeps ito running: texts and calls still arrive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuLabel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let n = model.unreadTotal
        Text(n > 0 ? "ito \(n)" : "ito")
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.linked ? "linked to \(model.paired?.name ?? "phone")" : "not linked")
        if let b = model.phone.battery, model.linked {
            Text("phone \(b)%" + (model.phone.charging ? " · charging" : ""))
        }
        Divider()
        Button("open ito") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

#if DEBUG
/// Dev only: pair with the fake phone, drive the UI through its main states,
/// write a PNG of each, quit. Scratch identity and store (see AppModel.init).
///   tools/snapshot.sh
@MainActor
enum Snapshot {
    static func run(model: AppModel, dir: String, host: String) {
        Task { @MainActor in
            func wait(_ what: String, _ seconds: Double = 15, _ ok: () -> Bool) async {
                let end = Date().addingTimeInterval(seconds)
                while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
                if !ok() { print("snapshot: timed out waiting for \(what)") }
            }
            @MainActor func snap(_ name: String, window: NSWindow? = nil) async {
                try? await Task.sleep(for: .milliseconds(700))
                guard let w = window ?? NSApp.windows.first(where: { $0.title == "ito" }), let v = w.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return print("snapshot: no window for \(name)") }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
                print("snapshot: \(name)")
            }

            await snap("0-unpaired")
            guard let phone = LinkClient.Found.manual(host) else { return }
            model.link.pair(with: phone)
            await wait("code") { if case .pairing(let c?, _, _) = model.linkState { return c.count == 6 } else { return false } }
            await snap("1-pairing")
            model.link.confirmPairing(true)
            await wait("sync") { model.linked && !model.syncing && !model.threads.isEmpty }

            model.saveGroup(id: nil, name: "trip", members: ["+15550100001", "+15550100002", "+15550100003"], relay: true)
            await wait("group") { model.selected?.hasPrefix("g:") == true }
            if let key = model.selected { model.send("dinner at 8? i'll book somewhere", to: key) }
            await wait("replies", 25) { model.messages(model.selected ?? "").count >= 3 }
            await snap("2-group")

            model.selected = model.threads.first { $0.group == nil && $0.numbers.count == 1 }?.id
            await snap("3-messages")
            model.section = .calls
            await snap("4-calls")
            model.section = .phone
            await snap("5-settings")
            model.section = .messages

            await wait("call", 25) { model.call?.state == "ringing" }
            await snap("6-call", window: NSApp.windows.first { $0 is NSPanel })
            await snap("7-callbar")
            NSApp.terminate(nil)
        }
    }
}
#endif

#if DEBUG
/// Dev only: a call out and a call in against the fake phone, on this Mac's real audio
/// devices: tools/calltest.sh. For each, when the call connected and when your mic was
/// flowing, from the click. Mic after connect = the start of the conversation lost to the
/// headset switching to call mode (and its tone). Then quits.
@MainActor
enum CallTest {
    static func run(model: AppModel, host: String) {
        Task { @MainActor in
            func wait(_ what: String, _ seconds: Double = 15, _ ok: () -> Bool) async {
                let end = Date().addingTimeInterval(seconds)
                while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
                if !ok() { print("calltest: timed out waiting for \(what)") }
            }
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm:ss.SSS"
            @MainActor func measure(_ label: String, _ act: @MainActor () -> Void) async {
                let t0 = Date()
                let sent = model.callStats.sent
                act()
                var active: Date?
                var heard: Date?
                await wait("\(label) connected and mic flowing", 12) {
                    if active == nil, model.call?.state == "active" { active = Date() }
                    if heard == nil, model.callStats.sent > sent + 5 { heard = Date() }
                    return active != nil && heard != nil
                }
                guard let active, let heard else { return }
                let late = heard.timeIntervalSince(active)
                print(String(format: "calltest: %@: clicked %@, connected +%.2f s, mic flowing +%.2f s → %@", label, clock.string(from: t0),
                             active.timeIntervalSince(t0), heard.timeIntervalSince(t0),
                             late > 0 ? String(format: "%.2f s of the call without your mic", late) : "mic ready before they could speak"))
                try? await Task.sleep(for: .seconds(4))
                model.hangup()
                await wait("\(label) ended") { model.call == nil || model.call?.state == "ended" }
            }

            guard let phone = LinkClient.Found.manual(host) else { return }
            model.link.pair(with: phone)
            await wait("code") { if case .pairing(let c?, _, _) = model.linkState { return c.count == 6 } else { return false } }
            model.link.confirmPairing(true)
            await wait("link") { model.linked && !model.syncing }
            await measure("call out") { model.dial("5550100001") }
            // The headset back in music mode, as between real calls.
            try? await Task.sleep(for: .seconds(6))
            print("calltest: ready for a ring")
            await wait("ring", 30) { model.call?.state == "ringing" }
            try? await Task.sleep(for: .seconds(1.5))
            await measure("call in") { model.answer() }
            try? await Task.sleep(for: .seconds(1))
            NSApp.terminate(nil)
        }
    }
}

/// Dev only: run the call-audio engine on this Mac's real devices, no phone, for
/// ITO_AUDIOTEST seconds (a number; default 15). That is long enough for a Bluetooth
/// headset to finish switching to call mode, about 5 s in, which is where calls died
/// and where a 3 s test never looked. A short beep goes in as the "downlink" every 4 s.
/// One line a second: mic frames out (50 = all of them), their peak, the devices, and
/// the longest the main thread froze. Passes if the mic delivered through the last 5 s.
@MainActor
enum AudioTest {
    static func run() {
        let seconds = Int(ProcessInfo.processInfo.environment["ITO_AUDIOTEST"] ?? "") ?? 15
        let audio = CallAudio()
        let frames = Counter()
        audio.onFrame = { frames.add($0) }
        audio.onError = { print("audiotest: error: \($0.localizedDescription)") }
        print("audiotest: devices: \(AudioTest.devices())")
        let began = Date()
        audio.onStarted = {
            print("audiotest: mic up after \(String(format: "%.1f", Date().timeIntervalSince(began))) s · \(audio.voiceProcessing ? "voice processing" : "split engines")")
        }
        audio.start()

        var phase = 0.0
        var seq: UInt32 = 0
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            var f = Data(capacity: 644)
            withUnsafeBytes(of: seq.bigEndian) { f.append(contentsOf: $0) }
            seq &+= 1
            for _ in 0..<320 {
                let v = Int16(sin(phase) * (seq % 200 < 15 ? 3000 : 0))   // 0.3 s of 440 Hz every 4 s
                withUnsafeBytes(of: v.littleEndian) { f.append(contentsOf: $0) }
                phase += 2 * .pi * 440 / 16_000
            }
            audio.play(f)
        }

        var last = Date()
        var stall = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            stall = max(stall, Date().timeIntervalSince(last) - 0.05)
            last = Date()
        }

        var tick = 0
        var tail = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            tick += 1
            let (n, peak) = frames.take()
            if tick > seconds - 5 { tail += n }
            print(String(format: "audiotest: %2d s  mic %2d frames, peak %5d  %@  main thread froze %.2f s", tick, n, peak, AudioTest.devices(), max(stall, 0)))
            stall = 0
            guard tick >= seconds else { return }
            t.invalidate()
            audio.stop()
            let ok = tail >= 225
            print("audiotest: \(ok ? "PASS" : "FAIL"): \(tail) of 250 mic frames in the last 5 s")
            exit(ok ? 0 : 2)
        }
    }

    static func devices() -> String {
        func name(_ sel: AudioObjectPropertySelector) -> String {
            var id = AudioObjectID(0)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return "?" }
            var cf: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            addr.mSelector = kAudioObjectPropertyName
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return "?" }
            var rate = Float64(0)
            size = UInt32(MemoryLayout<Float64>.size)
            addr.mSelector = kAudioDevicePropertyNominalSampleRate
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
            return "\(s) @\(Int(rate))"
        }
        return "in=\(name(kAudioHardwarePropertyDefaultInputDevice)) out=\(name(kAudioHardwarePropertyDefaultOutputDevice))"
    }

    /// Mic frames and their peak since the last take. Written on the audio thread.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var peak = 0
        func add(_ frame: Data) {
            var p = 0
            frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in stride(from: 4, to: raw.count - 1, by: 2) {
                    p = max(p, abs(Int(Int16(bitPattern: UInt16(raw[i]) | UInt16(raw[i + 1]) << 8))))
                }
            }
            lock.lock(); n += 1; peak = max(peak, p); lock.unlock()
        }
        func take() -> (Int, Int) {
            lock.lock(); defer { n = 0; peak = 0; lock.unlock() }
            return (n, peak)
        }
    }
}
#endif
