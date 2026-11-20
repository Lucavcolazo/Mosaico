import SwiftUI

/// Reloj digital de matriz de puntos. Los dígitos cambian punto por punto: los que se
/// apagan caen y se desvanecen, los que se prenden destellan. Abajo, 60 píxeles marcan
/// los segundos.
struct ClockCard: View {
    var ctx: WidgetContext
    /// Para capturas: hora fija.
    var fixedDate: Date? = nil

    static let baseWidth: CGFloat = 400

    private static let locale = Locale(identifier: "es_AR")

    var body: some View {
        let m = Metrics(s: ctx.scale)
        TimelineView(TickSchedule()) { timeline in
            let date = fixedDate ?? timeline.date
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.dateText(date))
                        .font(.system(size: m(13), weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 0)
                    Text(Self.zoneText(date))
                        .font(.system(size: m(12), weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Color.clear
                    .frame(height: m(ClockFace.height))
                    .overlay {
                        Canvas { g, size in
                            ClockFace.draw(&g, size: size, s: m.s,
                                           t: date.timeIntervalSinceReferenceDate)
                        }
                        .padding(-m(14))
                        .allowsHitTesting(false)
                    }
                    .padding(.top, m(18))
            }
            .padding(.horizontal, m(22))
            .padding(.top, m(18))
            .padding(.bottom, m(22))
        }
        .widgetChrome(ctx: ctx, baseWidth: Self.baseWidth)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "EEEE d 'de' MMMM"
        return f
    }()

    private static func dateText(_ d: Date) -> String {
        let text = dateFormatter.string(from: d)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func zoneText(_ d: Date) -> String {
        let tz = TimeZone.current
        let secs = tz.secondsFromGMT(for: d)
        let h = secs / 3600, mins = abs(secs % 3600) / 60
        let offset = "GMT" + (h >= 0 ? "+" : "") + "\(h)" + (mins > 0 ? String(format: ":%02d", mins) : "")
        guard let name = tz.localizedName(for: .shortGeneric, locale: locale), !name.hasPrefix("GMT") else { return offset }
        return "\(name.prefix(1).uppercased() + name.dropFirst()) · \(offset)"
    }
}

/// Cuadros densos (24 fps) solo durante el primer medio segundo de cada segundo, que es
/// cuando hay animación. El resto del tiempo el reloj no dibuja nada.
struct TickSchedule: TimelineSchedule {
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Iterator {
        Iterator(t: startDate.timeIntervalSinceReferenceDate, dense: mode != .lowFrequency)
    }

    struct Iterator: Sequence, IteratorProtocol {
        var t: Double
        let dense: Bool

        mutating func next() -> Date? {
            let out = t
            let base = floor(t)
            let step = t + 1.0 / 24
            if dense, step - base < 0.52 {
                t = step
            } else {
                t = base + 1
            }
            return Date(timeIntervalSinceReferenceDate: out)
        }
    }
}

enum ClockFace {
    static let height: CGFloat = 92
    static let bigPitch: CGFloat = 9
    static let bigDot: CGFloat = 7
    static let smallPitch: CGFloat = 4.5
    static let smallDot: CGFloat = 3.5
    static let morph = 0.32

    /// Glifos de 5×7.
    static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
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
        let line = Array(g[row])
        return line[col] == "1"
    }

    static func digits(_ t: Double) -> [Character] {
        let c = Calendar.current.dateComponents([.hour, .minute, .second],
                                                from: Date(timeIntervalSinceReferenceDate: t))
        return Array(String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0))
    }

    static func draw(_ g: inout GraphicsContext, size: CGSize, s: CGFloat, t: Double) {
        let pad = 14 * s
        let area = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)
        let second = floor(t)
        let frac = t - second
        let now = digits(t)
        let before = digits(second - 1)

        let bp = bigPitch * s, bd = bigDot * s
        let sp = smallPitch * s, sd = smallDot * s
        let bigH = 7 * bp - (bp - bd)
        let bigW = 25 * bp - (bp - bd)
        let smallW = 11 * sp - (sp - sd)
        let gapToSeconds = 14 * s
        let totalW = bigW + gapToSeconds + smallW
        let ox = area.minX + (area.width - totalW) / 2
        let oy = area.minY

        // Capas: brillo desenfocado por detrás y puntos nítidos encima.
        var crisp: [(CGRect, Color)] = []
        var bloom: [(CGRect, Color)] = []
        let white: SIMD3<Double> = [1, 1, 1]

