import AppKit
import SwiftUI

/// Solo los ojos de LuckyPy: sin textos. Tocar los ojos le manda `{"type":"touch"}` a la Pi.
/// Sin conexión se ven cerrados y apagados.
struct MascotaCard: View {
    var model: MascotaModel
    var ctx: WidgetContext

    static let baseWidth: CGFloat = 460
    static let padding: CGFloat = 14
    /// Alto de la zona de ojos respecto del ancho interior (dos "pantallas" 2:1 con margen).
    static let eyesAspect: CGFloat = 0.255

    var body: some View {
        let s = ctx.scale
        let innerWidth = (Self.baseWidth - Self.padding * 2) * s
        eyes
            .frame(height: innerWidth * Self.eyesAspect)
            .contentShape(Rectangle())
            .onTapGesture { model.touch() }
            .padding(Self.padding * s)
            .onChange(of: ctx.isVisible) { _, visible in model.isVisible = visible }
            .onAppear { model.start() }
            .widgetChrome(ctx: ctx, baseWidth: Self.baseWidth)
    }

    @ViewBuilder private var eyes: some View {
        if ctx.id == "snapshot" {
            EyesPreview(images: model.lastEyes, offline: model.link != .live)
        } else {
            EyesRepresentable(model: model, offline: model.link != .live)
        }
    }
}

/// Puente a la vista nativa de los ojos.
private struct EyesRepresentable: NSViewRepresentable {
    let model: MascotaModel
    let offline: Bool

    func makeNSView(context: Context) -> EyesView {
        let v = EyesView()
        model.sink = v
        v.setOffline(offline)
        return v
    }

    func updateNSView(_ view: EyesView, context: Context) {
        if model.sink !== view { model.sink = view }
        view.setOffline(offline)
    }
}

/// Dos "pantallas OLED" con los ojos. Los cuadros llegan directo a capas de Core Animation
/// (filtro nearest: píxel nítido, sin suavizado) y el tamaño se ajusta a múltiplos enteros
/// de píxel para que todos los píxeles del robot midan lo mismo en pantalla.
final class EyesView: NSView {
    private let screens = [CALayer(), CALayer()]
    private let eyes = [CALayer(), CALayer()]
    private var offline = false
    private var liveImages: [CGImage] = []
    private var glow = CGColor(red: 0.91, green: 0.95, blue: 1, alpha: 1)
    private static let closed = MascotaModel.closedEye()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let noAnimations: [String: CAAction] = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
            "shadowColor": NSNull(), "shadowOpacity": NSNull(), "opacity": NSNull(),
        ]
        for i in 0..<2 {
            screens[i].backgroundColor = CGColor(gray: 0, alpha: 0.88)
            screens[i].borderColor = CGColor(gray: 1, alpha: 0.06)
            screens[i].borderWidth = 1
            screens[i].actions = noAnimations
            eyes[i].magnificationFilter = .nearest
            eyes[i].minificationFilter = .nearest
            eyes[i].contentsGravity = .resize
            eyes[i].shadowOffset = .zero
            eyes[i].shadowRadius = 3
            eyes[i].shadowOpacity = 0.55
            eyes[i].actions = noAnimations
            layer?.addSublayer(screens[i])
            screens[i].addSublayer(eyes[i])
        }
    }

    required init?(coder: NSCoder) { nil }

    // Los clics y el arrastre los maneja SwiftUI (tocar / mover el widget).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        relayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout()
    }

    private func relayout() {
        let scale = window?.backingScaleFactor ?? 2
        let gap = (bounds.width * 0.03).rounded()
        let screenW = (bounds.width - gap) / 2
        let screenH = bounds.height
        let pad = min(screenW, screenH) * 0.05
        // Múltiplo entero de píxeles del dispositivo por cada píxel del robot.
        let k = max(1, floor(min((screenW - pad * 2) * scale / 128, (screenH - pad * 2) * scale / 64)))
        let eyeW = 128 * k / scale, eyeH = 64 * k / scale
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<2 {
            screens[i].frame = CGRect(x: CGFloat(i) * (screenW + gap), y: 0, width: screenW, height: screenH)
            screens[i].cornerRadius = min(screenW, screenH) * 0.09
            eyes[i].frame = CGRect(x: snap((screenW - eyeW) / 2), y: snap((screenH - eyeH) / 2),
                                   width: eyeW, height: eyeH)
            eyes[i].contentsScale = scale
            eyes[i].shadowRadius = 3 * k / 3
        }
        CATransaction.commit()
    }

    func show(_ images: [CGImage], glow: CGColor) {
        liveImages = images
        self.glow = glow
        guard !offline else { return }
        apply()
    }

    func setOffline(_ value: Bool) {
        guard value != offline else { return }
        offline = value
        apply()
    }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<2 {
            if offline || liveImages.count < 2 {
                eyes[i].contents = Self.closed
                eyes[i].shadowOpacity = 0
            } else {
                eyes[i].contents = liveImages[i]
                eyes[i].shadowColor = glow
                eyes[i].shadowOpacity = 0.55
            }
        }
        CATransaction.commit()
    }
}

/// Versión SwiftUI solo para las capturas (ImageRenderer no dibuja vistas de AppKit).
private struct EyesPreview: View {
    let images: [CGImage]
    let offline: Bool

    var body: some View {
        GeometryReader { g in
            let gap = (g.size.width * 0.03).rounded()
            let w = (g.size.width - gap) / 2
            HStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { i in
                    ZStack {
                        RoundedRectangle(cornerRadius: min(w, g.size.height) * 0.09)
                            .fill(Color.black.opacity(0.88))
                        if !offline, i < images.count {
                            Image(decorative: images[i], scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 192 * g.size.width / 432, height: 96 * g.size.width / 432)
                                .shadow(color: Color(white: 0.92).opacity(0.55), radius: 3)
                        } else if let c = MascotaModel.closedEye() {
                            Image(decorative: c, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 192 * g.size.width / 432, height: 96 * g.size.width / 432)
                        }
                    }
                    .frame(width: w)
                }
            }
        }
    }
}
