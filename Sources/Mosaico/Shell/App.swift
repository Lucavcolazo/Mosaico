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
                hovered: value(after: "--hover"),
                scale: value(after: "--scale").flatMap(Double.init).map { CGFloat($0) } ?? 1,
                disk: args.contains("--disk")
            )
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(demo: args.contains("--demo"))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let storage: StorageModel
    private var storagePanel: WidgetPanel?
    private var contexts: [WidgetContext] = []
    private var disks: [URL: (model: ExternalDiskModel, panel: WidgetPanel)] = [:]
    private let volumes = VolumeWatcher()
    private var statusItem: NSStatusItem?
    private let onTopKey = "Mosaico.onTop"

    init(demo: Bool) {
        storage = StorageModel(demo: demo)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let ctx = WidgetContext(id: "storage")
        contexts.append(ctx)
        let panel = WidgetPanel(context: ctx, content: StorageCard(model: storage, ctx: ctx)) { size in
            guard let vf = NSScreen.main?.visibleFrame else { return .zero }
            return NSPoint(x: vf.maxX - size.width - 28, y: vf.maxY - size.height - 28)
        }
        storagePanel = panel
        panel.applyLevel(onTop: onTop)
        panel.orderFrontRegardless()
        setupStatusItem()
        storage.rescan()

        volumes.onAdd = { [weak self] url in self?.addDisk(url) }
        volumes.onRemove = { [weak self] url in self?.removeDisk(url) }
        volumes.onWillRemove = { [weak self] url in self?.disks[url]?.model.cancel() }
        volumes.start()
    }

    // MARK: - Discos externos

    private func addDisk(_ url: URL) {
        guard disks[url] == nil else { return }
        let model = ExternalDiskModel(volumeURL: url)
        let uuid = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? model.name
        let ctx = WidgetContext(id: "disk.\(uuid)")
        contexts.append(ctx)
        let panel = WidgetPanel(context: ctx, content: ExternalDiskCard(model: model, ctx: ctx)) { [weak self] size in
            // La primera vez aparece debajo del widget más bajo.
            let panels = [self?.storagePanel].compactMap { $0 } + (self?.disks.values.map(\.panel) ?? [])
            if let lowest = panels.min(by: { $0.frame.minY < $1.frame.minY }) {
                return NSPoint(x: lowest.frame.minX, y: lowest.frame.minY - 16 - size.height)
            }
            guard let vf = NSScreen.main?.visibleFrame else { return .zero }
            return NSPoint(x: vf.maxX - size.width - 28, y: vf.maxY - size.height - 28)
        }
        panel.applyLevel(onTop: onTop)
        panel.orderFrontRegardless()
        disks[url] = (model, panel)
        model.rescan()
    }

    private func removeDisk(_ url: URL) {
        guard let entry = disks.removeValue(forKey: url) else { return }
        entry.model.cancel()
        entry.panel.orderOut(nil)
        contexts.removeAll { $0 === entry.panel.context }
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
        let title = NSMenuItem(title: storage.demo ? "Mosaico (demo)" : "Mosaico", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        menu.addItem(item("Volver a escanear", #selector(rescan), "r"))

        let sizeItem = NSMenuItem(title: "Tamaño", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (name, value) in [("Pequeño", 0.75), ("Mediano", 1.0), ("Grande", 1.25)] {
            let i = item(name, #selector(setSize(_:)), "")
            i.representedObject = value
            sizeMenu.addItem(i)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

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

    @objc private func rescan() {
        storage.rescan()
        for d in disks.values { d.model.rescan() }
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        for c in contexts { c.scale = CGFloat(v) }
    }

    @objc private func toggleOnTop(_ sender: NSMenuItem) {
        let v = !onTop
        UserDefaults.standard.set(v, forKey: onTopKey)
        sender.state = v ? .on : .off
        storagePanel?.applyLevel(onTop: v)
        for d in disks.values { d.panel.applyLevel(onTop: v) }
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

/// `Mosaico --snapshot salida.png [--hover id] [--scale 0.8] [--disk]` dibuja un widget con datos demo.
@MainActor
enum Snapshot {
    static func render(to path: String, hovered: String?, scale: CGFloat, disk: Bool) {
        let ctx = WidgetContext(id: "snapshot")
        ctx.scale = scale
        let card: AnyView
        if disk {
            let model = ExternalDiskModel.demo()
            model.hoveredID = hovered.map { $0.hasPrefix("_") ? $0 : "f:" + $0 }
            model.animator.snap()
            card = AnyView(ExternalDiskCard(model: model, ctx: ctx))
        } else {
            let model = StorageModel(demo: true)
            model.fillDemoInstantly()
            model.hoveredID = hovered
            model.animator.snap()
            card = AnyView(StorageCard(model: model, ctx: ctx))
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
