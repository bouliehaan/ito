import ItoKit
import SwiftUI

/// Pick people by name or number. Used by "new" and by the group editor.
struct RecipientPicker: View {
    @EnvironmentObject var model: AppModel
    @Binding var chosen: [String]
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !chosen.isEmpty {
                FlowRow(items: chosen) { n in
                    HStack(spacing: 8) {
                        Text(model.displayName(n)).font(Theme.mono(13))
                        Button("×") { chosen.removeAll { $0 == n } }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.surface2)
                    .overlay(Rectangle().strokeBorder(Theme.lineStrong, lineWidth: 1))
                }
            }
            ConsoleField(placeholder: "name or number", text: $query, onSubmit: addTyped)
            VStack(spacing: 0) {
                ForEach(suggestions, id: \.self) { n in
                    Button { add(n) } label: {
                        HStack {
                            Text(model.store.name(for: n) ?? "use this number").font(Theme.mono(14))
                            Spacer()
                            Text(Numbers.pretty(n)).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Hairline()
                }
            }
        }
    }

    private var suggestions: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var out: [String] = []
        let digits = q.filter(\.isNumber)
        if digits.count >= 3 && q.allSatisfy({ $0.isNumber || "+()- ".contains($0) }) { out.append(q) }
        for c in model.store.contacts where c.n.lowercased().contains(q) || (!digits.isEmpty && c.p.contains { $0.filter(\.isNumber).contains(digits) }) {
            for p in c.p where !out.contains(where: { Numbers.key($0) == Numbers.key(p) }) { out.append(p) }
            if out.count >= 7 { break }
        }
        return out.filter { n in !chosen.contains { Numbers.key($0) == Numbers.key(n) } }
    }

    private func add(_ n: String) {
        chosen.append(n)
        query = ""
    }

    private func addTyped() {
        if let first = suggestions.first { add(first) }
    }
}

/// Wraps chips onto lines.
struct FlowRow<Item: Hashable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell
    var body: some View {
        FlowLayout(spacing: 8) { ForEach(items, id: \.self) { cell($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 600, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, p) in r.points.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified) }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        var pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += line + spacing; line = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += sz.width + spacing
            line = max(line, sz.height)
            widest = max(widest, x)
        }
        return (CGSize(width: widest, height: y + line), pts)
    }
}

/// "new": one person opens a 1:1; two or more becomes an ito group.
struct NewMessageSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [String] = []
    @State private var name = ""
    @State private var relay = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("> NEW").font(Theme.mono(16, bold: true)).tracking(1.8)
            Caps("to")
            RecipientPicker(chosen: $chosen)
            if chosen.count > 1 {
                GroupOptions(name: $name, relay: $relay)
            }
            Spacer(minLength: 0)
            HStack {
                Button("cancel") { dismiss() }.buttonStyle(ConsoleButton(kind: .ghost)).keyboardShortcut(.cancelAction)
                Spacer()
                Button(chosen.count > 1 ? "create group" : "start") {
                    if chosen.count > 1 {
                        model.saveGroup(id: nil, name: name, members: chosen, relay: relay)
                    } else if let n = chosen.first {
                        model.open(number: n)
                    }
                    dismiss()
                }
                .buttonStyle(ConsoleButton(kind: .primary))
                .disabled(chosen.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 520, height: 560)
        .background(Theme.bg)
    }
}

struct GroupOptions: View {
    @Binding var name: String
    @Binding var relay: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caps("group name")
            ConsoleField(placeholder: "e.g. trip", text: $name)
            Toggle(isOn: $relay) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("relay replies to everyone").font(Theme.mono(14))
                    Text(relay
                         ? "a real group chat through your number. a reply from one person is forwarded to the others as \"name: text\". the first text each person gets says it's a group and who's in it. replies more than 2 h after the conversation goes quiet come only to you."
                         : "everyone gets your message separately; replies come back only to you, threaded here. nobody sees anybody else.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(BoxToggle())
        }
    }
}

/// [x] checkbox, console style.
struct BoxToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(configuration.isOn ? "[x]" : "[ ]").font(Theme.mono(14, bold: true))
                    .foregroundStyle(configuration.isOn ? Theme.text : Theme.muted)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct GroupEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let group: GroupDef?
    let prefill: [String]
    @State private var name = ""
    @State private var members: [String] = []
    @State private var relay = true
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(group == nil ? "> NEW GROUP" : "> EDIT GROUP").font(Theme.mono(16, bold: true)).tracking(1.8)
            Caps("people")
            RecipientPicker(chosen: $members)
            GroupOptions(name: $name, relay: $relay)
            Spacer(minLength: 0)
            HStack {
                Button("cancel") { dismiss() }.buttonStyle(ConsoleButton(kind: .ghost)).keyboardShortcut(.cancelAction)
                if let group {
                    Button(confirmDelete ? "really delete" : "delete group") {
                        if confirmDelete { model.deleteGroup(group.id); dismiss() } else { confirmDelete = true }
                    }
                    .buttonStyle(ConsoleButton(kind: .danger))
                }
                Spacer()
                Button("save") {
                    model.saveGroup(id: group?.id, name: name, members: members, relay: relay)
                    dismiss()
                }
                .buttonStyle(ConsoleButton(kind: .primary))
                .disabled(members.count < 2)
            }
        }
        .padding(28)
        .frame(width: 540, height: 620)
        .background(Theme.bg)
        .onAppear {
            name = group?.name ?? ""
            members = group?.members ?? prefill
            relay = group?.relay ?? true
        }
    }
}
