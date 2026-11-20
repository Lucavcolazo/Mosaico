import AppKit
import DiskArbitration

/// Avisa cuando se conecta o se desconecta un disco externo (sin contar imágenes .dmg ni discos de red).
@MainActor
final class VolumeWatcher {
    var onAdd: ((URL) -> Void)?
    var onRemove: ((URL) -> Void)?
    var onWillRemove: ((URL) -> Void)?

    private var known: Set<URL> = []
    private var observers: [NSObjectProtocol] = []
    private let session = DASessionCreate(kCFAllocatorDefault)

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(nc.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let url = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.standardizedFileURL
            MainActor.assumeIsolated {
                if let url { self?.onWillRemove?(url) }
            }
        })
        refresh()
    }

    func refresh() {
        let current = Set(externalVolumes())
        for url in current.subtracting(known).sorted(by: { $0.path < $1.path }) { onAdd?(url) }
        for url in known.subtracting(current) { onRemove?(url) }
        known = current
    }

    private func externalVolumes() -> [URL] {
        let keys: [URLResourceKey] = [
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> URL? in
            let url = url.standardizedFileURL
            guard url.path.hasPrefix("/Volumes/"),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsBrowsable == true,
                  v.volumeIsLocal == true,
                  v.volumeIsRootFileSystem != true,
                  v.volumeIsInternal != true,
                  !isDiskImage(url)
            else { return nil }
            return url
        }
    }

    private func isDiskImage(_ url: URL) -> Bool {
        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let desc = DADiskCopyDescription(disk) as? [CFString: Any]
        else { return false }
        let model = (desc[kDADiskDescriptionDeviceModelKey] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let proto = desc[kDADiskDescriptionDeviceProtocolKey] as? String ?? ""
        return model == "Disk Image" || proto == "Virtual Interface"
    }
}