        func glyph(_ slot: Int, at x0: CGFloat, y0: CGFloat, pitch: CGFloat, dot: CGFloat, tint: SIMD3<Double>) {
            let from = before[slot], to = now[slot]
            for r in 0..<7 {
                for c in 0..<5 {
                    let a = bit(from, c, r), b = bit(to, c, r)
                    var x = x0 + CGFloat(c) * pitch
                    var y = y0 + CGFloat(r) * pitch
                    var level: Double
                    var flash = 0.0
                    if a == b {
                        level = b ? 1 : 0
                    } else {
                        let delay = PixelBar.hash(c, r, slot) * 0.12
                        let p = min(1, max(0, (frac - delay) / morph))
                        let e = p * p * (3 - 2 * p)
                        if b {
                            level = e
                            flash = sin(p * .pi) * 0.9
                        } else {
                            level = 1 - e
                            y += CGFloat(e) * pitch * 1.4   // el punto "cae"
                            x += CGFloat(PixelBar.hash(c, r, slot + 7) - 0.5) * pitch * CGFloat(e)
                        }
                    }
                    let off = Color.white.opacity(0.055)
                    let cellRect = CGRect(x: x0 + CGFloat(c) * pitch, y: y0 + CGFloat(r) * pitch, width: dot, height: dot)
                    crisp.append((cellRect, off))
                    if level > 0.01 {
                        let rgb = tint + (white - tint) * min(1, 0.55 + flash)
                        let rect = CGRect(x: x, y: y, width: dot, height: dot)
                        crisp.append((rect, Color(rgb: rgb, opacity: level)))
                        bloom.append((rect.insetBy(dx: -dot * 0.2, dy: -dot * 0.2), Color(rgb: tint, opacity: level * 0.7)))
                    }
                }
            }
        }

        let tint = Palette.colors[4]
        // HH
        glyph(0, at: ox, y0: oy, pitch: bp, dot: bd, tint: tint)
        glyph(1, at: ox + 6 * bp, y0: oy, pitch: bp, dot: bd, tint: tint)
        // Dos puntos que respiran con cada segundo.
        let colonX = ox + 12 * bp
        let blink = 0.35 + 0.65 * (frac < 0.5 ? 1 - frac * 2 * 0.6 : 0.4 + (frac - 0.5) * 1.2)
        for r in [2, 4] {
            let rect = CGRect(x: colonX, y: oy + CGFloat(r) * bp, width: bd, height: bd)
            crisp.append((rect, Color(rgb: tint + (white - tint) * 0.5, opacity: blink)))
            bloom.append((rect, Color(rgb: tint, opacity: blink * 0.6)))
        }
        // MM
        glyph(2, at: ox + 14 * bp, y0: oy, pitch: bp, dot: bd, tint: tint)
        glyph(3, at: ox + 20 * bp, y0: oy, pitch: bp, dot: bd, tint: tint)
        // SS, más chicos y alineados abajo.
        let sx = ox + bigW + gapToSeconds
        let sy = oy + bigH - (7 * sp - (sp - sd))
        let secTint = Palette.colors[2]
        glyph(4, at: sx, y0: sy, pitch: sp, dot: sd, tint: secTint)
        glyph(5, at: sx + 6 * sp, y0: sy, pitch: sp, dot: sd, tint: secTint)

        // Barra de segundos: 60 píxeles con los colores de la paleta.
        let sec = Int(now[4].wholeNumberValue! * 10 + now[5].wholeNumberValue!)
        let barY = oy + bigH + 22 * s
        let bpitch = area.width / 60
        let bdot = min(bpitch - 1.5 * s, 5 * s)
        for i in 0..<60 {
            let x = area.minX + CGFloat(i) * bpitch + (bpitch - bdot) / 2
            let rect = CGRect(x: x, y: barY, width: bdot, height: bdot)
            let rgb = paletteColor(Double(i) / 59)
            var a: Double
            if sec == 0 {
                // Arranca un minuto nuevo: la barra se vacía de derecha a izquierda.
                let delay = Double(59 - i) / 59 * 0.35
                a = max(0, 1 - (frac - delay) / 0.15)
                if i == 0 { a = max(a, min(1, frac / 0.3)) }
            } else if i < sec {
                a = 0.85
            } else if i == sec {
                a = min(1, frac / 0.3)
            } else {
                a = 0
            }
            crisp.append((rect, Color.white.opacity(0.06)))
            if a > 0.01 {
                let head = i == sec ? 0.5 * (1 - min(1, frac / 0.5)) : 0
                crisp.append((rect, Color(rgb: rgb + (white - rgb) * head, opacity: a)))
                if i == sec || i == sec - 1 {
                    bloom.append((rect.insetBy(dx: -bdot * 0.4, dy: -bdot * 0.4), Color(rgb: rgb, opacity: a * 0.9)))
                }
            }
        }

        // Brillo "falso": dos halos translúcidos en vez de un desenfoque (mucho más barato).
        for (r, c) in bloom {
            let spread = r.width * 0.32
            g.fill(Path(roundedRect: r.insetBy(dx: -spread, dy: -spread), cornerRadius: r.width * 0.6),
                   with: .color(c.opacity(0.09)))
            g.fill(Path(roundedRect: r.insetBy(dx: -spread * 0.45, dy: -spread * 0.45), cornerRadius: r.width * 0.4),
                   with: .color(c.opacity(0.17)))
        }
        for (r, c) in crisp {
            g.fill(Path(roundedRect: r, cornerRadius: r.width * 0.18), with: .color(c))
        }
    }

    /// Recorre la paleta de punta a punta (0…1).
    static func paletteColor(_ f: Double) -> SIMD3<Double> {
        let colors = Palette.colors
        let x = max(0, min(1, f)) * Double(colors.count - 1)
        let i = Int(x)
        let j = min(colors.count - 1, i + 1)
        let k = x - Double(i)
        return colors[i] + (colors[j] - colors[i]) * k
    }
}
