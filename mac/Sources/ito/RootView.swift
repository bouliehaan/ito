import ItoKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Rail()
                .frame(width: 252)
            Hairline(vertical: true)
            switch model.section {
            case .messages:
                ThreadsColumn().frame(width: 330)
                Hairline(vertical: true)
                if let key = model.selected {
                    ConversationView(key: key).id(key)
                } else {
                    Empty(title: model.threads.isEmpty ? "no messages yet" : "pick a thread", hint: "⌘N new message")
                }
            case .calls:
                CallsView()
            case .phone:
                PhoneView()
            }
        }
        // Content stays below the hidden title bar; only the colours run up under it.
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .overlay(alignment: .bottom) { NoticeBar() }
        .preferredColorScheme(.dark)
    }
}

/// Left rail: wordmark, the phone's vitals, the three places.
struct Rail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ito").font(Theme.mono(34, bold: true)).padding(.bottom, 4)
            Text("phone on your mac").font(Theme.mono(12)).foregroundStyle(Theme.muted)

            VStack(alignment: .leading, spacing: 9) {
                vital("link", linkText, on: model.linked)
                if model.linked {
                    if let b = model.phone.battery {
                        vital("battery", "\(b)%" + (model.phone.plugged ? "" : " · unplugged"), on: model.phone.plugged, warn: !model.phone.plugged)
                    }
                    vital("wi-fi calling", model.phone.ims, on: model.phone.ims == "wifi" || model.phone.ims == "cellular")
                }
            }
            .padding(.top, 28)

            VStack(alignment: .leading, spacing: 2) {
                SectionHead("phone").padding(.bottom, 8)
                nav(.messages, "01", "messages", badge: model.unreadTotal)
                nav(.calls, "02", "calls", badge: 0)
                nav(.phone, "03", "settings", badge: model.identity.phone == nil ? 1 : 0)
            }
            .padding(.top, 34)

            Spacer()
            if model.syncing {
                Caps("syncing…", color: Theme.dim, size: 11).padding(.bottom, 8)
            }
            if let p = model.identity.phone {
                Text(p.name).font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.elevated.ignoresSafeArea())
    }

    private var linkText: String {
        switch model.linkState {
        case .unpaired: return "not paired"
        case .searching: return "looking…"
        case .connecting: return "connecting…"
        case .pairing: return "pairing"
        case .linked: return "linked"
        case .failed: return "retrying"
        }
    }

    private func vital(_ k: String, _ v: String, on: Bool, warn: Bool = false) -> some View {
        HStack(spacing: 10) {
            StatusDot(on: on)
            Caps(k, size: 11)
            Spacer(minLength: 4)
            Text(v).font(Theme.mono(13)).foregroundStyle(warn ? Theme.danger : on ? Theme.text : Theme.dim).lineLimit(1)
        }
    }

    private func nav(_ s: Section, _ key: String, _ title: String, badge: Int) -> some View {
        let active = model.section == s
        return Button {
            model.section = s
        } label: {
            HStack(spacing: 12) {
                Text(key).font(Theme.mono(12)).foregroundStyle(active ? Theme.text : Theme.ghost)
                Text(title).font(Theme.mono(16, bold: active)).foregroundStyle(active ? Theme.text : Theme.dim)
                Spacer()
                if badge > 0 {
                    Text("\(badge)").font(Theme.mono(12, bold: true)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.accent)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(active ? Theme.surface2 : .clear)
            .overlay(alignment: .leading) { if active { Rectangle().fill(Theme.accent).frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ThreadsColumn: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var composing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ConsoleField(placeholder: "search", text: $query, size: 14)
                Button("new") { composing = true }
                    .buttonStyle(ConsoleButton(kind: .primary, compact: true))
                    .keyboardShortcut("n")
                    .disabled(!model.linked)
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.header)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { t in
                        ThreadRow(thread: t, selected: model.selected == t.id)
                            .onTapGesture { model.selected = t.id }
                        Hairline()
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .background(Theme.bg)
        .sheet(isPresented: $composing) { NewMessageSheet().environmentObject(model) }
    }

    private var filtered: [ThreadSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.threads }
        let digits = q.filter(\.isNumber)
        return model.threads.filter { t in
            t.title.lowercased().contains(q)
                || (!digits.isEmpty && t.numbers.contains { $0.filter(\.isNumber).contains(digits) })
                || model.messages(t.id).contains { $0.body.lowercased().contains(q) }
        }
    }
}

struct ThreadRow: View {
    @EnvironmentObject var model: AppModel
    let thread: ThreadSummary
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(thread.unread > 0 ? Theme.accent : .clear).frame(width: 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    if thread.group != nil {
                        Text("#").font(Theme.mono(15)).foregroundStyle(Theme.muted)
                    }
                    Text(thread.title).font(Theme.mono(15, bold: thread.unread > 0)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(thread.last.map { Fmt.time($0.date) } ?? "").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
                Text(preview).font(Theme.mono(13)).foregroundStyle(thread.unread > 0 ? Theme.text : Theme.dim)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 13)
        .padding(.trailing, 16)
        .background(selected ? Theme.surface2 : Theme.bg)
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard let m = thread.last else {
            return thread.group.map { "\($0.relay ? "relay" : "broadcast") · \($0.members.count) people" } ?? ""
        }
        switch m.kind {
        case .mmsUndownloaded: return "picture message (not downloaded)"
        case .mms where m.body.isEmpty: return "picture message"
        default: break
        }
        if !m.incoming { return "you: " + m.body }
        if thread.group != nil || thread.numbers.count > 1 {
            return model.displayName(m.sender).split(separator: " ").first.map { "\($0.lowercased()): " + m.body } ?? m.body
        }
        return m.body
    }
}

struct Empty: View {
    let title: String
    var hint: String = ""
    var body: some View {
        ZStack {
            DotGrid()
            VStack(spacing: 8) {
                Text(title).font(Theme.mono(15)).foregroundStyle(Theme.muted)
                if !hint.isEmpty { Text(hint).font(Theme.mono(12)).foregroundStyle(Theme.ghost) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

struct NoticeBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let n = model.notice {
            HStack(spacing: 14) {
                Text(n).font(Theme.mono(13)).foregroundStyle(Theme.text)
                Button("ok") { model.notice = nil }.buttonStyle(ConsoleButton(kind: .ghost, compact: true))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.high)
            .overlay(Rectangle().strokeBorder(Theme.lineStrong, lineWidth: 1))
            .padding(.bottom, 18)
            .task(id: n) {
                try? await Task.sleep(for: .seconds(8))
                if model.notice == n { model.notice = nil }
            }
        }
    }
}
