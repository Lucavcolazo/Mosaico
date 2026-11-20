import SwiftUI

struct NowPlayingCard: View {
    var model: NowPlayingModel
    var ctx: WidgetContext

    static let baseWidth: CGFloat = 380
    static let coverSize: CGFloat = 104
    static let barDots = 46

    var body: some View {
        let m = Metrics(s: ctx.scale)
        let animating = model.isAnimating
        TimelineView(.animation(minimumInterval: animating ? nil : 0.5,
                                paused: !(model.isPlaying || animating))) { timeline in
            let now = timeline.date
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: m(16)) {
                    cover(m, now: now)
                    info(m)
                    Spacer(minLength: 0)
                }
                progress(m, now: now).padding(.top, m(18))
                controls(m).padding(.top, m(10))
            }
            .padding(.horizontal, m(20))
            .padding(.top, m(20))
            .padding(.bottom, m(14))
        }
        .onPreferenceChange(BarFrameKey.self) { ctx.barFrame = $0 }
        .onChange(of: ctx.pointer) { _, p in
            let inside = p.map { ctx.barFrame.contains($0) } ?? false
            if model.hoveringCover != inside { model.hoveringCover = inside }
        }
        .onAppear { model.start() }
        .widgetChrome(ctx: ctx, baseWidth: Self.baseWidth)
    }

    // MARK: - Portada

    private func cover(_ m: Metrics, now: Date) -> some View {
        let side = m(Self.coverSize)
        let shape = RoundedRectangle(cornerRadius: m(10), style: .continuous)
        let elapsed = now.timeIntervalSince(model.coverChangedAt)
        let pixels = model.coverPixels
        let previous = model.previousPixels
        return ZStack {
            shape.fill(.white.opacity(0.04))
            Canvas { g, size in
                CoverMosaic.draw(&g, size: size, pixels: pixels, previous: previous,
                                 elapsed: elapsed, n: NowPlayingModel.coverGrid)
            }
            if pixels.isEmpty {
                Image(systemName: "music.note")
                    .font(.system(size: m(28), weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
            }
            if let art = model.artwork {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .opacity(model.hoveringCover ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: model.hoveringCover)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .background(GeometryReader { g in
            Color.clear.preference(key: BarFrameKey.self, value: g.frame(in: .global))
        })
    }

    // MARK: - Texto

    @ViewBuilder private func info(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: m(4)) {
            switch model.status {
            case .playing, .paused:
                Text(model.title)
                    .font(.system(size: m(17), weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(model.artist)
                    .font(.system(size: m(13), weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Text(model.album)
                    .font(.system(size: m(12)))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
            case .closed:
                message("Spotify está cerrado.", m)
                ActionButton(title: "Abrir Spotify", m: m) { model.openSpotify() }.padding(.top, m(6))
            case .stopped:
                message("No hay nada sonando.", m)
            case .denied:
                message("Mosaico necesita permiso para controlar Spotify.", m)
                ActionButton(title: "Abrir Ajustes", m: m) { SpotifyBridge.openAutomationSettings() }.padding(.top, m(6))
            case .notInstalled:
                message("No encontré Spotify en esta Mac.", m)
            }
        }
        .frame(height: m(Self.coverSize), alignment: .topLeading)
    }

    private func message(_ text: String, _ m: Metrics) -> some View {
        Text(text)
            .font(.system(size: m(14), weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Progreso

    private func progress(_ m: Metrics, now: Date) -> some View {
        let duration = max(model.duration, 1)
        let pos = model.hasTrack ? model.position(at: now) : 0
        let fraction = model.hasTrack ? pos / duration : 0
        let colors = model.barColors
        let playing = model.isPlaying
        let tick = Int(now.timeIntervalSinceReferenceDate * 2)
        return VStack(spacing: m(6)) {
            Canvas { g, size in
                ProgressDots.draw(&g, size: size, fraction: fraction, colors: colors,
                                  playing: playing, count: Self.barDots, tick: tick)
            }
            .frame(height: m(7))
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in
                guard model.hasTrack else { return }
                let width = Self.baseWidth * m.s - m(40)
                model.seek(fraction: v.location.x / width)
            })
            HStack {
                Text(NowPlayingModel.time(pos))
                Spacer()
                Text("-" + NowPlayingModel.time(model.hasTrack ? duration - pos : 0))
            }
            .font(.system(size: m(11), weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.38))
        }
    }

    // MARK: - Controles

    private func controls(_ m: Metrics) -> some View {
        let enabled = model.hasTrack
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            control("gobackward.10", size: 15, m, enabled) { model.skip(by: -10) }
            control("backward.fill", size: 16, m, enabled) { model.previous() }
            Button { model.playPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: m(17), weight: .bold))
                    .foregroundStyle(Color(white: 0.08))
                    .frame(width: m(42), height: m(42))
                    .background(Circle().fill(.white.opacity(enabled ? 0.92 : 0.3)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .padding(.horizontal, m(10))
            control("forward.fill", size: 16, m, enabled) { model.next() }
            control("goforward.10", size: 15, m, enabled) { model.skip(by: 10) }
            Spacer(minLength: 0)
        }
    }

    private func control(_ symbol: String, size: CGFloat, _ m: Metrics, _ enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: m(size), weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.78 : 0.25))
                .frame(width: m(44), height: m(36))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// La portada como mosaico de píxeles. Al cambiar de canción, cada píxel "da vuelta"
/// del color viejo al nuevo en una ola diagonal.
enum CoverMosaic {
    static func draw(_ g: inout GraphicsContext, size: CGSize, pixels: [SIMD3<Double>],
                     previous: [SIMD3<Double>], elapsed: Double, n: Int) {
        let pitch = size.width / CGFloat(n)
        let dot = pitch * 0.82
        let inset = (pitch - dot) / 2
        let hasPrev = previous.count == n * n
        let hasNow = pixels.count == n * n
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let delay = Double(x + y) / Double(2 * n) * 0.6
                let p = min(1, max(0, (elapsed - delay) / 0.3))
                let from: SIMD3<Double>? = hasPrev ? previous[i] : nil
                let to: SIMD3<Double>? = hasNow ? pixels[i] : nil
                let rgb: SIMD3<Double>
                var alpha = 1.0
                switch (from, to) {
                case let (f?, t?): rgb = f + (t - f) * p
                case let (nil, t?): rgb = t; alpha = p
                case let (f?, nil): rgb = f; alpha = 1 - p
                default:
                    let r = CGRect(x: CGFloat(x) * pitch + pitch * 0.4, y: CGFloat(y) * pitch + pitch * 0.4,
                                   width: pitch * 0.2, height: pitch * 0.2)
                    g.fill(Path(r), with: .color(.white.opacity(0.08)))
                    continue
                }
                let flip = 1 - 0.7 * sin(p * .pi) * (hasPrev ? 1 : 0)
                let w = dot * flip
                let rect = CGRect(x: CGFloat(x) * pitch + inset + (dot - w) / 2,
                                  y: CGFloat(y) * pitch + inset, width: w, height: dot)
                g.fill(Path(roundedRect: rect, cornerRadius: dot * 0.18), with: .color(Color(rgb: rgb, opacity: alpha)))
            }
        }
    }
}

/// Barra de progreso de píxeles teñida con los colores de la portada.
enum ProgressDots {
    static func draw(_ g: inout GraphicsContext, size: CGSize, fraction: Double, colors: [SIMD3<Double>],
                     playing: Bool, count: Int, tick: Int) {
        let pitch = size.width / CGFloat(count)
        let dot = min(size.height, pitch * 0.72)
        let lit = fraction * Double(count)
        let fallback: SIMD3<Double> = [0.9, 0.9, 0.92]
        for i in 0..<count {
            let rect = CGRect(x: CGFloat(i) * pitch + (pitch - dot) / 2, y: (size.height - dot) / 2,
                              width: dot, height: dot)
            let path = Path(roundedRect: rect, cornerRadius: dot * 0.2)
            g.fill(path, with: .color(.white.opacity(0.07)))
            let level = min(1, max(0, lit - Double(i)))
            guard level > 0 else { continue }
            let rgb = colors.isEmpty ? fallback : colors[min(colors.count - 1, i * colors.count / count)]
            var a = (playing ? 0.95 : 0.5) * level
            // La "cabeza" late suave mientras suena.
            if playing, Double(i) <= lit, Double(i) > lit - 1 { a *= tick % 2 == 0 ? 1 : 0.65 }
            g.fill(path, with: .color(Color(rgb: rgb, opacity: a)))
        }
    }
}
