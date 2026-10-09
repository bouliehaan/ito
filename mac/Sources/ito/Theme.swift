import AppKit
import CoreText
import SwiftUI

/// The samo-server console language, native: a neutral black → grey → white
/// ladder, one mono face (Office Code Pro), hard corners everywhere, white as
/// the only accent, `//` section heads and `>` command titles. The brand is
/// always lowercase: "ito".
enum Theme {
    static let bg = Color(hex: 0x000000)
    static let elevated = Color(hex: 0x0d0d0d)
    static let surface = Color(hex: 0x151515)
    static let surface2 = Color(hex: 0x1f1f1f)
    static let high = Color(hex: 0x2b2b2b)
    static let line = Color.white.opacity(0.08)
    static let lineStrong = Color.white.opacity(0.15)
    static let text = Color(hex: 0xf2f2f2)
    static let dim = Color(hex: 0x9e9e9e)
    static let muted = Color(hex: 0x6a6a6a)
    static let ghost = Color(hex: 0x3a3a3a)
    static let accent = Color.white
    static let danger = Color(hex: 0xcf6f6f)

    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "OfficeCodePro-Bold" : "OfficeCodePro-Regular", size: size)
    }

    /// Fonts ship inside the app bundle; register them for this process only.
    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "otf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

// MARK: primitives

/// Small tracked caps. Labels only — never the wordmark.
struct Caps: View {
    let text: String
    var color: Color = Theme.muted
    var size: CGFloat = 12
    init(_ text: String, color: Color = Theme.muted, size: CGFloat = 12) {
        self.text = text; self.color = color; self.size = size
    }
    var body: some View {
        Text(text.uppercased()).font(Theme.mono(size)).tracking(size * 0.14).foregroundStyle(color)
    }
}

/// `// section`
struct SectionHead: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text("// \(text)").font(Theme.mono(13)).tracking(0.6).foregroundStyle(Theme.dim)
    }
}

struct Hairline: View {
    var vertical = false
    var strong = false
    var body: some View {
        Rectangle().fill(strong ? Theme.lineStrong : Theme.line)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// The one live-state mark: a white dot with a soft halo when on.
struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle().fill(on ? Theme.accent : Theme.ghost).frame(width: 7, height: 7)
            .shadow(color: on ? .white.opacity(0.9) : .clear, radius: on ? 5 : 0)
    }
}

struct ConsoleButton: ButtonStyle {
    enum Kind { case primary, ghost, danger }
    var kind: Kind = .ghost
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(compact ? 12 : 13, bold: true))
            .tracking(1.4)
            .textCase(.uppercase)
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 7 : 11)
            .foregroundStyle(foreground(configuration.isPressed))
            .background(background(configuration.isPressed))
            .overlay(Rectangle().strokeBorder(border, lineWidth: 1))
            .contentShape(Rectangle())
    }

    private func foreground(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return .black
        case .ghost: return pressed ? Theme.text : Theme.dim
        case .danger: return Theme.danger
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? Color(hex: 0xd8d8d8) : Theme.accent
        case .ghost, .danger: return pressed ? Theme.surface2 : .clear
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return Theme.accent
        case .ghost: return Theme.lineStrong
        case .danger: return Theme.danger.opacity(0.6)
        }
    }
}

/// Plain field on a surface, 1 px border that goes white on focus.
struct ConsoleField: View {
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var size: CGFloat = 15
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.muted), axis: axis)
            .textFieldStyle(.plain)
            .font(Theme.mono(size))
            .foregroundStyle(Theme.text)
            .lineLimit(axis == .vertical ? 1...8 : 1...1)
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(Rectangle().strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.lineStrong, lineWidth: 1))
    }
}

/// Technical-drawing corner ticks, as on the server's cards.
struct CornerTicks: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                let s: CGFloat = 12, w = g.size.width, h = g.size.height
                p.move(to: .init(x: 0, y: s)); p.addLine(to: .zero); p.addLine(to: .init(x: s, y: 0))
                p.move(to: .init(x: w - s, y: h)); p.addLine(to: .init(x: w, y: h)); p.addLine(to: .init(x: w, y: h - s))
            }
            .stroke(Theme.accent.opacity(0.55), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
            .overlay(CornerTicks())
    }
}

/// Faint dot grid, only where a pane is otherwise empty.
struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 30
            var y: CGFloat = 1
            while y < size.height {
                var x: CGFloat = 1
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(.white.opacity(0.06)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

enum Metrics {
    /// Every column's top bar is this tall, so their hairlines line up across the window.
    static let header: CGFloat = 72
}

enum Fmt {
    static func time(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm" }
        else if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 6 { f.dateFormat = "EEE" }
        else { f.dateFormat = "MMM d" }
        return f.string(from: d).lowercased()
    }

    static func stamp(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'today' · HH:mm" : "EEE MMM d · HH:mm"
        return f.string(from: d).lowercased()
    }

    static func clock(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static func duration(_ s: Int64) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
