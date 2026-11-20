import AppKit
import ServiceManagement
import SwiftUI

@main
enum MosaicoApp {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let out = value(after: "--snapshot") {
            Snapshot.render(
                to: out,
                kind: value(after: "--widget") ?? "storage",
                hovered: value(after: "--hover"),
                scale: value(after: "--scale").flatMap(Double.init).map { CGFloat($0) } ?? 1
            )
            return
        }
        if args.contains("--mascota-test") {
            // Prueba la conexión con LuckyPy durante 8 s e imprime lo que llega.
            let model = MascotaModel()
            model.start()
            let end = Date().addingTimeInterval(8)
            var last = ""
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let line = "\(model.host)  estado: \(model.link)  ojos: \(model.lastEyes.count)"
                if line != last { print(line); last = line }
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(demo: args.contains("--demo"))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Los widgets disponibles. Para sumar uno nuevo: agregarlo acá y en `makePanel`.
enum WidgetKind: String, CaseIterable {
    case storage, calendar, clock, nowPlaying, weather, mascota

    var title: String {
        switch self {
        case .storage: "Almacenamiento"
        case .calendar: "Calendario"
        case .clock: "Reloj"
        case .nowPlaying: "Música (Spotify)"
        case .weather: "Clima"
        case .mascota: "Mascota (LuckyPy)"
        }
    }

    var symbol: String {
        switch self {
        case .storage: "internaldrive"
        case .calendar: "calendar"
        case .clock: "clock"
        case .nowPlaying: "music.note"
        case .weather: "cloud.sun"
        case .mascota: "eyes"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demo: Bool
    private let storage: StorageModel
    private let hub: StorageHub
    private var calendarModel: CalendarModel?
    private var nowPlayingModel: NowPlayingModel?
    private var weatherModel: WeatherModel?
    private var mascotaModel: MascotaModel?
    private var panels: [WidgetKind: WidgetPanel] = [:]
    private let volumes = VolumeWatcher()
    private var statusItem: NSStatusItem?
    private var widgetItems: [WidgetKind: NSMenuItem] = [:]
    private let onTopKey = "Mosaico.onTop"
    private let enabledKey = "Mosaico.enabledWidgets"

    init(demo: Bool) {
        self.demo = demo
        storage = StorageModel(demo: demo)
        hub = StorageHub(internalModel: storage)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        let initial = enabled
        enabled = initial   // guarda la lista de widgets conocidos
        for kind in WidgetKind.allCases where initial.contains(kind.rawValue) { show(kind) }

        volumes.onAdd = { [weak self] url in self?.hub.addDisk(url) }
        volumes.onRemove = { [weak self] url in self?.hub.removeDisk(url) }
        volumes.onWillRemove = { [weak self] url in self?.hub.willRemoveDisk(url) }
        volumes.start()

        NotificationCenter.default.addObserver(
            forName: MascotaModel.needsSetupNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureMascota() }
        }
    }

    // MARK: - Widgets

    private var enabled: Set<String> {
        get {
            let all = Set(WidgetKind.allCases.map(\.rawValue))
            guard let list = UserDefaults.standard.stringArray(forKey: enabledKey) else { return all }
            // La versión anterior conocía estos tres; los que se sumen después arrancan activados.
            let known = Set(UserDefaults.standard.stringArray(forKey: "Mosaico.knownWidgets")
                            ?? ["storage", "calendar", "clock"])
            return Set(list).union(all.subtracting(known))
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: enabledKey)
            UserDefaults.standard.set(WidgetKind.allCases.map(\.rawValue), forKey: "Mosaico.knownWidgets")
        }
    }

    private func isEnabled(_ kind: WidgetKind) -> Bool { enabled.contains(kind.rawValue) }

    private func show(_ kind: WidgetKind) {
        let panel = panels[kind] ?? makePanel(kind)
        panels[kind] = panel
        panel.applyLevel(onTop: onTop)
        panel.orderFrontRegardless()
    }

    private func hide(_ kind: WidgetKind) {
        panels[kind]?.orderOut(nil)
    }

    private func makePanel(_ kind: WidgetKind) -> WidgetPanel {
        let ctx = WidgetContext(id: kind.rawValue)
        let placement: (NSSize) -> NSPoint = { [weak self] size in self?.defaultOrigin(for: size) ?? .zero }
        switch kind {
        case .storage:
            storage.rescan()
            return WidgetPanel(context: ctx, content: StorageHubView(hub: hub, ctx: ctx), placement: placement)
        case .calendar:
            let model = calendarModel ?? CalendarModel(demo: demo)
            calendarModel = model
            return WidgetPanel(context: ctx, content: CalendarCard(model: model, ctx: ctx), placement: placement)
        case .clock:
            return WidgetPanel(context: ctx, content: ClockCard(ctx: ctx), placement: placement)
        case .nowPlaying:
            let model = nowPlayingModel ?? NowPlayingModel(demo: demo)
            nowPlayingModel = model
            model.start()
            return WidgetPanel(context: ctx, content: NowPlayingCard(model: model, ctx: ctx), placement: placement)
        case .weather:
            let model = weatherModel ?? WeatherModel(demo: demo)
            weatherModel = model
            model.start()
            return WidgetPanel(context: ctx, content: WeatherCard(model: model, ctx: ctx), placement: placement)
        case .mascota:
            let model = mascotaModel ?? MascotaModel()
            mascotaModel = model
            model.start()
            return WidgetPanel(context: ctx, content: MascotaCard(model: model, ctx: ctx), placement: placement)
        }
    }

    /// Primera vez: a la derecha del widget visible más a la derecha (alineado arriba);
    /// si no entra, debajo del más bajo.
    private func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let vf = NSScreen.main?.visibleFrame else { return .zero }
        let visible = panels.values.filter(\.isVisible)
        guard let first = visible.first else {
            return NSPoint(x: vf.minX + 12, y: vf.maxY - size.height - 12)
        }
        let top = visible.map(\.frame.maxY).max() ?? first.frame.maxY
        let right = visible.map(\.frame.maxX).max() ?? first.frame.maxX
        if right + 16 + size.width <= vf.maxX {
            return NSPoint(x: right + 16, y: top - size.height)
        }
        let lowest = visible.min { $0.frame.minY < $1.frame.minY }!
        return NSPoint(x: lowest.frame.minX, y: max(vf.minY, lowest.frame.minY - 16 - size.height))
    }

    // MARK: - Menú en la barra

    private var onTop: Bool { UserDefaults.standard.bool(forKey: onTopKey) }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Mosaico")
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: demo ? "Mosaico (demo)" : "Mosaico", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let widgetsItem = NSMenuItem(title: "Widgets", action: nil, keyEquivalent: "")
        let widgetsMenu = NSMenu()
        for kind in WidgetKind.allCases {
            let i = item(kind.title, #selector(toggleWidget(_:)), "")
            i.representedObject = kind.rawValue
            i.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
            i.state = isEnabled(kind) ? .on : .off
            widgetItems[kind] = i
            widgetsMenu.addItem(i)
        }
        widgetsItem.submenu = widgetsMenu
        menu.addItem(widgetsItem)

        menu.addItem(item("Dirección de LuckyPy…", #selector(configureMascota), ""))
        menu.addItem(item("Volver a escanear discos", #selector(rescan), "r"))

        let sizeItem = NSMenuItem(title: "Tamaño de todos", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (name, value) in [("Pequeño", 0.75), ("Mediano", 1.0), ("Grande", 1.25)] {
            let i = item(name, #selector(setSize(_:)), "")
            i.representedObject = value
            sizeMenu.addItem(i)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let styleItem = NSMenuItem(title: "Estilo", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for style in Appearance.Style.allCases {
            let i = item(style.title, #selector(setStyle(_:)), "")
            i.representedObject = style.rawValue
            i.state = Appearance.shared.style == style ? .on : .off
            styleMenu.addItem(i)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let onTopItem = item("Mostrar encima de las ventanas", #selector(toggleOnTop), "")
        onTopItem.state = onTop ? .on : .off
        menu.addItem(onTopItem)

        let login = item("Abrir al iniciar sesión", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Salir", #selector(quit), "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = WidgetKind(rawValue: raw) else { return }
        var set = enabled
        if set.contains(raw) {
            set.remove(raw)
            hide(kind)
        } else {
            set.insert(raw)
            show(kind)
        }
        enabled = set
        sender.state = set.contains(raw) ? .on : .off
    }

    @objc private func rescan() { hub.rescanAll() }

    @objc private func configureMascota() {
        let alert = NSAlert()
        alert.messageText = "Dirección de LuckyPy"
        alert.informativeText = "Escribí una o más direcciones del robot (host:puerto), separadas por coma. "
            + "Se prueban en orden: por ejemplo la IP de Tailscale primero y la local como respaldo."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "100.x.y.z:8765, 192.168.1.10:8765"
        field.stringValue = MascotaModel.hosts.joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MascotaModel.hosts = MascotaModel.parseHosts(field.stringValue)
        mascotaModel?.reconfigure()
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        for p in panels.values { p.context.scale = CGFloat(v) }
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = Appearance.Style(rawValue: raw) else { return }
        Appearance.shared.style = style
        for i in sender.menu?.items ?? [] { i.state = (i.representedObject as? String) == raw ? .on : .off }
        for p in panels.values { p.invalidateShadow() }
    }

    @objc private func toggleOnTop(_ sender: NSMenuItem) {
        let v = !onTop
        UserDefaults.standard.set(v, forKey: onTopKey)
        sender.state = v ? .on : .off
        for p in panels.values { p.applyLevel(onTop: v) }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// `Mosaico --snapshot salida.png [--widget storage|disk|calendar|clock] [--hover id] [--scale 0.8]`
/// dibuja un widget con datos demo a un PNG.
@MainActor
enum Snapshot {
    static func render(to path: String, kind: String, hovered: String?, scale: CGFloat) {
        let ctx = WidgetContext(id: "snapshot")
        ctx.scale = scale
        // El vidrio necesita el fondo real de la pantalla; para capturas, sólido.
        Appearance.shared.style = .solid
        let card: AnyView
        switch kind {
        case "disk":
            let model = ExternalDiskModel.demo()
            model.hoveredID = hovered.map { $0.hasPrefix("_") ? $0 : "f:" + $0 }
            model.animator.snap()
            card = AnyView(ExternalDiskCard(model: model, ctx: ctx))
        case "calendar":
            let model = CalendarModel(demo: true)
            model.hoveredIndex = hovered.flatMap(Int.init)
            model.skipReveal()
            card = AnyView(CalendarCard(model: model, ctx: ctx))
        case "mascota":
            let model = MascotaModel(demo: true)
            if let path = ProcessInfo.processInfo.environment["MOSAICO_FRAME"],
               let data = FileManager.default.contents(atPath: path) {
                model.loadDemo(frameJSON: data)
            }
            card = AnyView(MascotaCard(model: model, ctx: ctx))
        case "weather":
            let model = WeatherModel(demo: true)
            model.hoveredHour = hovered.flatMap(Int.init)
            card = AnyView(WeatherCard(model: model, ctx: ctx))
        case "music":
            card = AnyView(NowPlayingCard(model: NowPlayingModel(demo: true), ctx: ctx))
        case "clock":
            var c = DateComponents()
            c.year = 2026; c.month = 11; c.day = 20; c.hour = 0; c.minute = 47; c.second = 32
            let date = Calendar.current.date(from: c)!.addingTimeInterval(0.15)
            card = AnyView(ClockCard(ctx: ctx, fixedDate: date))
        default:
            let model = StorageModel(demo: true)
            model.fillDemoInstantly()
            model.hoveredID = hovered
            model.animator.snap()
            let hub = StorageHub(internalModel: model)
            if hovered == nil { hub.attachForSnapshot(ExternalDiskModel.demo()) }
            card = AnyView(StorageHubView(hub: hub, ctx: ctx))
        }
        let renderer = ImageRenderer(content: card.padding(40).background(Color(white: 0.93)))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("No se pudo renderizar")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Guardado en \(path)")
    }
}
