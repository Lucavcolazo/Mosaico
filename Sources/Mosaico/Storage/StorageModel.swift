import AppKit
import Observation

enum StoragePhase: Equatable {
    case idle
    case scanning(path: String)
    case clearing(StorageCategory, path: String)
}

enum StorageSuggestion: Equatable {
    case scanning
    case clear(StorageCategory)
    case needsAccess
    case allGood
}

struct TopItem: Equatable {
    var name: String
    var bytes: Double
}

struct FreedBanner: Equatable {
    var freed: Double
    var id = UUID()
}

/// Estado del widget de almacenamiento. Se modifica siempre desde el hilo principal.
@Observable
final class StorageModel: BarSource {
    let demo: Bool
    let animator = BarAnimator()

    private(set) var bytes: [StorageCategory: Double] = [:]
    private(set) var largest: [StorageCategory: TopItem] = [:]
    private(set) var unreadable: Set<StorageCategory> = []
    private(set) var phase: StoragePhase = .idle
    private(set) var totalCapacity: Double = 512_000_000_000
    private(set) var scannedOnce = false
    private(set) var freedBanner: FreedBanner?
    private(set) var confirming: StorageCategory?
    var hovered: StorageCategory? {
        didSet { if hovered != oldValue { animator.kick() } }
    }

    @ObservationIgnored private var token = CancelToken()
    @ObservationIgnored private var children: [StorageCategory: [String: Int64]] = [:]
    @ObservationIgnored private var clearedThisSession: Set<StorageCategory> = []
    @ObservationIgnored private var volumeAvailable: Double = 0

    init(demo: Bool) {
        self.demo = demo
        animator.source = self
    }

    // MARK: - Derivados

    var used: Double { StorageCategory.allCases.reduce(0) { $0 + (bytes[$1] ?? 0) } }
    var available: Double { max(0, totalCapacity - used) }
    var isBusy: Bool { phase != .idle }

    var suggestion: StorageSuggestion {
        switch phase {
        case .scanning: return .scanning
        case .clearing(let c, _): return .clear(c)
        case .idle: break
        }
        guard scannedOnce else { return .scanning }
        if (bytes[.caches] ?? 0) > 500_000_000, !clearedThisSession.contains(.caches) { return .clear(.caches) }
        if (bytes[.trash] ?? 0) > 100_000_000, !clearedThisSession.contains(.trash) { return .clear(.trash) }
        if unreadable.contains(.trash) { return .needsAccess }
        return .allGood
    }

    func insight(for c: StorageCategory) -> String {
        if unreadable.contains(c) { return "Sin permiso para leer esta carpeta." }
        if !c.blurb.isEmpty { return c.blurb }
        if let top = largest[c], top.bytes > 50_000_000 {
            let name = top.name.hasSuffix(".app") ? String(top.name.dropLast(4)) : top.name
            return "\(name) ocupa \(ByteFormat.gb(top.bytes))."
        }
        return ""
    }

    // MARK: - BarSource

    var barItems: [BarItem] { StorageCategory.allCases.map { $0.barItem(bytes: bytes[$0] ?? 0) } }
    var barCapacity: Double { totalCapacity }
    var hoveredID: String? {
        get { hovered?.rawValue }
        set { hovered = newValue.flatMap(StorageCategory.init(rawValue:)) }
    }
    var isScanning: Bool { if case .scanning = phase { return true }; return false }
    var clearingID: String? { if case .clearing(let c, _) = phase { return c.rawValue }; return nil }
    var canHover: Bool { phase == .idle && scannedOnce }

    // MARK: - Escaneo

