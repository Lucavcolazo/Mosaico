import SwiftUI

/// Reloj digital minimalista de matriz de puntos: solo HH:MM en blanco.
/// Al cambiar el minuto, los puntos que se apagan caen y los que se prenden aparecen.
struct ClockCard: View {
    var ctx: WidgetContext
    /// Para capturas: hora fija.
    var fixedDate: Date? = nil

    static let baseWidth: CGFloat = 300

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_AR")
        f.dateFormat = "EEEE d 'de' MMMM"
        return f
    }()

    var body: some View {
        let m = Metrics(s: ctx.scale)
        TimelineView(MinuteSchedule()) { timeline in
            let date = fixedDate ?? timeline.date
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.dateText(date))
                    .font(.system(size: m(13), weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Color.clear
                    .frame(height: m(ClockFace.height))
                    .overlay {
                        Canvas { g, size in
                            ClockFace.draw(&g, size: size, s: m.s, t: date.timeIntervalSinceReferenceDate)
                        }
                        .padding(-m(14))
                        .allowsHitTesting(false)
                    }
                    .padding(.top, m(16))
            }
            .padding(.horizontal, m(22))
            .padding(.top, m(18))
            .padding(.bottom, m(24))
        }
        .widgetChrome(ctx: ctx, baseWidth: Self.baseWidth)
    }

    private static func dateText(_ d: Date) -> String {
        let text = dateFormatter.string(from: d)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Solo dibuja cuando cambia el minuto: unos cuadros seguidos durante la animación y
/// después nada hasta el minuto siguiente.
struct MinuteSchedule: TimelineSchedule {
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Iterator {
        Iterator(t: startDate.timeIntervalSinceReferenceDate, dense: mode != .lowFrequency)
    }

    struct Iterator: Sequence, IteratorProtocol {
        var t: Double
        let dense: Bool

        mutating func next() -> Date? {
            let out = t
            let minuteStart = ClockFace.minuteStart(t)
            let step = t + 1.0 / 30
            if dense, step - minuteStart < ClockFace.animationLength {
                t = step
            } else {
                t = minuteStart + 60
            }
            return Date(timeIntervalSinceReferenceDate: out)
        }
    }
}

enum ClockFace {
    static let height: CGFloat = 61
    static let pitch: CGFloat = 9
    static let dot: CGFloat = 7
    static let morph = 0.4
    static let animationLength = 0.6

    /// Glifos de 5×7.
    static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    ]

    static func bit(_ ch: Character, _ col: Int, _ row: Int) -> Bool {
        guard let g = glyphs[ch] else { return false }
        return Array(g[row])[col] == "1"
    }

    /// Comienzo del minuto (en hora local) que contiene `t`.
    static func minuteStart(_ t: Double) -> Double {
        let date = Date(timeIntervalSinceReferenceDate: t)
        let sec = Calendar.current.component(.second, from: date)
        return floor(t) - Double(sec)
    }

    static func digits(_ t: Double) -> [Character] {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSinceReferenceDate: t))
        return Array(String(format: "%02d%02d", c.hour ?? 0, c.minute ?? 0))
    }

    static func draw(_ g: inout GraphicsContext, size: CGSize, s: CGFloat, t: Double) {
        let pad = 14 * s
        let area = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)
        let start = minuteStart(t)
        let frac = t - start
        let now = digits(t)
        let before = digits(start - 1)

        let p = pitch * s, d = dot * s
        let totalW = 25 * p - (p - d)
        let ox = area.minX + (area.width - totalW) / 2
        let oy = area.minY
        let radius = d * 0.2

        func fill(_ rect: CGRect, _ opacity: Double) {
            g.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(.white.opacity(opacity)))
        }

        func glyph(_ slot: Int, x0: CGFloat) {
            let from = before[slot], to = now[slot]
            for r in 0..<7 {
                for c in 0..<5 {
                    let home = CGRect(x: x0 + CGFloat(c) * p, y: oy + CGFloat(r) * p, width: d, height: d)
                    fill(home, 0.03)
                    let a = bit(from, c, r), b = bit(to, c, r)
                    if a == b {
                        if b { fill(home, 0.92) }
                        continue
                    }
                    let delay = PixelBar.hash(c, r, slot) * 0.15
                    let k = min(1, max(0, (frac - delay) / morph))
                    let e = k * k * (3 - 2 * k)
                    if b {
                        fill(home, 0.92 * e)
                    } else {
                        fill(home.offsetBy(dx: 0, dy: CGFloat(e) * p * 1.2), 0.92 * (1 - e))
                    }
                }
            }
        }

        glyph(0, x0: ox)
        glyph(1, x0: ox + 6 * p)
        for r in [2, 4] {
            fill(CGRect(x: ox + 12 * p, y: oy + CGFloat(r) * p, width: d, height: d), 0.6)
        }
        glyph(2, x0: ox + 14 * p)
        glyph(3, x0: ox + 20 * p)
    }
}
