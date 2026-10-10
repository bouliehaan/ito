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
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let dir = env["ITO_SNAPSHOT"], let host = env["ITO_HOST"] { Snapshot.run(model: model, dir: dir, host: host) }
        #endif
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
        Text(model.linked ? "linked to \(model.identity.phone?.name ?? "phone")" : "not linked")
        if let b = model.phone.battery, model.linked {
            Text("phone \(b)%" + (model.phone.plugged ? "" : " · unplugged"))
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
            NSApp.terminate(nil)
        }
    }
}
#endif

#if DEBUG
/// Dev only: run the call-audio engine on this Mac's real devices for 3 s, no phone.
/// Feeds a 440 Hz tone in as the "downlink", counts microphone frames out, prints, quits.
@MainActor
enum AudioTest {
    static func run() {
        let audio = CallAudio()
        let frames = Counter()
        audio.onFrame = { _ in frames.bump() }
        audio.onError = {
            print("audiotest: failed: \($0.localizedDescription)")
            exit(1)
        }
        print("audiotest: devices: \(AudioTest.devices())")
        let began = Date()
        audio.onStarted = {
            print("audiotest: started after \(String(format: "%.1f", Date().timeIntervalSince(began))) s · voice processing \(audio.voiceProcessing ? "on" : "off") · devices now: \(AudioTest.devices())")
            feed(audio, frames)
        }
        audio.start()
    }

    static func feed(_ audio: CallAudio, _ frames: Counter) {
        guard frames.value == 0 else { return }
        var phase = 0.0
        var seq: UInt32 = 0
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { t in
            var f = Data(capacity: 644)
            withUnsafeBytes(of: seq.bigEndian) { f.append(contentsOf: $0) }
            seq &+= 1
            for _ in 0..<320 {
                let v = Int16(sin(phase) * (seq < 40 ? 4000 : 0))   // ~0.8 s of tone, then silence
                withUnsafeBytes(of: v.littleEndian) { f.append(contentsOf: $0) }
                phase += 2 * .pi * 440 / 16_000
            }
            audio.play(f)
            if seq >= 150 {
                t.invalidate()
                audio.stop()
                print("audiotest: mic frames out = \(frames.value) (expect ~150)")
                exit(frames.value > 50 ? 0 : 2)
            }
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

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
#endif
