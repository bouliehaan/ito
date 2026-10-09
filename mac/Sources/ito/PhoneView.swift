import ItoKit
import SwiftUI

/// Pairing, the phone's state, and the few settings there are.
struct PhoneView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmForget = false
    @State private var address = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 12) {
                    Text(">").font(Theme.mono(18)).foregroundStyle(Theme.muted)
                    Text("SETTINGS").font(Theme.mono(16, bold: true)).tracking(1.8)
                }
                if model.identity.phone == nil || isPairing { pairing } else { phoneCard }
                linkSettings
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
    }

    private var isPairing: Bool { if case .pairing = model.linkState { return true } else { return false } }

    // MARK: pairing

    @ViewBuilder private var pairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHead("pair a phone")
            switch model.linkState {
            case .pairing(let code, let name, let confirmed):
                Card {
                    if let code {
                        Caps("does \(name) show")
                        Text(code.prefix(3) + " " + code.suffix(3)).font(Theme.mono(46, bold: true)).tracking(4)
                        Text(confirmed ? "waiting for the phone…" : "same six digits on both screens means nobody is in between.")
                            .font(Theme.mono(13)).foregroundStyle(Theme.muted)
                        if !confirmed {
                            HStack {
                                Button("it matches") { model.link.confirmPairing(true) }.buttonStyle(ConsoleButton(kind: .primary))
                                Button("no") { model.link.confirmPairing(false) }.buttonStyle(ConsoleButton(kind: .danger))
                            }
                        }
                    } else {
                        Text("talking to \(name)…").font(Theme.mono(15)).foregroundStyle(Theme.dim)
                    }
                }
                Button("cancel") { model.link.cancelPairing() }.buttonStyle(ConsoleButton(kind: .ghost, compact: true))
            default:
                VStack(alignment: .leading, spacing: 10) {
                    step("1", "on the phone, open ito and tap pair a mac.")
                    step("2", "pick it below. both screens show a six-digit code.")
                    step("3", "if the codes match, accept on both.")
                }
                if case .failed(let why) = model.linkState {
                    Text(why).font(Theme.mono(13)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
                Caps("phones on this network").padding(.top, 8)
                if model.found.isEmpty {
                    Text("none yet. same wi-fi? ito open on the phone?").font(Theme.mono(14)).foregroundStyle(Theme.muted)
                }
                HStack {
                    ConsoleField(placeholder: "or pair by address: 192.168.1.20", text: $address, size: 14).frame(width: 320)
                    Button("pair") { if let f = LinkClient.Found.manual(address) { model.link.pair(with: f) } }
                        .buttonStyle(ConsoleButton(kind: .ghost, compact: true))
                        .disabled(LinkClient.Found.manual(address) == nil)
                }
                ForEach(model.found, id: \.self) { f in
                    HStack {
                        Text(f.name).font(Theme.mono(15))
                        Spacer()
                        Button("pair") { model.link.pair(with: f) }.buttonStyle(ConsoleButton(kind: .primary, compact: true))
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .background(Theme.surface)
                    .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
                }
            }
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(n).font(Theme.mono(12)).foregroundStyle(Theme.ghost)
            Text(text).font(Theme.mono(14)).foregroundStyle(Theme.dim)
        }
    }

    // MARK: phone

    private var phoneCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHead("phone")
            Card {
                Text(model.identity.phone?.name ?? "phone").font(Theme.mono(20, bold: true))
                row("link", linkText)
                if model.linked {
                    row("number", model.phone.number.isEmpty ? "unknown" : Numbers.pretty(model.phone.number))
                    row("android", "\(model.phone.android) · \(model.phone.model)")
                    if let b = model.phone.battery {
                        row("battery", "\(b)%" + (model.phone.plugged ? " · on power" : " · NOT on power"), warn: !model.phone.plugged)
                    }
                    row("wi-fi calling", model.phone.ims)
                    row("texts", model.phone.smsOK ? "ok" : "permissions missing on the phone", warn: !model.phone.smsOK)
                    row("calls", model.phone.system ? "full control" : "ringing + decline (system install needed)", warn: !model.phone.system)
                    row("call audio", audioText, warn: model.phone.callAudio != "ok")
                }
                row("key", model.identity.phone?.fingerprint ?? "")
            }
            HStack {
                Button(confirmForget ? "really forget it" : "forget this phone") {
                    if confirmForget { model.forgetPhone(); confirmForget = false } else { confirmForget = true }
                }
                .buttonStyle(ConsoleButton(kind: .danger, compact: true))
                if confirmForget {
                    Text("removes the pairing and every message stored on this mac").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var audioText: String {
        switch model.phone.callAudio {
        case "ok": return "over the link"
        case "unsupported": return "this rom does not expose call audio"
        case "needs-system-install": return "needs the system install"
        default: return model.phone.callAudio
        }
    }

    private var linkText: String {
        switch model.linkState {
        case .linked: return "linked"
        case .searching: return "looking for it on the network…"
        case .connecting(let to): return "connecting to \(to)…"
        case .failed(let why): return why
        case .pairing: return "pairing"
        case .unpaired: return "not paired"
        }
    }

    private func row(_ k: String, _ v: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Caps(k, size: 11).frame(width: 130, alignment: .leading)
            Text(v).font(Theme.mono(14)).foregroundStyle(warn ? Theme.danger : Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: link

    private var linkSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHead("away from home")
            Text("on the same wi-fi ito finds the phone by itself. elsewhere, put the phone's address here (a tailscale ip works). the link is end-to-end encrypted and the phone only talks to the mac it paired with.")
                .font(Theme.mono(13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                ConsoleField(placeholder: "100.x.y.z:6969", text: $model.manualHost, size: 14).frame(width: 320)
                Button("reconnect") { model.link.reconnectNow() }.buttonStyle(ConsoleButton(kind: .ghost, compact: true))
            }
        }
    }
}
