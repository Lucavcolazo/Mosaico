import Foundation

/// Un segmento de la barra de píxeles (una categoría, una carpeta, etc.).
struct BarItem: Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    var rgb: SIMD3<Double>
    var bytes: Double

    var seed: Int { stableSeed(id) }
}

/// Lo que necesita la barra animada para dibujarse. Lo implementan los modelos de cada widget.
protocol BarSource: AnyObject {
    var barItems: [BarItem] { get }
    var barCapacity: Double { get }
    var hoveredID: String? { get set }
    var isScanning: Bool { get }
    var clearingID: String? { get }
    var isBusy: Bool { get }
    var canHover: Bool { get }
}

extension BarSource {
    /// Qué segmento hay en una posición horizontal de la barra (0…1).
    func itemID(atFraction f: Double) -> String? {
        var acc = 0.0
        let cap = max(barCapacity, 1)
        for item in barItems {
            acc += item.bytes / cap
            if f <= acc { return item.bytes > 0 ? item.id : nil }
        }
        return nil
    }
}

func stableSeed(_ s: String) -> Int {
    var h: UInt64 = 5381
    for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
    return Int(h & 0x7FFF_FFFF)
}

/// Paleta compartida para segmentos que no son categorías fijas.
enum Palette {
    static let colors: [SIMD3<Double>] = [
        [0.27, 0.56, 1.00], [0.26, 0.86, 0.42], [0.96, 0.30, 0.62], [0.62, 0.38, 1.00],
        [0.20, 0.82, 0.86], [1.00, 0.80, 0.22], [1.00, 0.56, 0.16], [1.00, 0.27, 0.32],
    ]
    static let gray: SIMD3<Double> = [0.66, 0.68, 0.72]
    static let darkGray: SIMD3<Double> = [0.46, 0.48, 0.52]
}
