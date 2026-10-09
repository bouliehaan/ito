import ItoKit
import SwiftUI

/// Recents on the left, a dialer that is also a contact search on the right.
struct CallsView: View {
    @EnvironmentObject var model: AppModel
    @State private var entry = ""

    var body: some View {
        HStack(spacing: 0) {
            recents.frame(width: 360)
            Hairline(vertical: true)
            dialer
        }
        .background(Theme.bg)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead("recent").padding(.horizontal, 20).frame(height: Metrics.header)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.store.calls.values.sorted { $0.d > $1.d }.prefix(300), id: \.id) { c in
                        Button { entry = c.n } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(c.nm.isEmpty ? model.displayName(c.n) : c.nm).font(Theme.mono(15))
                                        .foregroundStyle(c.missed ? Theme.danger : Theme.text)
                                    Text(kind(c)).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Text(Fmt.time(c.d)).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("call") { model.dial(c.n) }
                            Button("text") { model.open(number: c.n) }
                        }
                        Hairline()
                    }
                }
            }
        }
    }

    private func kind(_ c: CallRow) -> String {
        let k: String
        switch c.ty {
        case 1: k = "incoming"
        case 2: k = "outgoing"
        case 3: k = "missed"
        case 4: k = "voicemail"
        case 5: k = "declined"
        case 6: k = "blocked"
        default: k = "call"
        }
        return c.dur > 0 ? "\(k) · \(Fmt.duration(c.dur))" : k
    }

    private var matches: [Contact] {
        let q = entry.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2, q.contains(where: \.isLetter) else { return [] }
        return Array(model.store.contacts.filter { $0.n.lowercased().contains(q) }.prefix(5))
    }

    private var dialer: some View {
        VStack(spacing: 22) {
            Spacer()
            ConsoleField(placeholder: "number or name", text: $entry, size: 26, onSubmit: { if matches.isEmpty { call() } })
                .frame(width: 360)
            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches, id: \.k) { c in
                        Button { entry = c.p.first ?? "" } label: {
                            HStack {
                                Text(c.n).font(Theme.mono(14))
                                Spacer()
                                Text(c.p.first.map(Numbers.pretty) ?? "").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Hairline()
                    }
                }
                .frame(width: 360)
            }
            Keypad { d in entry.append(d) }
            HStack(spacing: 12) {
                Button("del") { if !entry.isEmpty { entry.removeLast() } }.buttonStyle(ConsoleButton(kind: .ghost))
                Button("call", action: call).buttonStyle(ConsoleButton(kind: .primary))
                    .disabled(!model.linked || model.call != nil || entry.filter(\.isNumber).isEmpty)
            }
            if !model.linked {
                Text("phone not linked").font(Theme.mono(12)).foregroundStyle(Theme.muted)
            } else if model.phone.callAudio != "ok" {
                Text("calls ring here, but audio stays on the phone until the system install is done (settings)")
                    .font(Theme.mono(12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(width: 360)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func call() {
        model.dial(entry)
    }
}

struct Keypad: View {
    let press: (String) -> Void
    private let keys = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]
    var body: some View {
        VStack(spacing: 8) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { k in
                        Button { press(k) } label: {
                            Text(k).font(Theme.mono(22)).frame(width: 72, height: 54)
                                .background(Theme.surface)
                                .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
