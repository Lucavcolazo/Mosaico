import SwiftUI

/// Las categorías en el orden en que aparecen en la barra (izquierda → derecha).
enum StorageCategory: String, CaseIterable, Identifiable {
    case apps, developer, photos, movies, documents, music, appData, system, caches, trash

    var id: String { rawValue }

    /// Orden de la leyenda: 3 columnas, se lee fila por fila.
    static let legendOrder: [StorageCategory] = [
        .apps, .developer, .photos,
        .movies, .documents, .music,
        .appData, .caches, .trash,
        .system,
    ]

    var name: String {
        switch self {
        case .apps: "Apps"
        case .developer: "Desarrollo"
        case .photos: "Fotos"
        case .movies: "Videos"
        case .documents: "Documentos"
        case .music: "Música"
        case .appData: "Datos de apps"
        case .system: "Sistema"
        case .caches: "Cachés"
        case .trash: "Papelera"
        }
    }

    var symbol: String {
        switch self {
        case .apps: "macwindow"
        case .developer: "hammer.fill"
        case .photos: "photo.fill"
        case .movies: "film.fill"
        case .documents: "doc.text.fill"
        case .music: "music.note"
        case .appData: "square.stack.3d.up.fill"
        case .system: "gearshape.fill"
        case .caches: "shippingbox.fill"
        case .trash: "trash.fill"
        }
    }

    /// Color base en RGB lineal 0…1 (se usa tanto en SwiftUI como en el Canvas).
    var rgb: SIMD3<Double> {
        switch self {
        case .apps: [0.27, 0.56, 1.00]
        case .developer: [0.26, 0.86, 0.42]
        case .photos: [0.96, 0.30, 0.62]
        case .movies: [0.62, 0.38, 1.00]
        case .documents: [0.20, 0.82, 0.86]
        case .music: [1.00, 0.80, 0.22]
        case .appData: [0.88, 0.74, 0.54]
        case .system: [0.66, 0.68, 0.72]
        case .caches: [1.00, 0.56, 0.16]
        case .trash: [1.00, 0.27, 0.32]
        }
    }

    var color: Color { Color(rgb: rgb) }

    func barItem(bytes: Double) -> BarItem {
        BarItem(id: rawValue, name: name, symbol: symbol, rgb: rgb, bytes: bytes)
    }

    /// Carpetas que se miden para cada categoría. `system` es lo que sobra.
    var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func h(_ p: String) -> URL { home.appendingPathComponent(p, isDirectory: true) }
        switch self {
        case .apps:
            return [URL(fileURLWithPath: "/Applications", isDirectory: true), h("Applications")]
        case .developer:
            return [
                h("Library/Developer"), h("Library/Android"),
                h(".npm"), h(".bun"), h(".cargo"), h(".rustup"), h(".gradle"), h(".m2"),
                h(".cocoapods"), h(".pyenv"), h(".nvm"), h(".pnpm-store"), h(".cache"),
            ]
        case .photos: return [h("Pictures")]
        case .movies: return [h("Movies")]
        case .documents: return [h("Documents"), h("Desktop"), h("Downloads")]
        case .music: return [h("Music")]
        case .appData: return [h("Library")]
        case .system: return []
        case .caches: return [h("Library/Caches")]
        case .trash: return [h(".Trash")]
        }
    }

    /// Carpetas dentro de `roots` que ya cuentan en otra categoría.
    var excluded: [URL] {
        guard self == .appData else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Library/Caches", "Library/Developer", "Library/Android"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Para "lo más pesado": en ~/Library interesa un nivel más (p. ej. Application Support/Google).
    var childDepth: Int { self == .appData ? 2 : 1 }

    /// Texto fijo para el hover cuando no hay algo más interesante que decir.
    var blurb: String {
        switch self {
        case .system: "macOS, archivos protegidos y espacio purgable."
        case .caches: "Las apps las regeneran cuando las necesitan."
        case .trash: "Cosas que ya borraste."
        default: ""
        }
    }
}

extension Color {
    init(rgb: SIMD3<Double>, opacity: Double = 1) {
        self.init(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z, opacity: opacity)
    }
}

enum ByteFormat {
    static func gb(_ bytes: Double, digits: Int = 1) -> String {
        let value = max(0, bytes) / 1_000_000_000
        return value.formatted(.number.precision(.fractionLength(digits))) + " GB"
    }

    static func gbNumber(_ bytes: Double) -> String {
        (max(0, bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(1)))
    }

    /// "357,8 GB" o "1,24 TB" según el tamaño.
    static func amount(_ bytes: Double) -> String {
        let b = max(0, bytes)
        if b >= 999.95e9 {
            return (b / 1e12).formatted(.number.precision(.fractionLength(2))) + " TB"
        }
        return gb(b)
    }

    static func capacity(_ bytes: Double) -> String {
        if bytes >= 999.5e9 {
            return (bytes / 1e12).formatted(.number.precision(.fractionLength(0...1))) + " TB"
        }
        return (bytes / 1_000_000_000).formatted(.number.precision(.fractionLength(0))) + " GB"
    }

    /// Ruta con ~ y recortada por el medio para que entre en una línea.
    static func shortPath(_ path: String, max: Int = 46) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = path
        if p.hasPrefix(home) { p = "~" + String(p.dropFirst(home.count)) }
        guard p.count > max else { return p }
        let keep = max - 1
        let head = String(p.prefix(keep / 2))
        let tail = String(p.suffix(keep - keep / 2))
        return head + "…" + tail
    }
}
