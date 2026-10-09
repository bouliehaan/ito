import AppKit
import Combine
import ItoKit
import SwiftUI

/// A small floating window for the live call, above everything, on every
/// Space. Rings (a looped system sound) while the phone rings.
@MainActor
final class CallPanelController {
    private var panel: NSPanel?
    private var cancel: AnyCancellable?
    private var ring: Timer?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        cancel = model.$call.receive(on: RunLoop.main).sink { [weak self] call in self?.update(call) }
    }

    private func update(_ call: CallInfo?) {
        if call?.state == "ringing" { startRinging() } else { stopRinging() }
        guard call != nil else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 250),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .black
            p.contentView = NSHostingView(rootView: CallPanelView().environmentObject(model))
            if let screen = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 360, y: screen.maxY - 20))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    private func startRinging() {
        guard ring == nil else { return }
        let sound = NSSound(named: "Glass")
        sound?.play()
        ring = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { _ in sound?.stop(); sound?.play() }
    }

    private func stopRinging() {
        ring?.invalidate()
        ring = nil
    }
}

struct CallPanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var keypad = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 14) {
                if let c = model.call {
                    HStack {
                        StatusDot(on: c.state == "active")
                        Caps(label(c), color: Theme.dim, size: 11)
                        Spacer()
                        if c.state == "active", c.since > 0 {
                            Text(Fmt.duration(Int64(ctx.date.timeIntervalSince1970) - c.since / 1000))
                                .font(Theme.mono(13)).foregroundStyle(Theme.dim)
                        }
                    }
                    Text(c.title).font(Theme.mono(22, bold: true)).lineLimit(1)
                    if !c.name.isEmpty { Text(Numbers.pretty(c.number)).font(Theme.mono(13)).foregroundStyle(Theme.muted) }
                    if keypad && c.state == "active" {
                        Keypad { model.dtmf($0) }.scaleEffect(0.7).frame(height: 170)
                    }
                    Spacer(minLength: 0)
                    controls(c)
                }
            }
            .padding(22)
            .frame(width: 340, alignment: .leading)
            .frame(minHeight: 250)
            .background(Theme.bg)
            .overlay(Rectangle().strokeBorder(Theme.lineStrong, lineWidth: 1))
            .overlay(CornerTicks())
            .foregroundStyle(Theme.text)
        }
    }

    private func label(_ c: CallInfo) -> String {
        switch c.state {
        case "ringing": return "incoming call"
        case "dialing": return "calling…"
        case "held": return "on hold"
        case "ended": return "call ended"
        default: return c.audio ? "on this mac" : "on the phone"
        }
    }

    @ViewBuilder private func controls(_ c: CallInfo) -> some View {
        switch c.state {
        case "ringing":
            HStack {
                Button("decline") { model.decline() }.buttonStyle(ConsoleButton(kind: .danger))
                Spacer()
                Button("answer") { model.answer() }.buttonStyle(ConsoleButton(kind: .primary)).disabled(!c.full)
            }
            if !c.full {
                Text("answering needs the system install").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
        case "ended":
            EmptyView()
        default:
            HStack(spacing: 8) {
                if c.audio {
                    Button(model.callMuted ? "unmute" : "mute") { model.callMuted.toggle() }
                        .buttonStyle(ConsoleButton(kind: model.callMuted ? .primary : .ghost, compact: true))
                } else if c.state == "active", c.full, model.phone.callAudio == "ok" {
                    Button("take it here") { model.takeCallHere() }.buttonStyle(ConsoleButton(kind: .primary, compact: true))
                }
                if c.full {
                    Button("keys") { keypad.toggle() }.buttonStyle(ConsoleButton(kind: keypad ? .primary : .ghost, compact: true))
                    Button(c.state == "held" ? "resume" : "hold") { model.hold(c.state != "held") }
                        .buttonStyle(ConsoleButton(kind: .ghost, compact: true))
                }
                Spacer()
                Button("end") { model.hangup() }.buttonStyle(ConsoleButton(kind: .danger, compact: true))
            }
        }
    }
}