    func rescan() {
        guard !isBusy else { return }
        token.isCancelled = true
        let token = CancelToken()
        self.token = token
        freedBanner = nil
        confirming = nil
        hovered = nil
        clearedThisSession = []
        for c in StorageCategory.allCases { bytes[c] = 0 }
        largest = [:]
        unreadable = []
        children = [:]
        readVolume()
        phase = .scanning(path: "")
        animator.kick()

        if demo { runDemoScan(token: token); return }

        let order = StorageCategory.allCases.filter { $0 != .system }
        DispatchQueue.global(qos: .utility).async {
            for cat in order {
                let r = FolderScanner.scan(roots: cat.roots, token: token) { b, path, _ in
                    DispatchQueue.main.async {
                        guard !token.isCancelled else { return }
                        self.bytes[cat] = Double(b)
                        self.phase = .scanning(path: path)
                        self.animator.kick()
                    }
                }
                if token.isCancelled { return }
                DispatchQueue.main.async { self.apply(r, to: cat) }
            }
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                self.finishScan()
            }
        }
    }

    private func apply(_ r: FolderScanResult, to cat: StorageCategory) {
        bytes[cat] = Double(r.bytes)
        children[cat] = r.children
        if !r.readable { unreadable.insert(cat) } else { unreadable.remove(cat) }
        if let top = r.children.max(by: { $0.value < $1.value }) {
            largest[cat] = TopItem(name: top.key, bytes: Double(top.value))
        } else {
            largest[cat] = nil
        }
    }

    private func finishScan() {
        readVolume()
        let others = StorageCategory.allCases.filter { $0 != .system }.reduce(0) { $0 + (bytes[$1] ?? 0) }
        bytes[.system] = max(0, (totalCapacity - volumeAvailable) - others)
        phase = .idle
        scannedOnce = true
        animator.kick()
    }

    private func readVolume() {
        guard !demo else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        if let v = try? url.resourceValues(forKeys: keys) {
            if let t = v.volumeTotalCapacity { totalCapacity = Double(t) }
            if let a = v.volumeAvailableCapacityForImportantUsage { volumeAvailable = Double(a) }
        }
    }

    // MARK: - Limpieza

    /// Primer clic pide confirmación, el segundo (dentro de 3 s) limpia.
    func requestClear(_ cat: StorageCategory) {
        guard !isBusy else { return }
        if confirming == cat {
            confirming = nil
            clear(cat)
        } else {
            confirming = cat
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.confirming == cat { self.confirming = nil }
            }
        }
    }

    private func clear(_ cat: StorageCategory) {
        guard cat == .caches || cat == .trash, let root = cat.roots.first else { return }
        let before = used
        hovered = nil
        phase = .clearing(cat, path: root.path)
        animator.kick()

        if demo { runDemoClear(cat, before: before); return }

        let sizes = children[cat] ?? [:]
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            // Que la animación dure al menos ~1,5 s aunque borrar sea instantáneo.
            let pause = min(0.15, 1.5 / Double(max(items.count, 1)))
            for item in items {
                let size = Double(sizes[item.lastPathComponent] ?? 0)
                DispatchQueue.main.async { self.phase = .clearing(cat, path: item.path) }
                try? fm.removeItem(at: item)
                DispatchQueue.main.async {
                    self.bytes[cat] = max(0, (self.bytes[cat] ?? 0) - size)
                    self.animator.kick()
                }
                Thread.sleep(forTimeInterval: pause)
            }
            // Medir de nuevo: lo que no se pudo borrar vuelve a aparecer.
            let r = FolderScanner.scan(roots: [root], token: CancelToken()) { _, _, _ in }
            DispatchQueue.main.async {
                self.apply(r, to: cat)
                self.finishClear(cat, before: before)
            }
        }
    }

    private func finishClear(_ cat: StorageCategory, before: Double) {
        clearedThisSession.insert(cat)
        phase = .idle
        animator.kick()
        let banner = FreedBanner(freed: max(0, before - used))
        freedBanner = banner
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if self.freedBanner?.id == banner.id { self.freedBanner = nil }
        }
    }

    // MARK: - Modo demo (datos inventados, no toca el disco)

    static let demoBytes: [StorageCategory: Double] = [
        .apps: 52.6e9, .developer: 36.3e9, .photos: 58.6e9, .movies: 44.1e9, .documents: 41.7e9,
        .music: 12.1e9, .system: 34.2e9, .caches: 46.8e9, .trash: 31.4e9,
    ]
    static let demoTop: [StorageCategory: TopItem] = [
        .apps: TopItem(name: "Xcode.app", bytes: 12.4e9),
        .developer: TopItem(name: "CoreSimulator", bytes: 17.2e9),
        .photos: TopItem(name: "Photos Library.photoslibrary", bytes: 55.1e9),
        .movies: TopItem(name: "Grabaciones de pantalla", bytes: 24.6e9),
        .documents: TopItem(name: "Lookbook final.psd", bytes: 3.8e9),
        .music: TopItem(name: "Music", bytes: 11.9e9),
    ]
    static let demoPaths: [StorageCategory: [String]] = [
        .apps: ["/Applications/Utilities", "/Applications/Xcode.app/Contents", "/Applications/Final Cut Pro.app"],
        .developer: ["~/Library/Developer/CoreSimulator/Devices", "~/Library/Developer/Xcode/DerivedData", "~/.npm/_cacache"],
        .photos: ["~/Pictures/Photos Library.photoslibrary", "~/Pictures/Exportadas"],
        .movies: ["~/Movies/Exports", "~/Movies/Grabaciones de pantalla"],
        .documents: ["~/Documents/Impuestos", "~/Desktop/Proyectos", "~/Downloads"],
        .music: ["~/Music/Music/Media.localized"],
        .system: ["/Library/Logs", "/private/var/vm"],
        .caches: ["~/Library/Caches/com.spotify.client", "~/Library/Caches/Google", "~/Library/Caches/Homebrew"],
        .trash: ["~/.Trash/Grabación 2026-08-14.mov", "~/.Trash/Exports viejos"],
    ]

    /// Para capturas: todo ya escaneado.
    func fillDemoInstantly() {
        bytes = Self.demoBytes
        largest = Self.demoTop
        scannedOnce = true
        phase = .idle
        animator.snap()
    }

    private func runDemoScan(token: CancelToken) {
        let order = StorageCategory.allCases
        let state = Box((index: 0, progress: 0.0))
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { timer in
            guard !token.isCancelled, state.value.index < order.count else {
                timer.invalidate()
                if !token.isCancelled {
                    self.largest = Self.demoTop
                    self.phase = .idle
                    self.scannedOnce = true
                    self.animator.kick()
                }
                return
            }
            let cat = order[state.value.index]
            let progress = min(1, state.value.progress + 1.0 / 22)
            state.value.progress = progress
            let eased = 1 - pow(1 - progress, 2)
            self.bytes[cat] = (Self.demoBytes[cat] ?? 0) * eased
            let paths = Self.demoPaths[cat] ?? [""]
            self.phase = .scanning(path: paths[min(paths.count - 1, Int(progress * Double(paths.count)))])
            self.animator.kick()
            if progress >= 1 { state.value = (state.value.index + 1, 0) }
        }
    }

    private func runDemoClear(_ cat: StorageCategory, before: Double) {
        let start = bytes[cat] ?? 0
        let target = cat == .caches ? 1.2e9 : 0
        let t = Box(0.0)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { timer in
            t.value = min(1, t.value + 1.0 / 60)
            self.bytes[cat] = start + (target - start) * t.value
            let paths = Self.demoPaths[cat] ?? [""]
            self.phase = .clearing(cat, path: paths[min(paths.count - 1, Int(t.value * Double(paths.count)))])
            self.animator.kick()
            if t.value >= 1 {
                timer.invalidate()
                self.finishClear(cat, before: before)
            }
        }
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

extension StorageModel {
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
