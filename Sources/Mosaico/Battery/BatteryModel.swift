import AppKit
import IOKit
import IOKit.ps
import Observation

struct MacBattery: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var charged: Bool
    /// Minutos hasta vaciarse (con batería) o hasta llenarse (cargando). nil = calculando.
    var minutes: Int?
    var cycles: Int?
    var health: Int?
}

struct DeviceBattery: Equatable, Identifiable {
    struct Level: Equatable {
        var label: String   // "I", "D", "Estuche" o "" si hay una sola batería
        var percent: Int
    }
    var id: String { name }
    var name: String
    var kind: String        // device_minorType de system_profiler
    var levels: [Level]

    var symbol: String {
        let k = kind.lowercased()
        let n = name.lowercased()
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods") { return "airpods" }
        if k.contains("keyboard") { return "keyboard" }
        if k.contains("mouse") { return "magicmouse" }
        if k.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if k.contains("gamepad") { return "gamecontroller.fill" }
        if k.contains("speaker") { return "hifispeaker.fill" }
        if k.contains("head") { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}

/// Baterías de la Mac (IOKit, con avisos del sistema) y de los dispositivos Bluetooth
/// conectados (`system_profiler`, cada 30 s y solo si el widget se ve).
@Observable
final class BatteryModel: @unchecked Sendable {
    private(set) var mac: MacBattery?
    private(set) var devices: [DeviceBattery] = []

    @ObservationIgnored var isVisible = true {
        didSet { if isVisible && !oldValue { refreshDevices() } }
    }
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "mosaico.battery", qos: .utility)
    @ObservationIgnored private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        if demo { loadDemo() }
    }

    func start() {
        guard !demo, runLoopSource == nil else { return }
        refreshMac()
        refreshDevices()
        // El sistema avisa cuando cambia la batería de la Mac: no hace falta preguntar.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryModel>.fromOpaque(ctx).takeUnretainedValue().refreshMac()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.refreshDevices()
            self.refreshMac()   // actualiza el tiempo restante estimado
        }
        t.tolerance = 5
        timer = t
    }

    // MARK: - Mac

    func refreshMac() {
        guard !demo else { return }
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        var found: MacBattery?
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charged = d[kIOPSIsChargedKey] as? Bool ?? false
            let minutesKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (d[minutesKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            let (cycles, health) = Self.smartBattery()
            found = MacBattery(percent: Int((Double(current) / Double(Swift.max(max, 1)) * 100).rounded()),
                               charging: charging, pluggedIn: plugged, charged: charged,
                               minutes: minutes, cycles: cycles, health: health)
        }
        if found != mac { mac = found }
    }

    /// Ciclos y salud (capacidad máxima actual / de diseño) desde AppleSmartBattery.
    private static func smartBattery() -> (Int?, Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return (nil, nil) }
        let data = dict["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (dict[key] as? Int) ?? (data[key] as? Int) }
        let cycles = int("CycleCount")
        var health: Int?
        if let design = int("DesignCapacity"), design > 0,
           let maxCap = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") {
            health = min(100, Int((Double(maxCap) / Double(design) * 100).rounded()))
        }
        return (cycles, health)
    }

    // MARK: - Bluetooth

    func refreshDevices() {
        guard !demo else { return }
        queue.async {
            let found = Self.readBluetooth()
            DispatchQueue.main.async {
                if found != self.devices { self.devices = found }
            }
        }
    }

    private static func readBluetooth() -> [DeviceBattery] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controller = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = controller["device_connected"] as? [[String: Any]] else { return [] }

        func percent(_ v: Any?) -> Int? {
            guard let s = v as? String else { return nil }
            return Int(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        }
        var result: [DeviceBattery] = []
        for entry in connected {
            for (name, value) in entry {
                guard let info = value as? [String: Any] else { continue }
                var levels: [DeviceBattery.Level] = []
                if let l = percent(info["device_batteryLevelLeft"]) { levels.append(.init(label: "I", percent: l)) }
                if let r = percent(info["device_batteryLevelRight"]) { levels.append(.init(label: "D", percent: r)) }
                if let c = percent(info["device_batteryLevelCase"]) { levels.append(.init(label: "Estuche", percent: c)) }
                if let m = percent(info["device_batteryLevelMain"]) ?? percent(info["device_batteryLevel"]) {
                    levels.append(.init(label: "", percent: m))
                }
                guard !levels.isEmpty else { continue }
                result.append(DeviceBattery(name: name.trimmingCharacters(in: .whitespaces),
                                            kind: info["device_minorType"] as? String ?? "", levels: levels))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    // MARK: - Textos

    static func color(for percent: Int, charging: Bool = false) -> SIMD3<Double> {
        if charging || percent > 50 { return [0.26, 0.86, 0.42] }
        if percent > 20 { return [1.00, 0.80, 0.22] }
        return [1.00, 0.27, 0.32]
    }

    func macStatus(_ m: MacBattery) -> String {
        if m.charged || (m.pluggedIn && !m.charging && m.percent >= 99) { return "Cargada" }
        if m.charging {
            guard let min = m.minutes else { return "Cargando…" }
            return "Cargando · llena en \(Self.duration(min))"
        }
        if m.pluggedIn { return "Conectada, sin cargar" }
        guard let min = m.minutes else { return "Calculando tiempo…" }
        return "\(Self.duration(min)) restantes"
    }

    func macDetail(_ m: MacBattery) -> String {
        var parts: [String] = []
        if let h = m.health { parts.append("Salud \(h) %") }
        if let c = m.cycles { parts.append("\(c) ciclos") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    // MARK: - Demo

    private func loadDemo() {
        mac = MacBattery(percent: 86, charging: false, pluggedIn: false, charged: false,
                         minutes: 347, cycles: 181, health: 96)
        devices = [
            DeviceBattery(name: "AirPods Pro", kind: "Headphones",
                          levels: [.init(label: "I", percent: 84), .init(label: "D", percent: 83),
                                   .init(label: "Estuche", percent: 100)]),
            DeviceBattery(name: "DualSense Wireless Controller", kind: "Gamepad",
                          levels: [.init(label: "", percent: 18)]),
        ]
    }
}
