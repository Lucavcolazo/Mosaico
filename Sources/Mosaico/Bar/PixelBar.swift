import SwiftUI

/// La barra de "píxeles". Se dibuja en un Canvas más grande que la barra para que el
/// brillo y las partículas puedan salirse de sus bordes. Todas las medidas están a
/// escala 1 y se multiplican por `s`.
enum PixelBar {
    static let height: CGFloat = 84
    static let padSide: CGFloat = 14
    static let padTop: CGFloat = 72
    static let padBottom: CGFloat = 14
    static let pitch: CGFloat = 6
    static let cell: CGFloat = 4
    static let radius: CGFloat = 10

    private struct Segment {
        var item: BarItem
        var x0: Double
        var x1: Double
    }

    static func insets(_ s: CGFloat) -> EdgeInsets {
        EdgeInsets(top: -padTop * s, leading: -padSide * s, bottom: -padBottom * s, trailing: -padSide * s)
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, s: CGFloat,
                     source: any BarSource, anim: BarAnimator) {
        let bar = CGRect(x: padSide * s, y: padTop * s,
                         width: size.width - padSide * s * 2,
                         height: size.height - (padTop + padBottom) * s)
        anim.barRect = bar
        anim.scale = s
        let cap = max(source.barCapacity, 1)
        let pitch = Self.pitch * s
        let cell = Self.cell * s
        let radius = Self.radius * s

        var segments: [Segment] = []
        var acc = 0.0
        for item in source.barItems {
            let w = (anim.shown[item.id] ?? 0) / cap * bar.width
            if w > 0.25 { segments.append(Segment(item: item, x0: bar.minX + acc, x1: bar.minX + acc + w)) }
            acc += w
        }
        let fillEnd = bar.minX + acc
        let glow = anim.scanGlow
        let clearing = source.clearingID
        let barPath = Path(roundedRect: bar, cornerRadius: radius)

        // 1. Brillos por detrás (sin recorte).
        if glow > 0.01 {
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: 14 * s))
                g.fill(Path(CGRect(x: fillEnd - 18 * s, y: bar.minY - 6 * s, width: 26 * s, height: bar.height + 12 * s)),
                       with: .color(.white.opacity(0.55 * glow)))
            }
        }
        for seg in segments {
            let e = anim.emphasis[seg.item.id] ?? 1
            guard e > 1.02 else { continue }
            let amount = min(1, (e - 1) / 0.3)
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: 16 * s))
                g.fill(Path(CGRect(x: seg.x0, y: bar.minY, width: seg.x1 - seg.x0, height: bar.height)),
                       with: .color(Color(rgb: seg.item.rgb, opacity: 0.45 * amount)))
            }
        }

        // 2. Contenido recortado a la forma de la barra.
        ctx.drawLayer { g in
            g.clip(to: barPath)
            g.fill(barPath, with: .color(.white.opacity(0.025)))

            for seg in segments {
                let e = min(1, anim.emphasis[seg.item.id] ?? 1)
                g.fill(Path(CGRect(x: seg.x0, y: bar.minY, width: seg.x1 - seg.x0, height: bar.height)),
                       with: .color(Color(rgb: seg.item.rgb, opacity: 0.10 * e)))
            }

            let cols = Int(bar.width / pitch)
            let rows = Int(bar.height / pitch)
            let ox = bar.minX + (bar.width - CGFloat(cols) * pitch) / 2 + (pitch - cell) / 2
            let oy = bar.minY + (bar.height - CGFloat(rows) * pitch) / 2 + (pitch - cell) / 2
            let twinkleTick = Int(t * 3)
            let flickerTick = Int(t * 24)
            let dot = 1.6 * s
            let dotInset = (cell - dot) / 2
            let glowReach = 70 * s
            let clearReach = 18 * s
            var si = 0

            for col in 0..<cols {
                let x = ox + CGFloat(col) * pitch
                let cx = Double(x + cell / 2)
                while si < segments.count, cx > segments[si].x1 { si += 1 }

                guard si < segments.count, cx >= segments[si].x0 else {
                    // Espacio libre: puntitos grises.
                    for row in 0..<rows {
                        let y = oy + CGFloat(row) * pitch
                        g.fill(Path(CGRect(x: x + dotInset, y: y + dotInset, width: dot, height: dot)),
                               with: .color(.white.opacity(0.07)))
                    }
                    continue
                }

                let seg = segments[si]
                let seed = seg.item.seed
                let rgbBase = seg.item.rgb
                let emph = anim.emphasis[seg.item.id] ?? 1
                let colBias = hash(col / 3, 7, seed) * 0.22
                for row in 0..<rows {
                    let y = oy + CGFloat(row) * pitch
                    let dEdge = min(row, rows - 1 - row)
                    let edgeBoost = dEdge == 0 ? 0.6 : (dEdge == 1 ? 0.22 : 0)
                    let density = 0.12 + edgeBoost + colBias
                    var lit = hash(col, row, seed) < density
                    if anim.running, hash(col, row, twinkleTick) > 0.985 { lit.toggle() }

                    var alpha = lit ? 0.9 : 0.17
                    var white = emph > 1 ? (emph - 1) * 0.5 : 0
                    alpha *= min(1, emph)

                    if glow > 0.01 {
                        let dist = fillEnd - cx
                        if dist < glowReach {
                            let w = pow(max(0, 1 - dist / glowReach), 1.6) * glow
                            white = max(white, w * 0.95)
                            alpha = max(alpha, w * (lit ? 1 : 0.85))
                        }
                    }
                    if seg.item.id == clearing {
                        let dist = seg.x1 - cx
                        if dist < clearReach {
                            let w = 1 - dist / clearReach
                            white = max(white, 0.65 * w)
                            alpha = max(alpha, w) * (0.35 + 0.65 * hash(col, row, flickerTick))
                        }
                    }

                    let rgb = rgbBase + (SIMD3<Double>(repeating: 1) - rgbBase) * min(1, white)
                    g.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                           with: .color(Color(rgb: rgb, opacity: alpha)))
                }
            }

            // Bordes de cada segmento.
            for (i, seg) in segments.enumerated() {
                let e = min(1, anim.emphasis[seg.item.id] ?? 1)
                let rect = CGRect(x: seg.x0, y: bar.minY, width: seg.x1 - seg.x0, height: bar.height)
                    .insetBy(dx: 0.5, dy: 0.5)
                let path: Path
                if i == 0 {
                    path = UnevenRoundedRectangle(topLeadingRadius: radius - 0.5, bottomLeadingRadius: radius - 0.5)
                        .path(in: rect)
                } else {
                    path = Path(rect)
                }
                g.stroke(path, with: .color(Color(rgb: seg.item.rgb, opacity: 0.85 * e)), lineWidth: 1)
                if i > 0 {
                    g.fill(Path(CGRect(x: seg.x0 - 0.5, y: bar.minY, width: 1, height: bar.height)),
                           with: .color(.white.opacity(0.28 * e)))
                }
            }
        }

        ctx.stroke(barPath, with: .color(.white.opacity(0.06)), lineWidth: 1)

        // 3. Partículas encima de todo.
        for p in anim.particles {
            let life = p.age / p.life
            let a = (1 - life) * (life < 0.1 ? life * 10 : 1)
            ctx.fill(Path(CGRect(x: p.x, y: p.y, width: p.size, height: p.size)),
                     with: .color(Color(rgb: p.rgb, opacity: a)))
        }
    }

    @inline(__always)
    static func hash(_ a: Int, _ b: Int, _ c: Int = 0) -> Double {
        var x = UInt64(bitPattern: Int64((a &* 73_856_093) ^ (b &* 19_349_663) ^ (c &* 83_492_791)))
        x ^= x >> 33
        x &*= 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        x &*= 0xc4ce_b9fe_1a85_ec53
        x ^= x >> 33
        return Double(x & 0xFF_FFFF) / Double(0xFF_FFFF)
    }
}
