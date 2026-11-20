// Genera el ícono de Mosaico (Support/AppIcon.icns) con CoreGraphics.
// Uso: swift scripts/make-icon.swift   (desde la carpeta del proyecto)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let palette: [(Double, Double, Double)] = [
    (0.27, 0.56, 1.00),  // azul
    (0.26, 0.86, 0.42),  // verde
    (0.96, 0.30, 0.62),  // rosa
    (0.62, 0.38, 1.00),  // violeta
    (0.20, 0.82, 0.86),  // cian
    (1.00, 0.56, 0.16),  // naranja
]
/// Cuántos píxeles se encienden en cada columna, de abajo hacia arriba.
let heights = [4, 6, 3, 5, 2, 4]
let grid = 6

func color(_ c: (Double, Double, Double), _ a: Double = 1, white w: Double = 0) -> CGColor {
    CGColor(srgbRed: c.0 + (1 - c.0) * w, green: c.1 + (1 - c.1) * w, blue: c.2 + (1 - c.2) * w, alpha: a)
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    // Cuerpo del ícono: 824×824 centrado (grilla de íconos de macOS), esquinas continuas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Sombra suave debajo.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Fondo oscuro con degradé vertical.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [CGColor(srgbRed: 0.16, green: 0.165, blue: 0.19, alpha: 1),
                                 CGColor(srgbRed: 0.045, green: 0.045, blue: 0.055, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

    // Grilla de píxeles.
    let area = body.insetBy(dx: 150, dy: 150)
    let pitch = area.width / CGFloat(grid)
    let cell = pitch * 0.8
    let inset = (pitch - cell) / 2
    func cellRect(_ col: Int, _ row: Int) -> CGRect {
        CGRect(x: area.minX + CGFloat(col) * pitch + inset, y: area.minY + CGFloat(row) * pitch + inset,
               width: cell, height: cell)
    }
    func fill(_ r: CGRect, _ c: CGColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: cell * 0.2, cornerHeight: cell * 0.2, transform: nil))
        ctx.setFillColor(c)
        ctx.fillPath()
    }

    // Brillo de color detrás de las columnas encendidas.
    ctx.saveGState()
    for col in 0..<grid {
        for row in 0..<heights[col] {
            ctx.setShadow(offset: .zero, blur: 46, color: color(palette[col], 0.55))
            fill(cellRect(col, row), color(palette[col], 0.9))
        }
    }
    ctx.restoreGState()

    for col in 0..<grid {
        for row in 0..<grid {
            let r = cellRect(col, row)
            if row < heights[col] {
                let top = row == heights[col] - 1
                fill(r, color(palette[col], 1, white: top ? 0.35 : 0))
            } else {
                fill(r, CGColor(gray: 1, alpha: 0.07))
            }
        }
    }

    // Reflejo arriba y borde fino, como el vidrio de los widgets.
    let shine = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.midY + 120), options: [])
    ctx.restoreGState()

    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
    ctx.setLineWidth(4)
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Mosaico.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
writePNG(render(size: 1024), to: URL(fileURLWithPath: "Support/AppIcon-1024.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Listo: Support/AppIcon.icns" : "iconutil falló")
