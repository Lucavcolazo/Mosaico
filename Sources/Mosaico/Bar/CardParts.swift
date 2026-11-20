import SwiftUI

/// Multiplica medidas de diseño (pensadas a escala 1) por la escala del widget.
struct Metrics {
    let s: CGFloat
    func callAsFunction(_ v: CGFloat) -> CGFloat { v * s }
}

struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct BarFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

private struct CardSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

// MARK: - Marco de la tarjeta

extension View {
    /// Fondo, borde, esquina para redimensionar y tamaño del panel. Lo usan todos los widgets.
    func widgetChrome(ctx: WidgetContext, baseWidth: CGFloat) -> some View {
        modifier(WidgetChrome(ctx: ctx, baseWidth: baseWidth))
    }

    /// `widgetChrome` + hover sobre la barra de píxeles y la leyenda.
    func cardChrome(ctx: WidgetContext, source: any BarSource, baseWidth: CGFloat) -> some View {
        modifier(BarHover(ctx: ctx, source: source))
            .widgetChrome(ctx: ctx, baseWidth: baseWidth)
    }
}

private struct WidgetChrome: ViewModifier {
    let ctx: WidgetContext
    let baseWidth: CGFloat

    func body(content: Content) -> some View {
        let s = ctx.scale
        let shape = RoundedRectangle(cornerRadius: 18 * s, style: .continuous)
        let style = Appearance.shared.style
        content
            .legibleOnGlass(style != .solid)
            .frame(width: baseWidth * s)
            .background(CardBackground(style: style, radius: 18 * s))
            .overlay(alignment: .bottomTrailing) { ResizeGrip(ctx: ctx, baseWidth: baseWidth) }
            .clipShape(shape)
            .environment(\.colorScheme, .dark)
            .focusEffectDisabled()
            .background(GeometryReader { g in
                Color.clear.preference(key: CardSizeKey.self, value: g.size)
            })
            .onPreferenceChange(CardSizeKey.self) { ctx.onContentSize?($0) }
    }
}

private struct BarHover: ViewModifier {
    let ctx: WidgetContext
    let source: any BarSource

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(RowFramesKey.self) { ctx.rowFrames = $0 }
            .onPreferenceChange(BarFrameKey.self) { ctx.barFrame = $0 }
            .onChange(of: ctx.pointer) { _, p in updateHover(p) }
            .onChange(of: source.isBusy) { _, _ in updateHover(ctx.pointer) }
    }

    private func updateHover(_ p: CGPoint?) {
        var target: String?
        if let p, source.canHover, ctx.resizeStartScale == nil {
            if let hit = ctx.rowFrames.first(where: { $0.value.contains(p) })?.key {
                target = hit
            } else if ctx.barFrame.contains(p), ctx.barFrame.width > 0 {
                target = source.itemID(atFraction: (p.x - ctx.barFrame.minX) / ctx.barFrame.width)
            }
        }
        if source.hoveredID != target { source.hoveredID = target }
    }
}

/// Esquina para arrastrar y cambiar el tamaño (escala todo de forma proporcional).
private struct ResizeGrip: View {
    let ctx: WidgetContext
    let baseWidth: CGFloat

    var body: some View {
        let s = ctx.scale
        Canvas { g, size in
            let pad = 6 * s
            var path = Path()
            for k in 1...3 {
                let d = CGFloat(k) * 4 * s
                path.move(to: CGPoint(x: size.width - pad - d, y: size.height - pad))
                path.addLine(to: CGPoint(x: size.width - pad, y: size.height - pad - d))
            }
            g.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.2 * s, lineCap: .round))
        }
        .frame(width: 24 * s, height: 24 * s)
        .opacity(ctx.pointer != nil || ctx.resizeStartScale != nil ? 0.45 : 0)
        .animation(.easeOut(duration: 0.2), value: ctx.pointer != nil)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = ctx.resizeStartScale ?? ctx.scale
                    ctx.resizeStartScale = start
                    let newScale = (baseWidth * start + v.translation.width) / baseWidth
                    ctx.scale = (newScale * 100).rounded() / 100
                }
                .onEnded { _ in ctx.resizeStartScale = nil }
        )
    }
}

// MARK: - Piezas compartidas

struct CardHeader: View {
    let used: Double
    let capacity: Double
    let busy: Bool
    let t: Double
    let m: Metrics
    var accessory: AnyView? = nil
    let rescan: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: m(8)) {
            Text(ByteFormat.amount(used))
                .font(.system(size: m(30), weight: .semibold))
                .tracking(-0.6 * m.s)
                .monospacedDigit()
                .foregroundStyle(.white)
            Text("de \(ByteFormat.capacity(capacity)) usados")
                .font(.system(size: m(15)))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 0)
            if let accessory {
                accessory.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + m(5) }
            }
            Button(action: rescan) {
                HStack(spacing: m(6)) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .rotationEffect(.degrees(busy ? (t * 300).truncatingRemainder(dividingBy: 360) : 0))
                    if accessory == nil { Text("Reescanear") }
                }
                .font(.system(size: m(13), weight: .medium))
                .foregroundStyle(.white.opacity(busy ? 0.3 : 0.6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
    }
}

