import AppKit
import Observation
import SwiftUI

/// Estilo visual de todas las tarjetas. Se guarda entre sesiones.
@Observable
final class Appearance {
    enum Style: String, CaseIterable {
        case solid, glass, frosted

        var title: String {
            switch self {
            case .solid: "Sólido"
            case .glass: "Vidrio líquido"
            case .frosted: "Vidrio esmerilado"
            }
        }
    }

    static let shared = Appearance()
    private static let key = "Mosaico.style"

    var style: Style {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.key) }
    }

    var isTranslucent: Bool { style != .solid }

    private init() {
        style = UserDefaults.standard.string(forKey: Self.key).flatMap(Style.init(rawValue:)) ?? .glass
    }
}

/// Fondo de la tarjeta según el estilo. Los modos de vidrio llevan una capa oscura
/// para que el texto y los píxeles se lean bien sobre cualquier fondo de pantalla.
struct CardBackground: View {
    let style: Appearance.Style
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch style {
        case .solid:
            shape.fill(Color(white: 0.085))
                .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
        case .glass:
            glass(shape)
                .overlay(shape.fill(Color.black.opacity(0.26)))
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
        case .frosted:
            FrostedView()
                .clipShape(shape)
                .overlay(shape.fill(Color.black.opacity(0.22)))
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
    }

    @ViewBuilder private func glass(_ shape: RoundedRectangle) -> some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(Color.black.opacity(0.32)), in: shape)
        } else {
            FrostedView().clipShape(shape).overlay(shape.fill(Color.black.opacity(0.1)))
        }
    }
}

/// Desenfoque clásico de macOS de lo que hay detrás de la ventana (siempre activo).
struct FrostedView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Sombra suave para que el texto no se pierda sobre fondos claros (solo en vidrio).
    @ViewBuilder func legibleOnGlass(_ enabled: Bool) -> some View {
        if enabled {
            self.shadow(color: .black.opacity(0.45), radius: 1.2, x: 0, y: 0.5)
        } else {
            self
        }
    }
}
