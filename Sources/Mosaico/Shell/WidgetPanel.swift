import AppKit
import Observation
import SwiftUI

/// Estado compartido entre un panel (AppKit) y su tarjeta (SwiftUI):
/// puntero, escala y los marcos de las zonas con hover.
@Observable
final class WidgetContext {
    static let scaleRange: ClosedRange<CGFloat> = 0.6...1.6

    let id: String
    /// Posición del puntero en coordenadas .global de SwiftUI. La medimos desde AppKit
    /// para que el hover funcione aunque la app no esté activa.
    var pointer: CGPoint?
    var scale: CGFloat {
        didSet {
            let clamped = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
            if clamped != scale { scale = clamped; return }
            UserDefaults.standard.set(Double(scale), forKey: scaleKey)
        }
    }

    // Guardado acá porque @State necesita las macros de Xcode completo.
    @ObservationIgnored var rowFrames: [String: CGRect] = [:]
    @ObservationIgnored var barFrame: CGRect = .zero
    @ObservationIgnored var resizeStartScale: CGFloat?
    @ObservationIgnored var onContentSize: ((CGSize) -> Void)?

    private var scaleKey: String { "Mosaico.scale.\(id)" }

    init(id: String) {
        self.id = id
        let stored = UserDefaults.standard.double(forKey: "Mosaico.scale.\(id)")
        scale = stored > 0 ? CGFloat(stored) : 1
    }
}

final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    var onPointer: ((CGPoint?) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        report(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }

    private func report(_ event: NSEvent) {
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        onPointer?(p)
    }
}

/// Ventana sin bordes que vive en el escritorio (o encima de todo, según preferencia).
final class WidgetPanel: NSPanel {
    let context: WidgetContext

    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    /// `placement` elige dónde aparece la primera vez (recibe el tamaño del panel).
    init<Content: View>(context: WidgetContext, content: Content, placement: (NSSize) -> NSPoint) {
        self.context = context
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        let host = WidgetHostingView(rootView: content.gesture(WindowDragGesture()))
        // Solo tamaño intrínseco: el panel lo ajustamos a mano para que la esquina
        // superior izquierda quede fija al cambiar la escala.
        host.sizingOptions = [.intrinsicContentSize]
        host.onPointer = { [weak context] in context?.pointer = $0 }
        contentView = host
        let initial = host.intrinsicContentSize
        setContentSize(initial.width > 0 && initial.height > 0 ? initial : host.fittingSize)
        restorePosition(placement: placement)
        invalidateShadow()

        context.onContentSize = { [weak self] size in self?.fit(to: size) }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in self?.savePosition() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func applyLevel(onTop: Bool) {
        level = onTop ? .floating : Self.desktopLevel
    }

    /// Cambia el tamaño dejando fija la esquina superior izquierda.
    private func fit(to size: CGSize) {
        let w = ceil(size.width), h = ceil(size.height)
        guard w > 0, h > 0, abs(w - frame.width) > 0.5 || abs(h - frame.height) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - h, width: w, height: h), display: true)
        invalidateShadow()
    }

    private var defaultsKey: String { "Mosaico.topLeft.\(context.id)" }

    private func savePosition() {
        // Guardamos la esquina superior izquierda, que es la que no se mueve al redimensionar.
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: defaultsKey)
    }

    private func restorePosition(placement: (NSSize) -> NSPoint) {
        if let s = UserDefaults.standard.string(forKey: defaultsKey) {
            let topLeft = NSPointFromString(s)
            let onScreen = NSScreen.screens.contains { $0.frame.insetBy(dx: -40, dy: -40).contains(topLeft) }
            if onScreen {
                setFrameTopLeftPoint(topLeft)
                return
            }
        }
        // Versión anterior: guardaba la esquina inferior izquierda.
        let legacyKey = "Mosaico.position.\(context.id)"
        if let s = UserDefaults.standard.string(forKey: legacyKey) {
            UserDefaults.standard.removeObject(forKey: legacyKey)
            let origin = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.frame.contains(origin) }) {
                setFrameOrigin(origin)
                savePosition()
                return
            }
        }
        setFrameOrigin(placement(frame.size))
    }
}
