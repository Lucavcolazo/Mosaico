import AppKit
import Observation

/// Ojos de LuckyPy en vivo. La Pi es el único cerebro: acá solo se escucha su stream
/// (`/stream`, Server-Sent Events) y se dibujan los mismos píxeles que ven las OLED.
///
/// Eventos del stream:
/// - `f`: `{"o": [ojo0, ojo1], "b": brillo}`; cada ojo es base64 de 1024 bytes
///   (128×64 a 1 bit, 16 bytes por fila, el bit más alto es el píxel de la izquierda).
/// - `e`: estado (no se usa: el widget solo muestra los ojos).
@Observable
final class MascotaModel: @unchecked Sendable {
    enum Link: Equatable { case notConfigured, connecting, live, offline }

    static let hostsKey = "Mosaico.mascota.hosts"
    /// Se publica al tocar los ojos sin dirección configurada: la app abre la configuración.
    static let needsSetupNotification = Notification.Name("MosaicoMascotaNeedsSetup")

    static let eyeWidth = 128
    static let eyeHeight = 64

    private(set) var link: Link = .connecting
    private(set) var host = ""

    /// La vista nativa que recibe los cuadros (sin pasar por SwiftUI, que es caro a 5 fps).
    @ObservationIgnored weak var sink: EyesView? {
        didSet { if let sink, !lastEyes.isEmpty { sink.show(lastEyes, glow: lastGlow) } }
    }
    /// Cuando el widget está tapado no se decodifica nada.
    @ObservationIgnored var isVisible = true
    @ObservationIgnored private(set) var lastEyes: [CGImage] = []
    @ObservationIgnored private var lastGlow = CGColor(red: 0.91, green: 0.95, blue: 1, alpha: 1)
    @ObservationIgnored private var reader: SSEReader?
    /// Último cuadro crudo: si llega uno idéntico (ojos quietos) no se procesa.
    @ObservationIgnored private var lastPayload = Data()
    @ObservationIgnored private var hostIndex = 0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private let demo: Bool
    @ObservationIgnored private let session: URLSession = URLSession(configuration: .ephemeral)

