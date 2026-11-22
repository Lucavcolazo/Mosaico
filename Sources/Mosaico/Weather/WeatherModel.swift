import AppKit
import CoreLocation
import Observation

/// Tipo de cielo, a partir del código WMO de Open-Meteo.
enum Sky: Equatable {
    case clear, partly, cloudy, fog, drizzle, rain, snow, storm

    init(code: Int) {
        switch code {
        case 0: self = .clear
        case 1, 2: self = .partly
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51...57: self = .drizzle
        case 61...67, 80...82: self = .rain
        case 71...77, 85, 86: self = .snow
        case 95...99: self = .storm
        default: self = .cloudy
        }
    }

    func title(day: Bool) -> String {
        switch self {
        case .clear: day ? "Despejado" : "Noche despejada"
        case .partly: "Parcialmente nublado"
        case .cloudy: "Nublado"
        case .fog: "Niebla"
        case .drizzle: "Llovizna"
        case .rain: "Lluvia"
        case .snow: "Nieve"
        case .storm: "Tormenta"
        }
    }

    func symbol(day: Bool) -> String {
        switch self {
        case .clear: day ? "sun.max.fill" : "moon.stars.fill"
        case .partly: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .snow: "cloud.snow.fill"
        case .storm: "cloud.bolt.rain.fill"
        }
    }
}

struct HourPoint: Equatable {
    var date: Date
    var temp: Double
    var rainChance: Double   // 0…100
    var sky: Sky
}

struct DayPoint: Equatable {
    var date: Date
    var max: Double
    var min: Double
    var sky: Sky
}

@Observable
final class WeatherModel: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable { case locating, loading, ready, denied, failed }

    private(set) var status: Status = .locating
    private(set) var city = ""
    private(set) var temp: Double = 0
    private(set) var feelsLike: Double = 0
    private(set) var humidity: Double = 0
    private(set) var wind: Double = 0
    private(set) var sky: Sky = .clear
    private(set) var isDay = true
    private(set) var hours: [HourPoint] = []
    private(set) var days: [DayPoint] = []
    private(set) var todayMax: Double = 0
    private(set) var todayMin: Double = 0
    var hoveredHour: Int?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var coordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let demo: Bool
    @ObservationIgnored private var started = false

    init(demo: Bool = false) {
        self.demo = demo
        super.init()
        if demo { loadDemo() }
    }

    func start() {
        guard !demo, !started else { return }
        started = true
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        handleAuthorization()
        // Cada 20 minutos alcanza para el clima.
        timer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    // MARK: - Ubicación

    private func handleAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .locating
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .denied
        default:
            status = .locating
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // Redondeado a ~1 km: alcanza para el clima y no comparte la ubicación exacta.
        let rounded = CLLocationCoordinate2D(
            latitude: (loc.coordinate.latitude * 100).rounded() / 100,
            longitude: (loc.coordinate.longitude * 100).rounded() / 100
        )
        let first = coordinate == nil
        coordinate = rounded
        if first || city.isEmpty { resolveCity(loc) }
        fetch()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if coordinate == nil { status = manager.authorizationStatus == .denied ? .denied : .failed }
    }

    private func resolveCity(_ loc: CLLocation) {
        CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "es_AR")) { marks, _ in
            DispatchQueue.main.async {
                if let p = marks?.first { self.city = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? "" }
            }
        }
    }

    func retry() {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        } else {
            status = .locating
            manager.requestLocation()
        }
    }

    // MARK: - Open-Meteo

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let relative_humidity_2m: Double
            let wind_speed_10m: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double]
            let precipitation_probability: [Double?]
            let weather_code: [Int]
        }
        struct Daily: Decodable {
            let time: [String]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let weather_code: [Int]
        }
        let utc_offset_seconds: Int
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    func fetch() {
        guard !demo, let c = coordinate else { return }
        if status != .ready { status = .loading }
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", c.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", c.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
        ]
        URLSession.shared.dataTask(with: comps.url!) { data, _, _ in
            let decoded = data.flatMap { try? JSONDecoder().decode(Response.self, from: $0) }
            DispatchQueue.main.async {
                guard let decoded else {
                    if self.status != .ready { self.status = .failed }
                    return
                }
                self.apply(decoded)
            }
        }.resume()
    }

    private func apply(_ r: Response) {
        let tz = TimeZone(secondsFromGMT: r.utc_offset_seconds) ?? .current
        let hourFmt = DateFormatter()
        hourFmt.timeZone = tz
        hourFmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let dayFmt = DateFormatter()
        dayFmt.timeZone = tz
        dayFmt.dateFormat = "yyyy-MM-dd"

        temp = r.current.temperature_2m
        feelsLike = r.current.apparent_temperature
        humidity = r.current.relative_humidity_2m
        wind = r.current.wind_speed_10m
        sky = Sky(code: r.current.weather_code)
        isDay = r.current.is_day == 1

        let now = Date()
        var points: [HourPoint] = []
        for (i, t) in r.hourly.time.enumerated() {
            guard let d = hourFmt.date(from: t), d > now.addingTimeInterval(-3600) else { continue }
            points.append(HourPoint(date: d, temp: r.hourly.temperature_2m[i],
                                    rainChance: r.hourly.precipitation_probability[i] ?? 0,
                                    sky: Sky(code: r.hourly.weather_code[i])))
            if points.count == 24 { break }
        }
        hours = points

        days = r.daily.time.enumerated().compactMap { i, t in
            guard let d = dayFmt.date(from: t) else { return nil }
            return DayPoint(date: d, max: r.daily.temperature_2m_max[i], min: r.daily.temperature_2m_min[i],
                            sky: Sky(code: r.daily.weather_code[i]))
        }
        todayMax = days.first?.max ?? temp
        todayMin = days.first?.min ?? temp
        status = .ready
    }

    // MARK: - Textos

    static func deg(_ v: Double) -> String { "\(Int(v.rounded()))°" }

    static let locale = Locale(identifier: "es_AR")

    static func hourLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "HH"
        return f.string(from: d)
    }

    static func dayLabel(_ d: Date, index: Int) -> String {
        if index == 0 { return "Hoy" }
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "EEE"
        let s = f.string(from: d).replacingOccurrences(of: ".", with: "")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    // MARK: - Demo

    private func loadDemo() {
        status = .ready
        city = "Córdoba"
        temp = 27.4
        feelsLike = 28.9
        humidity = 41
        wind = 14
        sky = .partly
        isDay = true
        let cal = Calendar.current
        let base = cal.date(bySetting: .minute, value: 0, of: Date())!
        hours = (0..<24).map { i in
            let h = Double((cal.component(.hour, from: base) + i) % 24)
            let t = 21 + 8 * sin((h - 9) / 24 * 2 * .pi)
            let rain: Double = (i >= 7 && i <= 10) ? [30, 65, 80, 40][i - 7] : 5
            let sky: Sky = rain > 50 ? .rain : (h < 7 || h > 20 ? .clear : .partly)
            return HourPoint(date: base.addingTimeInterval(Double(i) * 3600), temp: t, rainChance: rain, sky: sky)
        }
        let skies: [Sky] = [.partly, .rain, .storm, .cloudy, .clear, .clear, .partly]
        days = (0..<7).map { i in
            DayPoint(date: cal.date(byAdding: .day, value: i, to: Date())!, max: [29, 24, 22, 25, 30, 31, 28][i],
                     min: [16, 15, 13, 14, 17, 19, 18][i], sky: skies[i])
        }
        todayMax = 29
        todayMin = 16
    }
}
