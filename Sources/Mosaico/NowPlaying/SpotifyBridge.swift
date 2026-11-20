import AppKit

struct SpotifyTrack: Equatable {
    var playing: Bool
    var title: String
    var artist: String
    var album: String
    var duration: Double      // segundos
    var position: Double      // segundos
    var artworkURL: URL?
    var id: String
}

enum SpotifyResult {
    case closed
    case stopped
    case denied
    case failed
    case track(SpotifyTrack)
}

/// Habla con Spotify por AppleScript. Todo corre en una cola propia para no trabar la UI.
/// Nunca abre Spotify por su cuenta: si está cerrado, no le manda nada.
final class SpotifyBridge: @unchecked Sendable {
    static let bundleID = "com.spotify.client"
    private let queue = DispatchQueue(label: "mosaico.spotify")
    private var stateScript: NSAppleScript?

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    private static let stateSource = """
    tell application id "com.spotify.client"
        set s to player state as string
        if s is "stopped" then return "stopped"
        set t to current track
        set sep to (character id 31)
        return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((duration of t) as string) & sep & ((player position) as string) & sep & (artwork url of t) & sep & (id of t)
    end tell
    """

    func fetch(_ done: @escaping (SpotifyResult) -> Void) {
        guard isRunning else { done(.closed); return }
        queue.async {
            if self.stateScript == nil {
                self.stateScript = NSAppleScript(source: Self.stateSource)
            }
            var error: NSDictionary?
            let out = self.stateScript?.executeAndReturnError(&error)
            let result: SpotifyResult
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                result = code == -1743 ? .denied : (code == -600 ? .closed : .failed)
            } else if let text = out?.stringValue {
                result = Self.parse(text)
            } else {
                result = .failed
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Comandos: "playpause", "next track", "previous track", "set player position to …".
    func send(_ command: String, then: (() -> Void)? = nil) {
        guard isRunning else { return }
        queue.async {
            let script = NSAppleScript(source: "tell application id \"com.spotify.client\" to \(command)")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let then { DispatchQueue.main.async(execute: then) }
        }
    }

    func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    static func parse(_ text: String) -> SpotifyResult {
        if text == "stopped" { return .stopped }
        let parts = text.components(separatedBy: "\u{1F}")
        guard parts.count >= 8 else { return .failed }
        return .track(SpotifyTrack(
            playing: parts[0] == "playing",
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: number(parts[4]) / 1000,
            position: number(parts[5]),
            artworkURL: URL(string: parts[6]),
            id: parts[7]
        ))
    }
}
