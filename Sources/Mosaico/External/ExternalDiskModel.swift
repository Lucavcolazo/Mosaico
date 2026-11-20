import AppKit
import Observation

/// Un disco externo: la barra muestra sus carpetas de primer nivel más pesadas.
@Observable
final class ExternalDiskModel: BarSource {
    let volumeURL: URL
    let animator = BarAnimator()

    private(set) var name: String
    private(set) var format = ""
    private(set) var capacity: Double = 1
    private(set) var available: Double = 0
    private(set) var items: [BarItem] = []
    private(set) var scanning = false
    private(set) var scanPath = ""
    private(set) var scannedOnce = false
    private(set) var unreadable = false
    private(set) var ejecting = false
    private(set) var ejectError: String?
    var hoveredID: String? {
        didSet { if hoveredID != oldValue { animator.kick() } }
    }

    @ObservationIgnored private var token = CancelToken()

    static let maxFolders = 7
    static let otherID = "_otros"
    static let hiddenID = "_sistema"

    init(volumeURL: URL) {
        self.volumeURL = volumeURL
        name = volumeURL.lastPathComponent
        animator.source = self
        refreshVolume()
    }

    var used: Double { max(0, capacity - available) }

    // MARK: - BarSource

    var barItems: [BarItem] { items }
    var barCapacity: Double { capacity }
    var isScanning: Bool { scanning }
    var clearingID: String? { nil }
    var isBusy: Bool { scanning || ejecting }
    var canHover: Bool { !isBusy && scannedOnce }

    func detail(for item: BarItem) -> String {
        let pct = item.bytes / max(capacity, 1) * 100
        let pctText = pct.formatted(.number.precision(.fractionLength(pct < 10 ? 1 : 0))) + " % del disco"
        switch item.id {
        case Self.otherID: return "Carpetas más chicas y archivos ocultos · " + pctText
        case Self.hiddenID: return "Espacio del sistema de archivos o sin acceso · " + pctText
        default: return pctText
        }
    }

    // MARK: - Escaneo

    func refreshVolume() {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]
        guard let v = try? volumeURL.resourceValues(forKeys: keys) else { return }
        if let n = v.volumeName { name = n }
        format = v.volumeLocalizedFormatDescription ?? ""
        if let t = v.volumeTotalCapacity { capacity = Double(t) }
        if let a = v.volumeAvailableCapacity { available = Double(a) }
    }

    func rescan() {
        guard !isBusy else { return }
        token.isCancelled = true
        let token = CancelToken()
        self.token = token
        refreshVolume()
        items = []
        hoveredID = nil
        ejectError = nil
        scanning = true
        scanPath = volumeURL.path
        animator.kick()

        let root = volumeURL
        let used = self.used
        DispatchQueue.global(qos: .utility).async {
            var order: [String] = []
            var seen: Set<String> = []
            func track(_ children: [String: Int64]) {
                for key in children.keys where !seen.contains(key) {
                    seen.insert(key)
                    order.append(key)
                }
            }
            let r = FolderScanner.scan(roots: [root], token: token) { _, path, children in
                track(children)
                let live = Self.makeItems(root: root, children: children, order: order, used: used, final: false)
                DispatchQueue.main.async {
                    guard !token.isCancelled else { return }
                    self.items = live
                    self.scanPath = path
                    self.animator.kick()
                }
            }
            guard !token.isCancelled else { return }
            track(r.children)
            let final = Self.makeItems(root: root, children: r.children, order: order, used: used, final: true)
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                self.items = final
                self.unreadable = !r.readable
                self.scanning = false
                self.scannedOnce = true
                self.animator.kick()
            }
        }
    }

    /// Corta el escaneo (por ejemplo antes de expulsar, para no tener archivos abiertos).
    func cancel() {
        token.isCancelled = true
        if scanning {
            scanning = false
            animator.kick()
        }
    }

    static func makeItems(root: URL, children: [String: Int64], order: [String], used: Double, final: Bool) -> [BarItem] {
        let visible = order.filter { !$0.hasPrefix(".") && !$0.isEmpty && (children[$0] ?? 0) > 0 }
        let top: Set<String>
        if final {
            top = Set(visible.sorted { (children[$0] ?? 0) > (children[$1] ?? 0) }.prefix(maxFolders))
        } else {
            top = Set(visible.prefix(maxFolders))
        }

        var items: [BarItem] = []
        var other = 0.0
        var scanned = 0.0
        var colorIndex = 0
        let fm = FileManager.default
        for key in order {
            let size = Double(children[key] ?? 0)
            scanned += size
            if top.contains(key) {
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: root.appendingPathComponent(key).path, isDirectory: &isDir)
                items.append(BarItem(
                    id: "f:" + key,
                    name: key,
                    symbol: isDir.boolValue ? "folder.fill" : "doc.fill",
                    rgb: Palette.colors[colorIndex % Palette.colors.count],
                    bytes: size
                ))
                colorIndex += 1
            } else {
                other += size
            }
        }
        if other > 0 {
            items.append(BarItem(id: otherID, name: "Otros", symbol: "ellipsis.circle.fill", rgb: Palette.gray, bytes: other))
        }
        if final {
            let hidden = used - scanned
            if hidden > used * 0.01, hidden > 100_000_000 {
                items.append(BarItem(id: hiddenID, name: "Sistema", symbol: "gearshape.fill", rgb: Palette.darkGray, bytes: hidden))
            }
        }
        return items
    }

    // MARK: - Expulsar

    func eject() {
        guard !ejecting else { return }
        cancel()
        ejecting = true
        ejectError = nil
        hoveredID = nil
        let url = volumeURL
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                // Al desmontarse, el VolumeWatcher cierra la tarjeta.
            } catch {
                DispatchQueue.main.async {
                    self.ejecting = false
                    self.ejectError = "No se pudo expulsar: hay algo usando el disco."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.ejectError = nil }
                }
            }
        }
    }

    static func openFilesAndFoldersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Demo (para capturas)

    static func demo() -> ExternalDiskModel {
        let m = ExternalDiskModel(volumeURL: URL(fileURLWithPath: "/Volumes/Samsung T7"))
        m.name = "Samsung T7"
        m.format = "ExFAT"
        m.capacity = 1_000_000_000_000
        m.available = 391_600_000_000
        let demo: [(String, Double)] = [
            ("Fotos RAW", 182.4e9), ("Proyectos Final Cut", 141.2e9), ("Backups", 96.8e9),
            ("Música", 61.3e9), ("Películas", 48.9e9), ("Instaladores", 22.1e9), ("Docs.zip", 11.6e9),
        ]
        m.items = demo.enumerated().map { i, d in
            BarItem(id: "f:" + d.0, name: d.0, symbol: d.0.contains(".") ? "doc.fill" : "folder.fill",
                    rgb: Palette.colors[i], bytes: d.1)
        } + [
            BarItem(id: otherID, name: "Otros", symbol: "ellipsis.circle.fill", rgb: Palette.gray, bytes: 34.7e9),
            BarItem(id: hiddenID, name: "Sistema", symbol: "gearshape.fill", rgb: Palette.darkGray, bytes: 9.4e9),
        ]
        m.scannedOnce = true
        m.animator.snap()
        return m
    }
}