    /// Direcciones del robot ("host:puerto"), en orden de preferencia: por ejemplo la IP de
    /// Tailscale (anda desde cualquier lado) y la IP local como respaldo. Se configuran desde
    /// el menú de Mosaico y quedan guardadas solo en esta Mac (no en el código).
    static var hosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: hostsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: hostsKey) }
    }

    /// Acepta "100.x.y.z:8765, 192.168.1.10" (separado por comas o espacios; puerto 8765 por defecto).
    static func parseHosts(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .map { $0.replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
            .map { $0.contains(":") ? $0 : $0 + ":8765" }
    }

    init(demo: Bool = false) {
        self.demo = demo
    }

    // MARK: - Conexión

    func start() {
        guard !demo, reader == nil else { return }
        connect()
    }

    /// Vuelve a conectar desde cero (después de cambiar las direcciones).
    func reconfigure() {
        reader?.cancel()
        reader = nil
        failures = 0
        hostIndex = 0
        lastEyes = []
        sink?.show([], glow: lastGlow)
        connect()
    }

    private func connect() {
        let list = Self.hosts
        guard !list.isEmpty else {
            host = ""
            link = .notConfigured
            return
        }
        let host = list[hostIndex % max(1, list.count)]
        self.host = host
        if failures == 0 { link = .connecting }
        guard let url = URL(string: "http://\(host)/stream") else { return }
        lastPayload = Data()
        reader = SSEReader(url: url, onEvent: { [weak self] event, payload in
            self?.handle(event: event, payload: payload)
        }, onEnd: { [weak self] error in
            if let error { print("Mascota: sin conexión con \(host): \(error.localizedDescription)") }
            DispatchQueue.main.async { self?.disconnected() }
        })
    }

    private func disconnected() {
        reader = nil
        failures += 1
        link = .offline
        hostIndex += 1                      // prueba la otra dirección
        let delay = min(30, pow(2, Double(min(failures, 5))))   // 2, 4, 8, 16, 30 s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.reader == nil else { return }
            self.connect()
        }
    }

    /// Reintenta ya (por ejemplo, al tocar el widget sin conexión).
    func reconnectNow() {
        guard reader == nil else { return }
        connect()
    }

    // MARK: - Eventos

    private struct Frame: Decodable {
        let o: [String]
        let b: Double?
    }

    /// Se llama desde la cola del lector (no la principal).
    private func handle(event: String, payload: Data) {
        markLive()
        guard event == "f", isVisible, payload != lastPayload else { return }
        lastPayload = payload
        guard let (eyes, glow) = Self.decode(frame: payload) else { return }
        DispatchQueue.main.async {
            self.lastEyes = eyes
            self.lastGlow = glow
            self.sink?.show(eyes, glow: glow)
        }
    }

    private func markLive() {
        guard link != .live || failures != 0 else { return }
        DispatchQueue.main.async {
            self.failures = 0
            if self.link != .live { self.link = .live }
        }
    }

    // MARK: - Tocar

    func touch() {
        if link == .notConfigured {
            NotificationCenter.default.post(name: Self.needsSetupNotification, object: nil)
            return
        }
        guard link == .live, let url = URL(string: "http://\(host)/evento") else {
            reconnectNow()
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"type":"touch"}"#.utf8)
        session.dataTask(with: request).resume()
    }

    // MARK: - Imagen

    static func decode(frame payload: Data) -> ([CGImage], CGColor)? {
        guard let frame = try? JSONDecoder().decode(Frame.self, from: payload) else { return nil }
        let b = max(0, min(1, frame.b ?? 1))
        // Mismo color que el panel web: de casi negro a #E8F1FF según el brillo.
        let rgb = (UInt8(5 + (232 - 5) * b), UInt8(6 + (241 - 6) * b), UInt8(8 + (255 - 8) * b))
        let eyes = frame.o.compactMap { Data(base64Encoded: $0) }.compactMap { image(bits: $0, rgb: rgb) }
        guard eyes.count == 2 else { return nil }
        let glow = CGColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        return (eyes, glow)
    }

    /// 1024 bytes (1 bit por píxel) → imagen 128×64; los píxeles apagados quedan transparentes
    /// para que el brillo (sombra) siga la forma del ojo.
    static func image(bits: Data, rgb: (UInt8, UInt8, UInt8)) -> CGImage? {
        guard bits.count >= eyeWidth * eyeHeight / 8 else { return nil }
        var buffer = [UInt8](repeating: 0, count: eyeWidth * eyeHeight * 4)
        bits.withUnsafeBytes { raw in
            for p in 0..<(eyeWidth * eyeHeight) where raw[p >> 3] & (0x80 >> UInt8(p & 7)) != 0 {
                let j = p * 4
                buffer[j] = rgb.0
                buffer[j + 1] = rgb.1
                buffer[j + 2] = rgb.2
                buffer[j + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(
            width: eyeWidth, height: eyeHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: eyeWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Ojos cerrados (una línea) para cuando no hay conexión.
    static func closedEye() -> CGImage? {
        var bits = Data(count: eyeWidth * eyeHeight / 8)
        let row = 34
        for x in 24..<104 {
            for dy in 0..<3 {
                let p = (row + dy) * eyeWidth + x
                bits[p >> 3] |= 0x80 >> UInt8(p & 7)
            }
        }
        return image(bits: bits, rgb: (70, 72, 80))
    }

    // MARK: - Demo (capturas)

    /// Carga un cuadro guardado (línea `data: {...}` de un evento `f`).
    func loadDemo(frameJSON: Data) {
        link = .live
        host = Self.hosts.first ?? ""
        if let (eyes, glow) = Self.decode(frame: frameJSON) {
            lastEyes = eyes
            lastGlow = glow
        }
    }
}

/// Lector de Server-Sent Events que recibe bloques de datos y los parte en líneas
/// (mucho más barato que recorrer el stream byte por byte con `AsyncBytes.lines`).
final class SSEReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onEvent: (String, Data) -> Void
    private let onEnd: (Error?) -> Void
    private var buffer = Data()
    private var event = ""
    private var session: URLSession!
    private var finished = false

    init(url: URL, onEvent: @escaping (String, Data) -> Void, onEnd: @escaping (Error?) -> Void) {
        self.onEvent = onEvent
        self.onEnd = onEnd
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20      // sin datos en 20 s → se corta y se reconecta
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
    }

    func cancel() {
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            var line = buffer[start..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if line.starts(with: Self.eventPrefix) {
                event = String(decoding: line.dropFirst(6), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            } else if line.starts(with: Self.dataPrefix) {
                onEvent(event, Data(line.dropFirst(5)))
            }
            start = buffer.index(after: newline)
        }
        buffer.removeSubrange(buffer.startIndex..<start)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        session.finishTasksAndInvalidate()
        onEnd(error)
    }

    private static let eventPrefix = Array("event:".utf8)
    private static let dataPrefix = Array("data:".utf8)
}
