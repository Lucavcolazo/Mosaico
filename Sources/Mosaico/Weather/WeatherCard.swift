import SwiftUI

struct WeatherCard: View {
    var model: WeatherModel
    var ctx: WidgetContext

    static let baseWidth: CGFloat = 400
    static let chartHeight: CGFloat = 64
    static let iconSize: CGFloat = 96

    var body: some View {
        let m = Metrics(s: ctx.scale)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header(m)
                details(m)
                    .subtitleSwap(key: model.hoveredHour.map { "h\($0)" } ?? "now", m: m)
                    .padding(.top, m(12))
                chart(m).padding(.top, m(14))
            }
            .padding(.horizontal, m(22))
            .padding(.top, m(20))
            .padding(.bottom, m(16))

            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)

            daysRow(m)
                .padding(.horizontal, m(16))
                .padding(.vertical, m(12))
        }
        .onPreferenceChange(BarFrameKey.self) { ctx.barFrame = $0 }
        .onChange(of: ctx.pointer) { _, p in updateHover(p) }
        .onAppear { model.start() }
        .widgetChrome(ctx: ctx, baseWidth: Self.baseWidth)
    }

    // MARK: - Cabecera

    private func header(_ m: Metrics) -> some View {
        HStack(alignment: .top, spacing: m(12)) {
            VStack(alignment: .leading, spacing: m(2)) {
                HStack(spacing: m(5)) {
                    Image(systemName: "location.fill").font(.system(size: m(9.5)))
                    Text(model.city.isEmpty ? "Tu ubicación" : model.city).lineLimit(1)
                }
                .font(.system(size: m(13), weight: .medium))
                .foregroundStyle(.white.opacity(0.65))

                switch model.status {
                case .ready:
                    Text(WeatherModel.deg(model.temp))
                        .font(.system(size: m(52), weight: .semibold))
                        .tracking(-1.5 * m.s)
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text(model.sky.title(day: model.isDay))
                        .font(.system(size: m(14), weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Máx \(WeatherModel.deg(model.todayMax))   Mín \(WeatherModel.deg(model.todayMin))")
                        .font(.system(size: m(12.5), weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                case .locating, .loading:
                    Text(model.status == .locating ? "Buscando tu ubicación…" : "Cargando el clima…")
                        .font(.system(size: m(15), weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, m(14))
                case .denied:
                    Text("Mosaico necesita tu ubicación para mostrar el clima.")
                        .font(.system(size: m(14), weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, m(10))
                    ActionButton(title: "Abrir Ajustes", m: m) { model.retry() }.padding(.top, m(8))
                case .failed:
                    Text("No pude cargar el clima.")
                        .font(.system(size: m(14), weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, m(10))
                    ActionButton(title: "Reintentar", m: m) { model.retry() }.padding(.top, m(8))
                }
            }
            Spacer(minLength: 0)
            weatherIcon
                .frame(width: m(Self.iconSize), height: m(Self.iconSize))
        }
        .frame(height: m(Self.iconSize + 18), alignment: .top)
    }

    /// Solo se anima si el cielo tiene movimiento y el widget está a la vista (6 cuadros/s).
    @ViewBuilder private var weatherIcon: some View {
        let ready = model.status == .ready
        let sky = ready ? model.sky : .cloudy
        let isDay = model.isDay
        if ready && sky.isAnimated && ctx.isVisible {
            TimelineView(.periodic(from: .now, by: 1.0 / 6)) { tl in
                Canvas { g, size in
                    WeatherIcon.draw(&g, size: size, sky: sky, isDay: isDay,
                                     t: tl.date.timeIntervalSinceReferenceDate, dim: false)
                }
            }
        } else {
            Canvas { g, size in
                WeatherIcon.draw(&g, size: size, sky: sky, isDay: isDay, t: 0, dim: !ready)
            }
        }
    }

    // MARK: - Detalle (o la hora con hover)

    @ViewBuilder private func details(_ m: Metrics) -> some View {
        Group {
            if let i = model.hoveredHour, i < model.hours.count {
                let h = model.hours[i]
                HStack(spacing: m(7)) {
                    Image(systemName: h.sky.symbol(day: true)).symbolRenderingMode(.multicolor)
                    Text(i == 0 ? "Ahora" : "\(WeatherModel.hourLabel(h.date)) h").foregroundStyle(.white.opacity(0.9))
                    Text(WeatherModel.deg(h.temp)).foregroundStyle(Color(rgb: WeatherChart.color(h.temp)))
                    Text("· \(Int(h.rainChance)) % de lluvia").foregroundStyle(.white.opacity(0.45))
                }
            } else if model.status == .ready {
                HStack(spacing: m(6)) {
                    Text("Sensación \(WeatherModel.deg(model.feelsLike))")
                    Text("·")
                    Text("Humedad \(Int(model.humidity)) %")
                    Text("·")
                    Text("Viento \(Int(model.wind.rounded())) km/h")
                }
                .foregroundStyle(.white.opacity(0.5))
            } else {
                Color.clear
            }
        }
        .font(.system(size: m(12.5), weight: .medium))
    }

    // MARK: - Próximas 24 horas

    private func chart(_ m: Metrics) -> some View {
        let hours = model.hours
        let hovered = model.hoveredHour
        return Color.clear
            .frame(height: m(Self.chartHeight + 16))
            .background(GeometryReader { g in
                Color.clear.preference(key: BarFrameKey.self, value: g.frame(in: .global))
            })
            .overlay {
                Canvas { g, size in
                    WeatherChart.draw(&g, size: size, s: m.s, hours: hours, hovered: hovered)
                }
                .allowsHitTesting(false)
            }
    }

    private func updateHover(_ p: CGPoint?) {
        let f = ctx.barFrame
        var index: Int?
        if let p, f.width > 0, f.contains(p), !model.hours.isEmpty {
            let i = Int((p.x - f.minX) / (f.width / CGFloat(model.hours.count)))
            index = min(model.hours.count - 1, max(0, i))
        }
        if model.hoveredHour != index { model.hoveredHour = index }
    }

    // MARK: - Próximos días

    private func daysRow(_ m: Metrics) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.days.prefix(7).enumerated()), id: \.offset) { i, d in
                VStack(spacing: m(5)) {
                    Text(WeatherModel.dayLabel(d.date, index: i))
                        .font(.system(size: m(11.5), weight: .semibold))
                        .foregroundStyle(.white.opacity(i == 0 ? 0.9 : 0.55))
                    Image(systemName: d.sky.symbol(day: true))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: m(15)))
                        .frame(height: m(18))
                    HStack(spacing: m(3)) {
                        Text(WeatherModel.deg(d.max)).foregroundStyle(.white.opacity(0.9))
                        Text(WeatherModel.deg(d.min)).foregroundStyle(.white.opacity(0.4))
                    }
                    .font(.system(size: m(11.5), weight: .medium))
                    .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
            if model.days.isEmpty {
                Text(" ").font(.system(size: m(11.5))).frame(height: m(52))
            }
        }
    }
}

/// Las próximas 24 horas como columnas de píxeles: la altura y el color siguen la
/// temperatura; los puntitos celestes arriba son la chance de lluvia.
enum WeatherChart {
    /// Escala de color por temperatura (°C).
    static func color(_ t: Double) -> SIMD3<Double> {
        let stops: [(Double, SIMD3<Double>)] = [
            (-5, [0.50, 0.58, 1.00]), (5, [0.33, 0.72, 1.00]), (12, [0.25, 0.86, 0.80]),
            (18, [0.55, 0.90, 0.38]), (24, [1.00, 0.82, 0.25]), (30, [1.00, 0.55, 0.18]),
            (36, [1.00, 0.30, 0.32]),
        ]
        if t <= stops[0].0 { return stops[0].1 }
        for k in 1..<stops.count where t <= stops[k].0 {
            let (t0, c0) = stops[k - 1], (t1, c1) = stops[k]
            return c0 + (c1 - c0) * ((t - t0) / (t1 - t0))
        }
        return stops.last!.1
    }

    static func draw(_ g: inout GraphicsContext, size: CGSize, s: CGFloat, hours: [HourPoint], hovered: Int?) {
        let labelH = 16 * s
        let chartH = size.height - labelH
        let count = max(1, hours.count)
        let slot = size.width / CGFloat(count)
        let pitch = 5 * s
        let dot = 3.8 * s
        let rows = Int(chartH / pitch)
        let colW = pitch * 2 - (pitch - dot)
        let temps = hours.map(\.temp)
        let lo = (temps.min() ?? 0) - 1
        let hi = max(lo + 1, (temps.max() ?? 1) + 1)
        let rainRGB: SIMD3<Double> = [0.45, 0.78, 1.0]

        guard !hours.isEmpty else {
            for i in 0..<24 {
                for r in 0..<rows {
                    let x = CGFloat(i) * (size.width / 24) + (size.width / 24 - colW) / 2
                    let rect = CGRect(x: x, y: CGFloat(r) * pitch, width: dot, height: dot)
                    g.fill(Path(rect), with: .color(.white.opacity(0.05)))
                }
            }
            return
        }

        for (i, h) in hours.enumerated() {
            let x0 = CGFloat(i) * slot + (slot - colW) / 2
            let level = 0.22 + 0.78 * (h.temp - lo) / (hi - lo)
            let lit = max(2, Int((Double(rows) * level).rounded()))
            let drops = h.rainChance >= 20 ? min(4, Int(h.rainChance / 22)) : 0
            let rgb = color(h.temp)
            let dimFactor = hovered == nil || hovered == i ? 1.0 : 0.4
            for r in 0..<rows {
                let fromBottom = rows - 1 - r
                for c in 0..<2 {
                    let rect = CGRect(x: x0 + CGFloat(c) * pitch, y: CGFloat(r) * pitch, width: dot, height: dot)
                    let path = Path(roundedRect: rect, cornerRadius: dot * 0.2)
                    if fromBottom < lit {
                        let top = fromBottom == lit - 1
                        let mix = top ? 0.35 : 0
                        let a = (top ? 1 : 0.55 + 0.4 * Double(fromBottom) / Double(max(1, lit))) * dimFactor
                        g.fill(path, with: .color(Color(rgb: rgb + (SIMD3(repeating: 1) - rgb) * mix, opacity: a)))
                    } else if fromBottom >= lit + 1, fromBottom < lit + 1 + drops * 2, (fromBottom + c) % 2 == 0 {
                        g.fill(path, with: .color(Color(rgb: rainRGB, opacity: 0.8 * dimFactor)))
                    } else {
                        g.fill(path, with: .color(.white.opacity(0.04)))
                    }
                }
            }
            if hovered == i {
                let r = CGRect(x: x0 - 2 * s, y: -2 * s, width: colW + 4 * s, height: CGFloat(rows) * pitch + 3 * s)
                g.stroke(Path(roundedRect: r, cornerRadius: 3 * s), with: .color(.white.opacity(0.35)), lineWidth: 1)
            }
            // Etiquetas cada 6 horas.
            if i % 6 == 0 {
                let label = i == 0 ? "Ahora" : WeatherModel.hourLabel(h.date)
                let text = g.resolve(Text(label)
                    .font(.system(size: 10.5 * s, weight: .semibold))
                    .foregroundStyle(.white.opacity(i == 0 ? 0.75 : 0.4)))
                g.draw(text, at: CGPoint(x: x0, y: chartH + labelH / 2 + 2 * s), anchor: .leading)
            }
        }
    }
}

/// Ícono del clima en pixel art (16×16), animado a 8 cuadros por segundo.
enum WeatherIcon {
    private typealias Pixels = [Int: (SIMD3<Double>, Double)]  // y*16+x → (color, alpha)

    static func draw(_ g: inout GraphicsContext, size: CGSize, sky: Sky, isDay: Bool, t: Double, dim: Bool) {
        let n = 16
        let pitch = size.width / CGFloat(n)
        let dot = pitch * 0.8
        let frame = Int(t * 8)
        var px: Pixels = [:]

        func put(_ x: Int, _ y: Int, _ c: SIMD3<Double>, _ a: Double = 1) {
            guard (0..<n).contains(x), (0..<n).contains(y) else { return }
            px[y * n + x] = (c, a)
        }
        func disc(_ cx: Double, _ cy: Double, _ r: Double, _ c: SIMD3<Double>, _ a: Double = 1) {
            for y in 0..<n { for x in 0..<n {
                let dx = Double(x) - cx, dy = Double(y) - cy
                if dx * dx + dy * dy <= r * r { put(x, y, c, a) }
            } }
        }
        let sunC: SIMD3<Double> = [1.0, 0.80, 0.25]
        let rayC: SIMD3<Double> = [1.0, 0.62, 0.20]
        let moonC: SIMD3<Double> = [0.92, 0.92, 1.0]
        let cloudC: SIMD3<Double> = sky == .storm ? [0.55, 0.57, 0.65] : [0.90, 0.92, 0.96]
        let shadeC: SIMD3<Double> = sky == .storm ? [0.40, 0.42, 0.50] : [0.68, 0.72, 0.80]

        func sun(_ cx: Double, _ cy: Double, _ r: Double, rays: Bool) {
            disc(cx, cy, r, sunC)
            guard rays else { return }
            let pulse = frame % 4 < 2
            let dist = r + (pulse ? 2.0 : 2.6)
            for k in 0..<8 {
                let ang = Double(k) * .pi / 4 + (frame % 8 < 4 ? 0 : .pi / 8)
                put(Int((cx + cos(ang) * dist).rounded()), Int((cy + sin(ang) * dist).rounded()), rayC, 0.9)
            }
        }
        func moon(_ cx: Double, _ cy: Double) {
            for y in 0..<n { for x in 0..<n {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let dx2 = Double(x) - (cx + 2.2), dy2 = Double(y) - (cy - 1.4)
                if dx * dx + dy * dy <= 16, dx2 * dx2 + dy2 * dy2 > 11 { put(x, y, moonC) }
            } }
            for (i, (sx, sy)) in [(12, 3), (13, 9), (3, 2), (10, 13)].enumerated() {
                let on = (frame / 3 + i) % 4 != 0
                put(sx, sy, [1, 1, 1], on ? 0.9 : 0.25)
            }
        }
        func cloud(dx: Double, dy: Double) {
            let shift = sin(t * 0.8) * 0.6
            let ox = dx + shift
            disc(5.5 + ox, 9.5 + dy, 2.6, shadeC)
            disc(8.5 + ox, 8.0 + dy, 3.3, cloudC)
            disc(11.2 + ox, 9.6 + dy, 2.5, cloudC)
            for x in 3...13 { for y in 10...11 { put(Int(Double(x) + ox.rounded()), y + Int(dy), x < 6 ? shadeC : cloudC) } }
        }
        func falling(_ color: SIMD3<Double>, columns: [Int], speed: Int, length: Int) {
            for (i, x) in columns.enumerated() {
                let phase = (frame / speed + i * 2) % 4
                for k in 0..<length { put(x - (k > 0 ? 0 : 0), 12 + phase + k - (length - 1), color, 0.95) }
            }
        }

        switch sky {
        case .clear:
            if isDay { sun(7.5, 7.5, 3.6, rays: true) } else { moon(7, 8) }
        case .partly:
            if isDay { sun(10.5, 5.0, 2.8, rays: true) } else { moon(10, 5) }
            cloud(dx: -1, dy: 1.5)
        case .cloudy:
            cloud(dx: 0, dy: 0)
        case .fog:
            for (row, y) in [5, 8, 11].enumerated() {
                let off = (frame / 2 + row * 3) % 4
                for x in 1..<15 where (x + off) % 6 != 0 { put(x, y, [0.78, 0.80, 0.86], 0.85) }
            }
        case .drizzle:
            cloud(dx: 0, dy: -1.5)
            falling([0.45, 0.78, 1.0], columns: [5, 9, 12], speed: 2, length: 1)
        case .rain:
            cloud(dx: 0, dy: -2)
            falling([0.45, 0.78, 1.0], columns: [4, 7, 10, 13], speed: 1, length: 2)
        case .snow:
            cloud(dx: 0, dy: -2)
            falling([1, 1, 1], columns: [5, 8, 11], speed: 3, length: 1)
        case .storm:
            cloud(dx: 0, dy: -2)
            if frame % 16 < 3 {
                let bolt: [(Int, Int)] = [(9, 11), (8, 12), (8, 13), (9, 13), (8, 14), (7, 15)]
                for (x, y) in bolt { put(x, y, [1.0, 0.88, 0.3]) }
            }
            falling([0.45, 0.78, 1.0], columns: [5, 12], speed: 1, length: 2)
        }

        for y in 0..<n {
            for x in 0..<n {
                let rect = CGRect(x: CGFloat(x) * pitch + (pitch - dot) / 2, y: CGFloat(y) * pitch + (pitch - dot) / 2,
                                  width: dot, height: dot)
                let path = Path(roundedRect: rect, cornerRadius: dot * 0.2)
                if let (c, a) = px[y * n + x] {
                    g.fill(path, with: .color(Color(rgb: c, opacity: a * (dim ? 0.35 : 1))))
                } else {
                    g.fill(path, with: .color(.white.opacity(0.035)))
                }
            }
        }
    }
}
