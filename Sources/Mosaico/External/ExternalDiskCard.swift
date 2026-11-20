import SwiftUI

struct ExternalDiskCard: View {
    var model: ExternalDiskModel
    var ctx: WidgetContext
    var accessory: AnyView? = nil

    var body: some View {
        let m = Metrics(s: ctx.scale)
        TimelineView(.animation(minimumInterval: nil, paused: !model.animator.running)) { timeline in
            let _ = model.animator.step(now: timeline.date)
            let t = timeline.date.timeIntervalSinceReferenceDate
            CardLayout(m: m, bar: CardBar(source: model, anim: model.animator, t: t, m: m)) {
                CardHeader(used: model.animator.shownTotal,
                           capacity: model.capacity, busy: model.isBusy, t: t, m: m, accessory: accessory) { model.rescan() }
            } subtitle: {
                subtitle(m).subtitleSwap(key: subtitleKey, m: m)
            } legend: {
                LegendGrid(items: Array(model.items.prefix(9)), hovered: model.hoveredID, m: m,
                           cardWidth: StorageCard.baseWidth * m.s) { ByteFormat.amount($0.bytes) }
            } footer: {
                footer(m)
            }
        }
        .cardChrome(ctx: ctx, source: model, baseWidth: StorageCard.baseWidth)
    }

    private var subtitleKey: String {
        if model.scanning { return "scan" }
        if let h = model.hoveredID { return "hover-\(h)" }
        if model.ejectError != nil { return "error" }
        return "idle"
    }

    @ViewBuilder private func subtitle(_ m: Metrics) -> some View {
        if model.scanning {
            PathLine(label: "Calculando", path: model.scanPath, m: m)
        } else if let h = model.hoveredID, let item = model.items.first(where: { $0.id == h }) {
            HoverLine(item: item, detail: model.detail(for: item), m: m)
        } else if let err = model.ejectError {
            HStack(spacing: m(6)) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(rgb: Palette.colors[5]))
                Text(err).foregroundStyle(.white.opacity(0.8))
            }
            .font(.system(size: m(13), weight: .medium))
        } else {
            HStack(spacing: m(6)) {
                Image(systemName: "externaldrive.fill").foregroundStyle(.white.opacity(0.7))
                Text(model.name).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Text([model.format, "\(ByteFormat.amount(model.available)) disponibles"]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .font(.system(size: m(13), weight: .medium))
        }
    }

    @ViewBuilder private func footer(_ m: Metrics) -> some View {
        if model.scanning {
            FooterSpinner(text: "Midiendo las carpetas del disco", m: m)
        } else if model.unreadable {
            Image(systemName: "lock.fill").foregroundStyle(.white.opacity(0.45)).frame(width: m(16))
            Text("Mosaico necesita permiso para leer discos externos.")
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: m(8))
            ActionButton(title: "Abrir Ajustes", m: m) { ExternalDiskModel.openFilesAndFoldersSettings() }
        } else {
            Image(systemName: "externaldrive.fill").foregroundStyle(.white.opacity(0.5)).frame(width: m(16))
            Text(model.items.isEmpty
                 ? "El disco está vacío."
                 : "\(model.name) está conectado. Expulsalo antes de desenchufarlo.")
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: m(8))
            ActionButton(title: model.ejecting ? "Expulsando…" : "Expulsar",
                         disabled: model.ejecting, m: m) { model.eject() }
        }
    }
}
