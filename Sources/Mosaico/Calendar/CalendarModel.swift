import AppKit
import EventKit
import Observation

struct DayEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var rgb: SIMD3<Double>
}

struct CalendarDay: Equatable {
    var date: Date
    var day: Int
    var inMonth: Bool
    var isToday: Bool
    var isPast: Bool
    var isWeekend: Bool
    var events: [DayEvent]

    /// 0…1: qué tan ocupado está el día (define cuántos píxeles se encienden).
    var busyness: Double {
        var hours = 0.0
        for e in events {
            hours += e.allDay ? 2 : min(10, e.end.timeIntervalSince(e.start) / 3600)
        }
        return min(1, hours / 8 + Double(events.count) * 0.08)
    }
}

enum CalendarAccess { case unknown, granted, denied }

@Observable
final class CalendarModel {
    private(set) var month: Date              // primer día del mes que se muestra
    private(set) var days: [CalendarDay] = [] // 42 celdas (6 semanas)
    private(set) var access: CalendarAccess = .unknown
    private(set) var nextEvent: DayEvent?
    private(set) var revealStart = Date()
    private(set) var animating = false
    var hoveredIndex: Int? {
        didSet { if hoveredIndex != oldValue { pulse(0.25) } }
    }

    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored let locale = Locale(identifier: "es_AR")
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pulseUntil = Date.distantPast
    @ObservationIgnored private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "es_AR")
        cal.firstWeekday = 2 // lunes
        calendar = cal
        month = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        if demo {
            access = .granted
        } else {
            access = Self.currentAccess()
        }
        rebuild(animated: true)

        guard !demo else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in self?.rebuild(animated: false) })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild(animated: false) })
        // Para el "próximo evento" (en X min) alcanza con refrescar cada minuto.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateNextEvent()
        }
    }

    // MARK: - Navegación

    var monthTitle: String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "LLLL"
        return f.string(from: month).capitalized(with: locale)
    }

    var yearTitle: String { String(calendar.component(.year, from: month)) }

    var isCurrentMonth: Bool { calendar.isDate(month, equalTo: Date(), toGranularity: .month) }

    var weekdaySymbols: [String] {
        // L M M J V S D
        let symbols = calendar.veryShortStandaloneWeekdaySymbols // empieza en domingo
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7].uppercased() }
    }

    func shiftMonth(_ delta: Int) {
        guard let m = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        month = m
        hoveredIndex = nil
        rebuild(animated: true)
    }

    func goToToday() {
        guard !isCurrentMonth else { return }
        month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        hoveredIndex = nil
        rebuild(animated: true)
    }

    // MARK: - Permisos

    static func currentAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                self.access = granted ? .granted : .denied
                self.rebuild(animated: true)
            }
        }
    }

    static func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Datos

    func rebuild(animated: Bool) {
        let today = calendar.startOfDay(for: Date())
        let weekdayOfFirst = calendar.component(.weekday, from: month)
        let lead = (weekdayOfFirst - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -lead, to: month),
              let gridEnd = calendar.date(byAdding: .day, value: 42, to: gridStart) else { return }

        let events = fetchEvents(from: gridStart, to: gridEnd)

        var result: [CalendarDay] = []
        for i in 0..<42 {
            let date = calendar.date(byAdding: .day, value: i, to: gridStart)!
            let next = calendar.date(byAdding: .day, value: 1, to: date)!
            let weekday = calendar.component(.weekday, from: date)
            let dayEvents = events.filter { $0.start < next && $0.end > date }
            result.append(CalendarDay(
                date: date,
                day: calendar.component(.day, from: date),
                inMonth: calendar.isDate(date, equalTo: month, toGranularity: .month),
                isToday: date == today,
                isPast: date < today,
                isWeekend: weekday == 1 || weekday == 7,
                events: dayEvents
            ))
        }
        days = result
        updateNextEvent()
        if animated {
            revealStart = Date()
            pulse(1.4)
        }
    }

    private func fetchEvents(from start: Date, to end: Date) -> [DayEvent] {
        if demo { return demoEvents(from: start) }
        guard access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .map { e in
                DayEvent(title: e.title ?? "Sin título", start: e.startDate, end: e.endDate,
                         allDay: e.isAllDay, rgb: Self.rgb(of: e.calendar?.cgColor))
            }
            .sorted { $0.start < $1.start }
    }

    private func updateNextEvent() {
        let now = Date()
        if demo {
            nextEvent = DayEvent(title: "Parcial de Análisis", start: now.addingTimeInterval(2 * 3600 + 15 * 60),
                                 end: now.addingTimeInterval(4 * 3600), allDay: false, rgb: Palette.colors[2])
            return
        }
        guard access == .granted,
              let horizon = calendar.date(byAdding: .day, value: 14, to: now) else { nextEvent = nil; return }
        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        nextEvent = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .min { $0.startDate < $1.startDate }
            .map { DayEvent(title: $0.title ?? "Sin título", start: $0.startDate, end: $0.endDate,
                            allDay: false, rgb: Self.rgb(of: $0.calendar?.cgColor)) }
    }

    static func rgb(of cg: CGColor?) -> SIMD3<Double> {
        guard let cg, let c = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return Palette.colors[0] }
        return [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
    }

    // MARK: - Animación

    /// Para capturas: todo ya revelado.
    func skipReveal() {
        revealStart = Date.distantPast
        animating = false
    }

    /// Mantiene el TimelineView andando un rato (al cambiar de mes o de hover).
    private func pulse(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        if until > pulseUntil { pulseUntil = until }
        animating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) {
            if Date() >= self.pulseUntil { self.animating = false }
        }
    }

    // MARK: - Textos

    func dayTitle(_ d: CalendarDay) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "EEEE d"
        return f.string(from: d.date).capitalized(with: locale)
    }

    func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    func relative(_ date: Date) -> String {
        let mins = Int(date.timeIntervalSinceNow / 60)
        if mins < 1 { return "ahora" }
        if mins < 60 { return "en \(mins) min" }
        if calendar.isDateInToday(date) {
            let h = mins / 60, m = mins % 60
            return m == 0 ? "en \(h) h" : "en \(h) h \(m) min"
        }
        if calendar.isDateInTomorrow(date) { return "mañana \(timeText(date))" }
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "EEE d, HH:mm"
        return f.string(from: date)
    }

    // MARK: - Demo

    private func demoEvents(from start: Date) -> [DayEvent] {
        let samples: [(Int, Int, Double, String, Int)] = [
            (2, 10, 1.5, "Clase", 0), (3, 18, 2, "Fútbol", 1), (5, 9, 8, "Trabajo", 3),
            (8, 14, 1, "Dentista", 2), (9, 10, 1.5, "Clase", 0), (11, 9, 8, "Trabajo", 3),
            (12, 19, 3, "Cumple Juli", 2), (16, 10, 1.5, "Clase", 0), (18, 9, 8, "Trabajo", 3),
            (18, 20, 2, "Cena", 5), (19, 15, 4, "Estudiar", 4), (20, 11, 3, "Parcial", 2),
            (23, 10, 1.5, "Clase", 0), (25, 9, 8, "Trabajo", 3), (26, 17, 1, "Gym", 1),
            (27, 9, 3, "Entrega TP", 6), (30, 10, 1.5, "Clase", 0), (33, 18, 2, "Fútbol", 1),
        ]
        return samples.map { offset, hour, length, title, color in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let s = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
            return DayEvent(title: title, start: s, end: s.addingTimeInterval(length * 3600),
                            allDay: false, rgb: Palette.colors[color])
        }
    }
}
