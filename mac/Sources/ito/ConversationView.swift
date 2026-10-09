import ItoKit
import SwiftUI

struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    let key: String
    @State private var draft = ""
    @State private var editingGroup = false
    @State private var promoting = false

    private var thread: ThreadSummary? { model.thread(key) }
    private var isNew: Bool { key.hasPrefix("new:") }
    private var numbers: [String] { thread?.numbers ?? (isNew ? [String(key.dropFirst(4))] : []) }
    private var group: GroupDef? { thread?.group }
    /// An old MMS group: it cannot be answered as MMS without mobile data.
    private var isMmsGroup: Bool { group == nil && numbers.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            commandBar
            Hairline()
            transcript
            Hairline()
            if isMmsGroup { mmsGroupFooter } else { composer }
        }
        .background(Theme.bg)
        .onAppear { draft = model.drafts[key] ?? "" }
        .onDisappear { model.drafts[key] = draft }
        .sheet(isPresented: $editingGroup) {
            GroupEditor(group: group, prefill: []).environmentObject(model)
        }
        .sheet(isPresented: $promoting) {
            GroupEditor(group: nil, prefill: numbers).environmentObject(model)
        }
    }

    // MARK: command bar

    private var commandBar: some View {
        HStack(spacing: 12) {
            Text(">").font(Theme.mono(18)).foregroundStyle(Theme.muted)
            Text(title.uppercased()).font(Theme.mono(16, bold: true)).tracking(1.8).lineLimit(1)
            Text(subtitle).font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
            if group == nil, numbers.count == 1 {
                Button("call") { model.dial(numbers[0]) }
                    .buttonStyle(ConsoleButton(kind: .ghost, compact: true)).disabled(!model.linked || model.call != nil)
            }
            if group != nil {
                Button("edit group") { editingGroup = true }.buttonStyle(ConsoleButton(kind: .ghost, compact: true))
            }
        }
        .padding(.horizontal, 22)
        .frame(height: Metrics.header)
    }

    private var title: String {
        if let thread { return thread.title }
        return numbers.first.map(model.displayName) ?? ""
    }

    private var subtitle: String {
        if let g = group { return (g.relay ? "relay" : "broadcast") + " · \(g.members.count) people" }
        if numbers.count == 1, model.store.name(for: numbers[0]) != nil { return Numbers.pretty(numbers[0]) }
        if numbers.count > 1 { return "mms group · \(numbers.count) people" }
        return ""
    }

    // MARK: transcript

    private enum Row: Identifiable {
        case day(String, String)
        case message(Message, showSender: Bool)
        case echo(Echo)
        var id: String {
            switch self {
            case .day(let id, _): return id
            case .message(let m, _): return m.id
            case .echo(let e): return "e" + e.cid
            }
        }
    }

    private var rows: [Row] {
        var out: [Row] = []
        var lastDate: Int64 = 0
        var lastSender = ""
        let multi = group != nil || numbers.count > 1
        for m in model.messages(key) {
            if m.date - lastDate > 3_600_000 {
                out.append(.day("d\(m.date)", Fmt.stamp(m.date)))
                lastSender = ""
            }
            let who = m.incoming ? Numbers.key(m.sender) : "me"
            out.append(.message(m, showSender: multi && m.incoming && who != lastSender))
            lastSender = who
            lastDate = m.date
        }
        for e in model.echoes where e.thread == key { out.append(.echo(e)) }
        return out
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        switch row {
                        case .day(_, let text):
                            Text("— \(text) —").font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                        case .message(let m, let showSender):
                            Bubble(message: m, showSender: showSender, groupId: group?.id)
                        case .echo(let e):
                            EchoBubble(echo: e)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: rows.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                ConsoleField(placeholder: model.linked ? placeholder : "phone not linked", text: $draft, axis: .vertical, onSubmit: send)
                    .disabled(!model.linked)
                Button("send", action: send)
                    .buttonStyle(ConsoleButton(kind: .primary))
                    .disabled(!model.linked || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(footer).font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.elevated)
    }

    private var placeholder: String {
        if let g = group { return g.relay ? "to everyone in \(g.name)" : "to each of \(g.members.count), separately" }
        return "text"
    }

    private var footer: String {
        var parts: [String] = []
        let n = Sms.segments(draft)
        if n > 1 { parts.append("\(n) sms") }
        if let g = group {
            parts.append(g.relay ? "relay: replies go to everyone" : "broadcast: replies come only to you")
        }
        parts.append("⏎ send · ⌥⏎ new line")
        return parts.joined(separator: " · ")
    }

    private func send() {
        let text = draft
        guard model.linked, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.send(text, to: key)
        draft = ""
        model.drafts[key] = nil
    }

    private var mmsGroupFooter: some View {
        HStack(spacing: 14) {
            Text("an mms group. mms needs mobile data the phone does not have.")
                .font(Theme.mono(13)).foregroundStyle(Theme.dim)
            Spacer()
            Button("make it an ito group") { promoting = true }.buttonStyle(ConsoleButton(kind: .primary, compact: true))
        }
        .padding(18)
        .background(Theme.elevated)
    }
}

