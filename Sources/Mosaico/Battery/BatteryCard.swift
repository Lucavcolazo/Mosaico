import SwiftUI

struct BatteryCard: View {
    var model: BatteryModel
    var ctx: WidgetContext

    static let baseWidth: CGFloat = 380

    var body: some View {
        let m = Metrics(s: ctx.scale)
        VStack(alignment: .leading, spacing: 0) {
            macSection(m)
                .padding(.horizontal, m(20))
                .padding(.top, m(18))
                .padding(.bottom, m(16))

            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)

            VStack(alignment: .leading, spacing: m(12)) {
                if model.devices.isEmpty {
                    HStack(spacing: m(8)) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(width: m(18))
                        Text("Sin dispositivos Bluetooth con batería conectados")
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .font(.system(size: m(12.5), weight: .medium))
                } else {
                    ForEach(model.devices) { d in deviceRow(d, m) }
                }
            }
            .padding(.horizontal, m(20))
            .padding(.vertical, m(14))
        }
        .onChange(of: ctx.isVisible) { _, v in model.isVisible = v }
        .onAppear { model.start() }
        .widgetChrome(ctx: ctx, baseWidth: Self.baseWidth)
    }

    // MARK: - Mac

    @ViewBuilder private func macSection(_ m: Metrics) -> some View {
        if let mac = model.mac {
            HStack(alignment: .center, spacing: m(14)) {
                VStack(alignment: .leading, spacing: m(2)) {
                    HStack(spacing: m(6)) {
                        Image(systemName: "laptopcomputer").font(.system(size: m(11)))
                        Text("Esta Mac")
                    }
                    .font(.system(size: m(13), weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    HStack(alignment: .firstTextBaseline, spacing: m(4)) {
                        Text("\(mac.percent)")
                            .font(.system(size: m(40), weight: .semibold))
                            .tracking(-1 * m.s)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("%")
                            .font(.system(size: m(20), weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        if mac.charging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: m(16)))
                                .foregroundStyle(Color(rgb: BatteryModel.color(for: mac.percent, charging: true)))
                        }
                    }
                    .foregroundStyle(.white)
                    Text(model.macStatus(mac))
                        .font(.system(size: m(12.5), weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    let detail = model.macDetail(mac)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: m(11.5), weight: .medium))
                            .foregroundStyle(.white.opacity(0.32))
                    }
                }
                Spacer(minLength: 0)
                bigBattery(mac, m)
                    .frame(width: m(118), height: m(56))
            }
        } else {
            Text("Esta Mac no tiene batería.")
                .font(.system(size: m(13), weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// Batería grande de píxeles. Cargando, el píxel siguiente al nivel late (1 vez por segundo).
    @ViewBuilder private func bigBattery(_ mac: MacBattery, _ m: Metrics) -> some View {
        let percent = mac.percent
        let charging = mac.charging
        if charging && ctx.isVisible {
            TimelineView(.periodic(from: .now, by: 0.5)) { tl in
                Canvas { g, size in
                    PixelBattery.draw(&g, size: size, percent: percent, charging: true,
                                      tick: Int(tl.date.timeIntervalSinceReferenceDate * 2), columns: 10, rows: 4)
                }
            }
        } else {
            Canvas { g, size in
                PixelBattery.draw(&g, size: size, percent: percent, charging: false, tick: 0, columns: 10, rows: 4)
            }
        }
    }

    // MARK: - Dispositivos

    /// Una línea si tiene una sola batería; si tiene varias (AirPods), los niveles van abajo del nombre.
    @ViewBuilder private func deviceRow(_ d: DeviceBattery, _ m: Metrics) -> some View {
        if d.levels.count > 1 {
            VStack(alignment: .leading, spacing: m(6)) {
                deviceName(d, m)
                HStack(spacing: m(14)) {
                    ForEach(Array(d.levels.enumerated()), id: \.offset) { _, level in levelView(level, m) }
                }
                .padding(.leading, m(30))
            }
        } else {
            HStack(spacing: m(10)) {
                deviceName(d, m)
                Spacer(minLength: m(8))
                ForEach(Array(d.levels.enumerated()), id: \.offset) { _, level in levelView(level, m) }
            }
        }
    }

    private func deviceName(_ d: DeviceBattery, _ m: Metrics) -> some View {
        HStack(spacing: m(10)) {
            Image(systemName: d.symbol)
                .font(.system(size: m(14)))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: m(20))
            Text(d.name)
                .font(.system(size: m(13), weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func levelView(_ level: DeviceBattery.Level, _ m: Metrics) -> some View {
        HStack(spacing: m(5)) {
            if !level.label.isEmpty {
                Text(level.label)
                    .font(.system(size: m(10.5), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Canvas { g, size in
                PixelBattery.draw(&g, size: size, percent: level.percent, charging: false,
                                  tick: 0, columns: 5, rows: 2, compact: true)
            }
            .frame(width: m(26), height: m(12))
            Text("\(level.percent)%")
                .font(.system(size: m(11.5), weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(level.percent <= 20 ? 0.9 : 0.55))
        }
        .fixedSize()
    }
}

/// Batería dibujada con píxeles: contorno, "botón" a la derecha y columnas que se llenan.
enum PixelBattery {
    static func draw(_ g: inout GraphicsContext, size: CGSize, percent: Int, charging: Bool,
                     tick: Int, columns: Int, rows: Int, compact: Bool = false) {
        let capW = size.width * (compact ? 0.08 : 0.06)
        let body = CGRect(x: 0, y: 0, width: size.width - capW - 1, height: size.height)
        let line: CGFloat = compact ? 1 : max(1.5, size.height * 0.035)
        let radius = size.height * (compact ? 0.2 : 0.16)
        // Contorno y botón.
        g.stroke(Path(roundedRect: body.insetBy(dx: line / 2, dy: line / 2), cornerRadius: radius),
                 with: .color(.white.opacity(0.35)), lineWidth: line)
        let capH = size.height * 0.4
        g.fill(Path(roundedRect: CGRect(x: body.maxX + 1, y: (size.height - capH) / 2, width: capW, height: capH),
                    cornerRadius: capW * 0.4),
               with: .color(.white.opacity(0.35)))

        // Píxeles.
        let pad = line + (compact ? 1 : size.height * 0.07)
        let inner = body.insetBy(dx: pad, dy: pad)
        let pitchX = inner.width / CGFloat(columns)
        let pitchY = inner.height / CGFloat(rows)
        let gap = compact ? 0.8 : max(1.5, min(pitchX, pitchY) * 0.18)
        let rgb = BatteryModel.color(for: percent, charging: charging)
        let level = Double(percent) / 100 * Double(columns)
        for c in 0..<columns {
            let fill = min(1, max(0, level - Double(c)))
            let pulsing = charging && c == min(columns - 1, Int(level)) && fill < 1
            for r in 0..<rows {
                let rect = CGRect(x: inner.minX + CGFloat(c) * pitchX + gap / 2,
                                  y: inner.minY + CGFloat(r) * pitchY + gap / 2,
                                  width: pitchX - gap, height: pitchY - gap)
                let path = Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.2)
                if fill >= 1 {
                    g.fill(path, with: .color(Color(rgb: rgb, opacity: 0.95)))
                } else if pulsing {
                    let a = tick % 2 == 0 ? 0.85 : 0.3
                    g.fill(path, with: .color(Color(rgb: rgb, opacity: a)))
                } else if fill > 0 {
                    // Columna parcial: se encienden las filas de abajo según cuánto falta.
                    let litRows = Int((fill * Double(rows)).rounded(.up))
                    let on = r >= rows - litRows
                    g.fill(path, with: .color(on ? Color(rgb: rgb, opacity: 0.95) : .white.opacity(0.06)))
                } else {
                    g.fill(path, with: .color(.white.opacity(0.06)))
                }
            }
        }
    }
}
