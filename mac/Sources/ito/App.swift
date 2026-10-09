import AppKit
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
            func snap(_ name: String, window: NSWindow? = nil) async {
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
