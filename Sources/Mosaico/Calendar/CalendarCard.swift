import SwiftUI

struct CalendarCard: View {
    var model: CalendarModel
    var ctx: WidgetContext

    static let baseWidth: CGFloat = 400
    static let cellHeight: CGFloat = 46
    static let gap: CGFloat = 4

    var body: some View {
        let m = Metrics(s: ctx.scale)
        TimelineView(.animation(minimumInterval: nil, paused: !model.animating)) { timeline in
            let t = timeline.date
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header(m)
                    subtitle(m)
                        .subtitleSwap(key: subtitleKey, m: m)
                        .padding(.top, m(4))
                    weekdays(m).padding(.top, m(16))
                    grid(m, now: t).padding(.top, m(8))
                }
                .padding(.horizontal, m(22))
                .padding(.top, m(20))
                .padding(.bottom, m(18))

                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)

                HStack(spacing: m(10)) { footer(m) }
                    .font(.system(size: m(13), weight: .medium))
                    .frame(height: m(52))
                    .padding(.horizontal, m(22))
            }
        }
        .onPreferenceChange(BarFrameKey.self) { ctx.barFrame = $0 }
        .onChange(of: ctx.pointer) { _, p in updateHover(p) }
        .widgetChrome(ctx: ctx, baseWidth: Self.baseWidth)
    }

    // MARK: - Cabecera

    private func header(_ m: Metrics) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: m(8)) {
            Text(model.monthTitle)
                .font(.system(size: m(28), weight: .semibold))
                .tracking(-0.5 * m.s)
                .foregroundStyle(.white)
                .contentTransition(.opacity)
            Text(model.yearTitle)
                .font(.system(size: m(15)))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
            HStack(spacing: m(4)) {
                if !model.isCurrentMonth {
                    navButton(m, label: AnyView(Text("Hoy").font(.system(size: m(12), weight: .semibold)))) {
                        model.goToToday()
                    }
                }
                navButton(m, label: AnyView(Image(systemName: "chevron.left"))) { model.shiftMonth(-1) }
                navButton(m, label: AnyView(Image(systemName: "chevron.right"))) { model.shiftMonth(1) }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + m(5) }
        }
        .animation(.easeOut(duration: 0.2), value: model.monthTitle)
    }

    private func navButton(_ m: Metrics, label: AnyView, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.system(size: m(11), weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(minWidth: m(26), minHeight: m(24))
                .padding(.horizontal, m(4))
                .background(RoundedRectangle(cornerRadius: m(7), style: .continuous).fill(.white.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subtítulo

    private var subtitleKey: String {
        if let i = model.hoveredIndex { return "day-\(i)" }
        return "today-\(model.monthTitle)"
    }

    @ViewBuilder private func subtitle(_ m: Metrics) -> some View {
        if let i = model.hoveredIndex, i < model.days.count {
            let d = model.days[i]
            HStack(spacing: m(7)) {
                Text(model.dayTitle(d)).foregroundStyle(.white.opacity(0.9))
                if d.events.isEmpty {
                    Text("Sin eventos").foregroundStyle(.white.opacity(0.35))
                } else {
                    Text(d.events.count == 1 ? "1 evento" : "\(d.events.count) eventos")
                        .foregroundStyle(.white.opacity(0.45))
                    Text(d.events.prefix(2).map { e in
                        e.allDay ? e.title : "\(model.timeText(e.start)) \(e.title)"
                    }.joined(separator: " · "))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                }
            }
            .font(.system(size: m(13), weight: .medium))
        } else if let today = model.days.first(where: \.isToday) {
            HStack(spacing: m(7)) {
                Circle().fill(Color(rgb: Palette.colors[0])).frame(width: m(6), height: m(6))
                Text("Hoy, \(model.dayTitle(today).lowercased())").foregroundStyle(.white.opacity(0.8))
                Text(today.events.isEmpty ? "· sin eventos"
                     : (today.events.count == 1 ? "· 1 evento" : "· \(today.events.count) eventos"))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .font(.system(size: m(13), weight: .medium))
        } else {
            Text("Mirá otro mes con las flechas.")
                .font(.system(size: m(13), weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Grilla

    private func weekdays(_ m: Metrics) -> some View {
        HStack(spacing: m(Self.gap)) {
            ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { i, sym in
                Text(sym)
                    .font(.system(size: m(10.5), weight: .semibold))
                    .foregroundStyle(.white.opacity(i >= 5 ? 0.25 : 0.38))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, m(6))
            }
        }
    }

    private func grid(_ m: Metrics, now: Date) -> some View {
        let days = model.days
        let hovered = model.hoveredIndex
        let reveal = now.timeIntervalSince(model.revealStart)
        let running = model.animating
        return Color.clear
            .frame(height: m(Self.cellHeight) * 6 + m(Self.gap) * 5)
            .background(GeometryReader { g in
                Color.clear.preference(key: BarFrameKey.self, value: g.frame(in: .global))
            })
            .overlay {
                Canvas { ctx, size in
                    CalendarGrid.draw(&ctx, size: size, s: m.s, days: days, hovered: hovered,
                                      reveal: reveal, running: running,
                                      t: now.timeIntervalSinceReferenceDate)
                }
                .padding(-m(12))
                .allowsHitTesting(false)
            }
    }

    private func updateHover(_ p: CGPoint?) {
        let f = ctx.barFrame
        var index: Int?
        if let p, f.width > 0, f.contains(p) {
            let s = ctx.scale
            let gap = Self.gap * s
            let cw = (f.width - gap * 6) / 7
            let ch = Self.cellHeight * s
            let col = Int((p.x - f.minX) / (cw + gap))
            let row = Int((p.y - f.minY) / (ch + gap))
            if (0..<7).contains(col), (0..<6).contains(row) { index = row * 7 + col }
        }
        if model.hoveredIndex != index { model.hoveredIndex = index }
    }

    // MARK: - Pie

    @ViewBuilder private func footer(_ m: Metrics) -> some View {
        switch model.access {
        case .unknown:
            Image(systemName: "calendar").foregroundStyle(.white.opacity(0.5)).frame(width: m(16))
            Text("Conectá tu calendario para ver tus eventos.")
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: m(8))
            ActionButton(title: "Permitir", m: m) { model.requestAccess() }
        case .denied:
            Image(systemName: "lock.fill").foregroundStyle(.white.opacity(0.45)).frame(width: m(16))
            Text("Mosaico no tiene acceso al Calendario.")
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: m(8))
            ActionButton(title: "Abrir Ajustes", m: m) { CalendarModel.openCalendarSettings() }
        case .granted:
            if let e = model.nextEvent {
                RoundedRectangle(cornerRadius: m(1.5))
                    .fill(Color(rgb: e.rgb))
                    .frame(width: m(8), height: m(8))
                    .frame(width: m(16))
                Text("Próximo").foregroundStyle(.white.opacity(0.45))
                Text(e.title).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer(minLength: m(8))
                Text(model.relative(e.start))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Image(systemName: "checkmark").foregroundStyle(Color(rgb: Palette.colors[1])).frame(width: m(16))
                Text("No tenés eventos en los próximos 14 días.")
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            }
        }
    }
}

/// Dibuja las 42 celdas: cada día es una mini matriz de píxeles que se "llena" desde abajo
/// según lo ocupado que esté, con los colores de sus calendarios.
enum CalendarGrid {
    static func draw(_ g: inout GraphicsContext, size: CGSize, s: CGFloat, days: [CalendarDay],
                     hovered: Int?, reveal: Double, running: Bool, t: Double) {
        let pad = 12 * s
        let area = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)
        let gap = CalendarCard.gap * s
        let cw = (area.width - gap * 6) / 7
        let ch = CalendarCard.cellHeight * s
        let radius = 7 * s
        let pitch = 4 * s
        let dot = 3 * s
        let accent = Palette.colors[0]

        for (i, d) in days.enumerated() {
            let row = i / 7, col = i % 7
            let rect = CGRect(x: area.minX + CGFloat(col) * (cw + gap),
                              y: area.minY + CGFloat(row) * (ch + gap), width: cw, height: ch)
            let shape = Path(roundedRect: rect, cornerRadius: radius)
            let isHovered = hovered == i
            let p = min(1, max(0, (reveal - Double(row + col) * 0.035) / 0.35))
            var fade = d.inMonth ? (d.isPast ? 0.55 : 1.0) : 0.22
            if hovered != nil && !isHovered { fade *= 0.75 }

            // Fondo y brillo de "hoy".
            if d.isToday {
                g.drawLayer { l in
                    l.addFilter(.blur(radius: 10 * s))
                    l.fill(shape, with: .color(Color(rgb: accent, opacity: 0.35 * p)))
                }
            }
            g.fill(shape, with: .color(.white.opacity((isHovered ? 0.075 : (d.inMonth ? 0.03 : 0.012)) * p)))

            // Matriz de píxeles.
            let inset = 5 * s
            let cols = max(1, Int((cw - inset * 2 + (pitch - dot)) / pitch))
            let rows = max(1, Int((ch - inset * 2 + (pitch - dot)) / pitch))
            let ox = rect.minX + (cw - (CGFloat(cols) * pitch - (pitch - dot))) / 2
            let oy = rect.minY + (ch - (CGFloat(rows) * pitch - (pitch - dot))) / 2
            let litRows = d.events.isEmpty ? 0 : max(1, Int((d.busyness * Double(rows) * 0.62).rounded()))
            let seed = d.day &* 31 &+ i
            for r in 0..<rows {
                let fromBottom = rows - 1 - r
                for c in 0..<cols {
                    let h = PixelBar.hash(c, r, seed)
                    guard PixelBar.hash(c, r, 999) < p else { continue }
                    let x = ox + CGFloat(c) * pitch
                    let y = oy + CGFloat(r) * pitch
                    if fromBottom < litRows {
                        let eventIndex = min(d.events.count - 1, c * d.events.count / cols)
                        let rgb = d.events[eventIndex].rgb
                        var lit = h < 0.78
                        if running, PixelBar.hash(c, r, Int(t * 3)) > 0.985 { lit.toggle() }
                        let a = (lit ? 0.9 : 0.22) * fade * (isHovered ? 1.0 : 0.92)
                        g.fill(Path(CGRect(x: x, y: y, width: dot, height: dot)),
                               with: .color(Color(rgb: rgb, opacity: a)))
                    } else if d.isToday {
                        let a = (h < 0.16 ? 0.55 : 0.1) * p
                        g.fill(Path(CGRect(x: x, y: y, width: dot, height: dot)),
                               with: .color(Color(rgb: accent, opacity: a)))
                    } else {
                        g.fill(Path(CGRect(x: x + dot * 0.3, y: y + dot * 0.3, width: dot * 0.4, height: dot * 0.4)),
                               with: .color(.white.opacity(0.06 * fade)))
                    }
                }
            }

            // Borde.
            if d.isToday {
                g.stroke(shape, with: .color(Color(rgb: accent, opacity: 0.95 * p)), lineWidth: 1.5 * s)
            } else if isHovered {
                g.stroke(shape, with: .color(.white.opacity(0.28)), lineWidth: 1)
            }

            // Número del día (con un fondito para que se lea sobre los píxeles).
            let numColor: Color = d.isToday ? .white
                : .white.opacity((d.inMonth ? (d.isWeekend ? 0.6 : 0.88) : 0.3) * (d.isPast && d.inMonth ? 0.6 : 1))
            let text = Text("\(d.day)")
                .font(.system(size: 12 * s, weight: d.isToday ? .bold : .semibold))
                .foregroundStyle(numColor.opacity(p))
            let resolved = g.resolve(text)
            let tsize = resolved.measure(in: CGSize(width: cw, height: ch))
            let tag = CGRect(x: rect.minX + 4 * s, y: rect.minY + 3 * s,
                             width: tsize.width + 5 * s, height: tsize.height + 1 * s)
            g.fill(Path(roundedRect: tag, cornerRadius: 3 * s),
                   with: .color(d.isToday ? Color(rgb: accent, opacity: 0.9 * p) : Color.black.opacity(0.42 * p)))
            g.draw(resolved, at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
        }
    }
}
