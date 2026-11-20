import Foundation

final class CancelToken: @unchecked Sendable {
    var isCancelled = false
}

struct FolderScanResult {
    var bytes: Int64 = 0
    /// Elemento de primer nivel (dentro de cada raíz) → bytes. Sirve para "lo más pesado".
    var children: [String: Int64] = [:]
    /// false si había carpetas pero ninguna se pudo leer (permisos).
    var readable = true
}

enum FolderScanner {
    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    private static let keySet = Set(keys)

    /// Recorre las carpetas sumando el espacio real ocupado en disco.
    /// `progress` se llama ~30 veces por segundo como mucho, desde el hilo del escaneo.
    static func scan(
        roots: [URL],
        token: CancelToken,
        progress: (_ bytes: Int64, _ path: String, _ children: [String: Int64]) -> Void
    ) -> FolderScanResult {
        var result = FolderScanResult()
        let fm = FileManager.default
        var anyExisting = false
        var anyReadable = false
        var lastReport = Date.distantPast
        var currentPath = ""

        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            anyExisting = true
            guard (try? fm.contentsOfDirectory(atPath: root.path)) != nil else { continue }
            anyReadable = true
            currentPath = root.path
            progress(result.bytes, currentPath, result.children)

            guard let walker = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            var currentChild = ""
            var counter = 0
            for case let url as URL in walker {
                if token.isCancelled { return result }
                let level = walker.level
                if level == 1 { currentChild = url.lastPathComponent }
                guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
                if values.isDirectory == true {
                    if level <= 4 { currentPath = url.path }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                result.bytes += size
                result.children[currentChild, default: 0] += size

                counter += 1
                if counter & 127 == 0 {
                    let now = Date()
                    if now.timeIntervalSince(lastReport) > 0.033 {
                        lastReport = now
                        progress(result.bytes, currentPath, result.children)
                    }
                }
            }
        }
        result.readable = !anyExisting || anyReadable
        progress(result.bytes, currentPath, result.children)
        return result
    }
}