struct PathLine: View {
    let label: String
    let path: String
    let m: Metrics

    var body: some View {
        HStack(spacing: m(8)) {
            Text(label)
                .font(.system(size: m(13), weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(ByteFormat.shortPath(path))
                .font(.system(size: m(12), design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)
        }
    }
}

struct HoverLine: View {
    let item: BarItem
    let detail: String
    let m: Metrics

    var body: some View {
        HStack(spacing: m(7)) {
            Image(systemName: item.symbol)
                .foregroundStyle(Color(rgb: item.rgb))
                .font(.system(size: m(12)))
            Text(item.name).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            Text(ByteFormat.amount(item.bytes)).foregroundStyle(.white.opacity(0.45)).monospacedDigit()
            Text(detail).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
        }
        .font(.system(size: m(13), weight: .medium))
    }
}

/// Animación de entrada/salida para la línea debajo del número grande.
extension View {
    func subtitleSwap(key: String, m: Metrics) -> some View {
        self
            .id(key)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: m(4))), removal: .opacity))
            .animation(.easeOut(duration: 0.22), value: key)
            .frame(height: m(20), alignment: .leading)
    }
}

struct LegendGrid: View {
    let items: [BarItem]
    let hovered: String?
    let m: Metrics
    let cardWidth: CGFloat
    let value: (BarItem) -> String

    var body: some View {
        let spacing = m(6)
        let colWidth = (cardWidth - 2 * m(22) + 2 * m(8) - 2 * spacing) / 3
        let rows = max(3, (items.count + 2) / 3)
        VStack(spacing: m(2)) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: spacing) {
                    ForEach(0..<3, id: \.self) { c in
                        let i = r * 3 + c
                        if i < items.count {
                            row(items[i], width: colWidth)
                        } else {
                            row(BarItem(id: "_", name: "—", symbol: "circle", rgb: Palette.gray, bytes: 0), width: colWidth)
                                .hidden()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, -m(8))
        .animation(.easeOut(duration: 0.18), value: hovered)
    }

    private func row(_ item: BarItem, width: CGFloat) -> some View {
        let isHovered = hovered == item.id
        let dimmed = hovered != nil && !isHovered
        return HStack(spacing: m(8)) {
            Image(systemName: item.symbol)
                .font(.system(size: m(12.5)))
                .foregroundStyle(Color(rgb: item.rgb))
                .frame(width: m(16))
            Text(item.name)
                .font(.system(size: m(13), weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
            Spacer(minLength: m(4))
            Text(value(item))
                .font(.system(size: m(12.5)))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, m(8))
        .padding(.vertical, m(5))
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: m(7), style: .continuous)
                .fill(.white.opacity(isHovered ? 0.07 : 0))
        )
        .opacity(dimmed ? 0.45 : 1)
        .background(GeometryReader { g in
            Color.clear.preference(key: RowFramesKey.self, value: [item.id: g.frame(in: .global)])
        })
    }
}

struct CardBar: View {
    let source: any BarSource
    let anim: BarAnimator
    let t: Double
    let m: Metrics

    var body: some View {
        Color.clear
            .frame(height: m(PixelBar.height))
            .background(GeometryReader { g in
                Color.clear.preference(key: BarFrameKey.self, value: g.frame(in: .global))
            })
            .overlay {
                Canvas { ctx, size in
                    PixelBar.draw(&ctx, size: size, t: t, s: m.s, source: source, anim: anim)
                }
                .padding(PixelBar.insets(m.s))
                .allowsHitTesting(false)
            }
    }
}

struct ActionButton: View {
    let title: String
    var tint: Color? = nil
    var disabled = false
    let m: Metrics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: m(12.5), weight: .semibold))
                .foregroundStyle(.white.opacity(disabled ? 0.35 : 0.92))
                .padding(.horizontal, m(12))
                .padding(.vertical, m(6))
                .background(
                    RoundedRectangle(cornerRadius: m(8), style: .continuous)
                        .fill(tint.map { $0.opacity(0.3) } ?? Color.white.opacity(0.09))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .animation(.easeOut(duration: 0.15), value: title)
    }
}

/// Esqueleto común: cabecera, subtítulo, barra, leyenda y pie.
struct CardLayout<Header: View, Subtitle: View, Legend: View, Footer: View>: View {
    let m: Metrics
    let bar: CardBar
    @ViewBuilder let header: Header
    @ViewBuilder let subtitle: Subtitle
    @ViewBuilder let legend: Legend
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                subtitle.padding(.top, m(4))
                bar.padding(.top, m(18))
                legend.padding(.top, m(22))
            }
            .padding(.horizontal, m(22))
            .padding(.top, m(20))
            .padding(.bottom, m(18))

            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)

            HStack(spacing: m(10)) { footer }
                .font(.system(size: m(13), weight: .medium))
                .frame(height: m(52))
                .padding(.horizontal, m(22))
        }
    }
}

struct FooterSpinner: View {
    let text: String
    let m: Metrics
    var body: some View {
        ProgressView().controlSize(.small).scaleEffect(0.75 * m.s).frame(width: m(16), height: m(16))
        Text(text).foregroundStyle(.white.opacity(0.45))
        Spacer(minLength: 0)
    }
}
