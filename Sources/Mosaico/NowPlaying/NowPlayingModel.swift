import AppKit
import Observation

/// Lo que suena en Spotify: canción, posición, portada (y su versión en píxeles).
@Observable
final class NowPlayingModel {
    enum Status: Equatable { case notInstalled, closed, stopped, denied, playing, paused }

    static let coverGrid = 24

    private(set) var status: Status = .closed
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var duration: Double = 0
    private(set) var artwork: NSImage?
    /// Portada reducida a 24×24 (fila por fila, de arriba hacia abajo).
    private(set) var coverPixels: [SIMD3<Double>] = []
    private(set) var previousPixels: [SIMD3<Double>] = []
    private(set) var coverChangedAt = Date.distantPast
    /// Un color por columna de la portada, más saturado: tiñe la barra de progreso.
    private(set) var barColors: [SIMD3<Double>] = []
    private(set) var animatingUntil = Date.distantPast
    /// true mientras dura la animación de cambio de portada.
    private(set) var coverAnimating = false
    var hoveringCover = false

    private var position: Double = 0
    private var syncedAt = Date()
    @ObservationIgnored private var trackID = ""
    @ObservationIgnored private var artworkURL: URL?
    @ObservationIgnored private let bridge = SpotifyBridge()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        if demo { loadDemo(); return }
        status = bridge.isInstalled ? .closed : .notInstalled
    }

    var isPlaying: Bool { status == .playing }
    var hasTrack: Bool { status == .playing || status == .paused }

    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        return min(duration, position + date.timeIntervalSince(syncedAt))
    }

    var isAnimating: Bool { Date() < animatingUntil }

    // MARK: - Ciclo de vida

    func start() {
        guard !demo, observers.isEmpty else { return }
        // Spotify avisa cada vez que cambia algo (play, pausa, canción).
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyBridge.bundleID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.refresh() }
            })
        }
        // Resincroniza la posición de vez en cuando (por si adelantás desde Spotify), solo mientras
        // suena: los cambios de play/pausa/canción ya llegan por la notificación de Spotify.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            if self?.status == .playing { self?.refresh() }
        }
        timer?.tolerance = 3
        refresh()
    }

    func refresh() {
        guard !demo else { return }
        bridge.fetch { [weak self] result in self?.apply(result) }
    }

    private func apply(_ result: SpotifyResult) {
        switch result {
        case .closed:
            status = bridge.isInstalled ? .closed : .notInstalled
        case .stopped:
            status = .stopped
        case .denied:
            status = .denied
        case .failed:
            break
        case .track(let t):
            status = t.playing ? .playing : .paused
            title = t.title
            artist = t.artist
            album = t.album
            duration = t.duration
            position = t.position
            syncedAt = Date()
            trackID = t.id
            if t.artworkURL != artworkURL {
                artworkURL = t.artworkURL
                loadArtwork(t.artworkURL)
            }
        }
    }

    // MARK: - Controles

    func playPause() {
        if demo { status = isPlaying ? .paused : .playing; syncedAt = Date(); return }
        position = position(at: Date())
        syncedAt = Date()
        status = isPlaying ? .paused : .playing   // respuesta inmediata; después se confirma
        bridge.send("playpause") { [weak self] in self?.refresh() }
    }

    func next() { bridge.send("next track") { [weak self] in self?.refreshSoon() } }
    func previous() { bridge.send("previous track") { [weak self] in self?.refreshSoon() } }

    func skip(by seconds: Double) {
        seek(to: position(at: Date()) + seconds)
    }

    func seek(fraction: Double) {
        seek(to: max(0, min(1, fraction)) * duration)
    }

    private func seek(to seconds: Double) {
        let target = max(0, min(duration - 1, seconds))
        position = target
        syncedAt = Date()
        animatingUntil = Date().addingTimeInterval(0.3)
        if demo { return }
        bridge.send("set player position to \(String(format: "%.2f", target))") { [weak self] in self?.refreshSoon() }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }

    func openSpotify() { bridge.launch() }

    // MARK: - Portada

    private func loadArtwork(_ url: URL?) {
        guard let url else { setArtwork(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async { [weak self] in
                guard self?.artworkURL == url else { return }
                self?.setArtwork(image)
            }
        }.resume()
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        previousPixels = coverPixels
        coverPixels = image.map { Self.pixels(of: $0, n: Self.coverGrid) } ?? []
        barColors = Self.columnColors(coverPixels, n: Self.coverGrid)
        coverChangedAt = Date()
        animatingUntil = Date().addingTimeInterval(1.1)
        coverAnimating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in
            guard let self, Date() >= self.animatingUntil else { return }
            self.coverAnimating = false
        }
    }

    static func pixels(of image: NSImage, n: Int) -> [SIMD3<Double>] {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return [] }
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        ctx?.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(n * n)
        for y in 0..<n {
            for x in 0..<n {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                out.append([Double(c?.redComponent ?? 0), Double(c?.greenComponent ?? 0), Double(c?.blueComponent ?? 0)])
            }
        }
        return out
    }

    static func columnColors(_ px: [SIMD3<Double>], n: Int) -> [SIMD3<Double>] {
        guard px.count == n * n else { return [] }
        return (0..<n).map { x in
            var sum = SIMD3<Double>(repeating: 0)
            for y in 0..<n { sum += px[y * n + x] }
            let avg = sum / Double(n)
            let c = NSColor(srgbRed: avg.x, green: avg.y, blue: avg.z, alpha: 1)
            let boosted = NSColor(hue: c.hueComponent,
                                  saturation: min(1, c.saturationComponent * 1.5 + 0.1),
                                  brightness: max(0.75, c.brightnessComponent),
                                  alpha: 1).usingColorSpace(.sRGB)!
            return [Double(boosted.redComponent), Double(boosted.greenComponent), Double(boosted.blueComponent)]
        }
    }

    // MARK: - Textos

    static func time(_ s: Double) -> String {
        let total = max(0, Int(s.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    // MARK: - Demo (capturas)

    private func loadDemo() {
        status = .playing
        title = "Nubes de Neón"
        artist = "Los Píxeles"
        album = "Mosaico (Deluxe)"
        duration = 214
        position = 83
        syncedAt = Date()
        // Portada inventada: un degradé con un sol.
        let n = Self.coverGrid
        var px: [SIMD3<Double>] = []
        for y in 0..<n {
            for x in 0..<n {
                let fy = Double(y) / Double(n - 1), fx = Double(x) / Double(n - 1)
                var c = SIMD3<Double>(0.98, 0.35, 0.55) * (1 - fy) + SIMD3<Double>(0.25, 0.2, 0.75) * fy
                let dx = fx - 0.5, dy = fy - 0.42
                if dx * dx + dy * dy < 0.045 { c = [1.0, 0.82, 0.35] }
                if fy > 0.72, (x + y) % 3 == 0 { c *= 0.7 }
                px.append(c)
            }
        }
        coverPixels = px
        barColors = Self.columnColors(px, n: n)
    }
}
