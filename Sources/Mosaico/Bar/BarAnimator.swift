import Foundation
import Observation

struct Particle {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var age: Double = 0
    var life: Double
    var size: Double
    var rgb: SIMD3<Double>
}

/// Lleva los valores "mostrados" hacia los reales cuadro a cuadro, y maneja las partículas.
/// Solo `running` es observable: cuando todo se asienta, el TimelineView se pausa y la
/// app deja de gastar CPU.
@Observable
final class BarAnimator {
    private(set) var running = false

    @ObservationIgnored weak var source: (any BarSource)?
    @ObservationIgnored private(set) var shown: [String: Double] = [:]
    @ObservationIgnored private(set) var emphasis: [String: Double] = [:]
    @ObservationIgnored private(set) var scanGlow: Double = 0
    @ObservationIgnored private(set) var particles: [Particle] = []
    /// Rectángulo de la barra dentro del Canvas y escala actual (los actualiza el dibujo).
    @ObservationIgnored var barRect: CGRect = .zero
    @ObservationIgnored var scale: Double = 1
    @ObservationIgnored private var last: Date?
    @ObservationIgnored private var stopPending = false

    /// Total mostrado (animado) de los segmentos actuales.
    var shownTotal: Double {
        (source?.barItems ?? []).reduce(0) { $0 + (shown[$1.id] ?? 0) }
    }

    func kick() {
        if !running {
            last = nil
            running = true
        }
    }

    /// Salta directo a los valores finales (para capturas).
    func snap() {
        guard let source else { return }
        for item in source.barItems {
            shown[item.id] = item.bytes
            emphasis[item.id] = emphasisTarget(item.id, source)
        }
        scanGlow = 0
        particles = []
    }

    private func emphasisTarget(_ id: String, _ s: any BarSource) -> Double {
        guard let h = s.hoveredID else { return 1 }
        return h == id ? 1.3 : 0.3
    }

    func step(now: Date) {
        guard let source else { return }
        let items = source.barItems
        let dt = last.map { min(1.0 / 20, max(0, now.timeIntervalSince($0))) } ?? (1.0 / 60)
        last = now
        let cap = max(source.barCapacity, 1)
        let kSize = 1 - exp(-dt * 7)
        let kEmph = 1 - exp(-dt * 14)
        var moving = false

        let before = shown
        for item in items {
            let target = item.bytes
            let cur = shown[item.id] ?? 0
            let next = cur + (target - cur) * kSize
            if abs(target - next) > cap * 0.0002 { moving = true; shown[item.id] = next } else { shown[item.id] = target }

            let eT = emphasisTarget(item.id, source)
            let eCur = emphasis[item.id] ?? 1
            let eNext = eCur + (eT - eCur) * kEmph
            if abs(eT - eNext) > 0.005 { moving = true; emphasis[item.id] = eNext } else { emphasis[item.id] = eT }
        }

        let glowTarget = source.isScanning ? 1.0 : 0.0
        scanGlow += (glowTarget - scanGlow) * (1 - exp(-dt * 5))
        if abs(glowTarget - scanGlow) > 0.01 { moving = true } else { scanGlow = glowTarget }

        // Partículas: salen del borde derecho del segmento que se está borrando.
        if let cid = source.clearingID, let item = items.first(where: { $0.id == cid }), barRect.width > 0 {
            let s = scale
            let edge = edgeX(of: cid, items: items, cap: cap)
            let shrink = max(0, (before[cid] ?? 0) - (shown[cid] ?? 0)) / cap * barRect.width / s
            let count = Int(dt * 90) + Int(min(40, shrink * 9)) + (Double.random(in: 0...1) < 0.5 ? 1 : 0)
            for _ in 0..<count {
                let whiten = Double.random(in: 0.15...0.85)
                let rgb = item.rgb + (SIMD3<Double>(repeating: 1) - item.rgb) * whiten
                particles.append(Particle(
                    x: edge - Double.random(in: 0...10) * s,
                    y: barRect.minY + Double.random(in: 0...barRect.height),
                    vx: Double.random(in: -18...26) * s,
                    vy: Double.random(in: -95 ... -15) * s,
                    life: Double.random(in: 0.5...1.3),
                    size: [1.5, 2, 2.5, 3].randomElement()! * s,
                    rgb: rgb
                ))
            }
            moving = true
        }
        if !particles.isEmpty {
            for i in particles.indices {
                particles[i].age += dt
                particles[i].vy -= 40 * scale * dt
                particles[i].vx *= 1 - 1.5 * dt
                particles[i].x += particles[i].vx * dt
                particles[i].y += particles[i].vy * dt
            }
            particles.removeAll { $0.age >= $0.life }
            moving = true
        }

        if source.isBusy { moving = true }

        if !moving && !stopPending {
            stopPending = true
            DispatchQueue.main.async {
                self.stopPending = false
                if self.isSettled() { self.running = false }
            }
        }
    }

    func edgeX(of id: String, items: [BarItem], cap: Double) -> Double {
        var acc = 0.0
        for k in items {
            acc += shown[k.id] ?? 0
            if k.id == id { break }
        }
        return barRect.minX + acc / cap * barRect.width
    }

    private func isSettled() -> Bool {
        guard let source else { return true }
        guard !source.isBusy, particles.isEmpty, scanGlow == 0 else { return false }
        let cap = max(source.barCapacity, 1)
        for item in source.barItems {
            if abs(item.bytes - (shown[item.id] ?? 0)) > cap * 0.0002 { return false }
            if abs(emphasisTarget(item.id, source) - (emphasis[item.id] ?? 1)) > 0.005 { return false }
        }
        return true
    }
}