struct Bubble: View {
    @EnvironmentObject var model: AppModel
    let message: Message
    let showSender: Bool
    let groupId: String?

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if !message.incoming { Spacer(minLength: 90) }
            VStack(alignment: message.incoming ? .leading : .trailing, spacing: 4) {
                if showSender {
                    Caps(model.displayName(message.sender), color: Theme.dim, size: 10.5).padding(.top, 6)
                }
                content
                Text(meta).font(Theme.mono(11)).foregroundStyle(message.status == .failed ? Theme.danger : Theme.muted)
            }
            if message.incoming { Spacer(minLength: 90) }
        }
        .contextMenu { menu }
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .mmsUndownloaded:
            VStack(alignment: .leading, spacing: 4) {
                Text("picture message — not downloaded").font(Theme.mono(14)).foregroundStyle(Theme.dim)
                Text("mms rides mobile data. ask them to send it as a text.").font(Theme.mono(12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(Rectangle().strokeBorder(Theme.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        case .mms, .text:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.parts.filter { $0.ct.hasPrefix("image/") }, id: \.pid) { p in
                    if let img = model.parts[p.pid] {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 300, maxHeight: 360)
                    } else {
                        Button("show picture") { model.loadPart(p.pid) }.buttonStyle(ConsoleButton(kind: .ghost, compact: true))
                    }
                }
                if !message.body.isEmpty {
                    Text(message.body).font(Theme.mono(15)).lineSpacing(3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 560, alignment: .leading)
            .background(message.incoming ? Theme.surface : Theme.surface2)
            .overlay(Rectangle().strokeBorder(message.incoming ? Theme.line : Theme.lineStrong, lineWidth: 1))
        }
    }

    private var meta: String {
        var parts = [Fmt.clock(message.date)]
        if message.recipients > 0 { parts.append("→ \(message.recipients)") }
        switch message.status {
        case .pending: parts.append("sending…")
        case .sent: parts.append("sent")
        case .delivered: parts.append("delivered")
        case .failed:
            parts.append(message.failedTo.isEmpty ? "failed" : "failed: " + message.failedTo.map(model.displayName).joined(separator: ", "))
        case .none: break
        }
        if message.relayedTo > 0 { parts.append("relayed to \(message.relayedTo)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var menu: some View {
        Button("copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.body, forType: .string)
        }
        if message.incoming, let id = message.smsId {
            if groupId != nil {
                Button("move out of the group (to a 1:1)") { model.refile(id, to: nil) }
            } else {
                ForEach(model.store.groups.filter { g in g.members.contains { Numbers.key($0) == Numbers.key(message.sender) } }, id: \.id) { g in
                    Button(g.relay ? "move into #\(g.name) and relay it" : "move into #\(g.name)") { model.refile(id, to: g.id) }
                }
            }
        }
    }
}

struct EchoBubble: View {
    let echo: Echo
    var body: some View {
        HStack {
            Spacer(minLength: 90)
            VStack(alignment: .trailing, spacing: 4) {
                Text(echo.body).font(Theme.mono(15)).lineSpacing(3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(Theme.surface2.opacity(0.6))
                    .overlay(Rectangle().strokeBorder(Theme.lineStrong, lineWidth: 1))
                Text(echo.failed ? "failed" : "sending…").font(Theme.mono(11)).foregroundStyle(echo.failed ? Theme.danger : Theme.muted)
            }
        }
    }
}

extension Sms {
    /// How many SMS a text will cost: GSM-7 fits 160 (153 per part), anything else 70 (67).
    static func segments(_ s: String) -> Int {
        if s.isEmpty { return 1 }
        let gsm = s.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 10 }
        let n = gsm ? s.count : s.utf16.count
        let (single, multi) = gsm ? (160, 153) : (70, 67)
        return n <= single ? 1 : (n + multi - 1) / multi
    }
}
