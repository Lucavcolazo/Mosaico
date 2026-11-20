import AppKit
import Observation
import SwiftUI

/// El widget de almacenamiento: el disco interno más los externos que estén conectados.
/// Un desplegable en la cabecera elige cuál se muestra.
@Observable
final class StorageHub {
    let internalModel: StorageModel
    private(set) var disks: [ExternalDiskModel] = []
    private(set) var selected: URL?          // nil = disco interno
    private(set) var newDiskAt: Date?        // para resaltar el desplegable un rato
    let internalName: String

    init(internalModel: StorageModel) {
        self.internalModel = internalModel
        let root = URL(fileURLWithPath: "/")
        internalName = (try? root.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"
    }

    var selectedDisk: ExternalDiskModel? {
        guard let selected else { return nil }
        return disks.first { $0.volumeURL == selected }
    }

    func addDisk(_ url: URL) {
        guard !disks.contains(where: { $0.volumeURL == url }) else { return }
        let model = ExternalDiskModel(volumeURL: url)
        disks.append(model)
        model.rescan()   // se mide en segundo plano, así ya está listo al elegirlo
        let stamp = Date()
        newDiskAt = stamp
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if self.newDiskAt == stamp { self.newDiskAt = nil }
        }
    }

    func attachForSnapshot(_ disk: ExternalDiskModel) {
        disks.append(disk)
    }

    func removeDisk(_ url: URL) {
        guard let i = disks.firstIndex(where: { $0.volumeURL == url }) else { return }
        disks[i].cancel()
        disks.remove(at: i)
        if selected == url { select(nil) }
    }

    func willRemoveDisk(_ url: URL) {
        disks.first { $0.volumeURL == url }?.cancel()
    }

    func select(_ url: URL?) {
        guard url != selected else { return }
        selected = url
        newDiskAt = nil
        if let disk = selectedDisk {
            disk.hoveredID = nil
            disk.animator.replay()
        } else {
            internalModel.hovered = nil
            internalModel.animator.replay()
        }
    }

    func rescanAll() {
        internalModel.rescan()
        for d in disks { d.rescan() }
    }
}

struct StorageHubView: View {
    var hub: StorageHub
    var ctx: WidgetContext

    var body: some View {
        let picker: AnyView? = hub.disks.isEmpty ? nil : AnyView(DiskPicker(hub: hub, m: Metrics(s: ctx.scale)))
        if let disk = hub.selectedDisk {
            ExternalDiskCard(model: disk, ctx: ctx, accessory: picker)
        } else {
            StorageCard(model: hub.internalModel, ctx: ctx, accessory: picker)
        }
    }
}

private struct DiskPicker: View {
    var hub: StorageHub
    let m: Metrics

    var body: some View {
        let disk = hub.selectedDisk
        let highlight = hub.newDiskAt != nil
        Menu {
            Button {
                hub.select(nil)
            } label: {
                Label(hub.internalName, systemImage: hub.selected == nil ? "checkmark" : "internaldrive")
            }
            Divider()
            ForEach(hub.disks, id: \.volumeURL) { d in
                Button {
                    hub.select(d.volumeURL)
                } label: {
                    Label(d.name, systemImage: hub.selected == d.volumeURL ? "checkmark" : "externaldrive")
                }
            }
        } label: {
            HStack(spacing: m(6)) {
                Image(systemName: disk == nil ? "internaldrive.fill" : "externaldrive.fill")
                Text(disk?.name ?? hub.internalName)
                    .lineLimit(1)
                    .frame(maxWidth: m(130))
                Image(systemName: "chevron.down")
                    .font(.system(size: m(9), weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                if highlight {
                    Circle().fill(Color(rgb: Palette.colors[4])).frame(width: m(6), height: m(6))
                }
            }
            .font(.system(size: m(12.5), weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, m(10))
            .padding(.vertical, m(5))
            .background(
                RoundedRectangle(cornerRadius: m(8), style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: m(8), style: .continuous)
                            .strokeBorder(Color(rgb: Palette.colors[4]).opacity(highlight ? 0.7 : 0), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .animation(.easeOut(duration: 0.25), value: highlight)
    }
}
