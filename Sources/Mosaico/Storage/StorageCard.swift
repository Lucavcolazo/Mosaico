import SwiftUI

struct StorageCard: View {
    var model: StorageModel
    var ctx: WidgetContext
    var accessory: AnyView? = nil

    static let baseWidth: CGFloat = 600

    var body: some View {
        let m = Metrics(s: ctx.scale)
        TimelineView(.animation(minimumInterval: nil, paused: !model.animator.running || !ctx.isVisible)) { timeline in
            let _ = model.animator.step(now: timeline.date)
            let t = timeline.date.timeIntervalSinceReferenceDate
            CardLayout(m: m, bar: CardBar(source: model, anim: model.animator, t: t, m: m)) {
                CardHeader(used: model.animator.shownTotal, capacity: model.totalCapacity,
                           busy: model.isBusy, t: t, m: m, accessory: accessory) { model.rescan() }
            } subtitle: {
                subtitle(m).subtitleSwap(key: subtitleKey, m: m)
            } legend: {
                LegendGrid(
                    items: StorageCategory.legendOrder.map { $0.barItem(bytes: model.bytes[$0] ?? 0) },
                    hovered: model.hoveredID, m: m, cardWidth: Self.baseWidth * m.s
                ) { item in
                    let c = StorageCategory(rawValue: item.id)
                    return c.map { model.unreadable.contains($0) } == true ? "—" : ByteFormat.amount(item.bytes)
                }
            } footer: {
                footer(m)
            }
        }
        .cardChrome(ctx: ctx, source: model, baseWidth: Self.baseWidth)
    }

    private var subtitleKey: String {
        switch model.phase {
        case .scanning: return "scan"
        case .clearing(let c, _): return "clear-\(c.rawValue)"
        case .idle:
            if let h = model.hovered { return "hover-\(h.rawValue)" }
            if let b = model.freedBanner { return "freed-\(b.id)" }
            return model.scannedOnce ? "idle" : "empty"
        }
    }

    @ViewBuilder private func subtitle(_ m: Metrics) -> some View {
        switch model.phase {
        case .scanning(let path):
            PathLine(label: "Calculando", path: path, m: m)
        case .clearing(let c, let path):
            PathLine(label: c == .caches ? "Limpiando cachés" : "Vaciando la Papelera", path: path, m: m)
        case .idle:
            if let h = model.hovered {
                HoverLine(item: h.barItem(bytes: model.bytes[h] ?? 0), detail: model.insight(for: h), m: m)
            } else if let b = model.freedBanner {
                HStack(spacing: m(6)) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(rgb: StorageCategory.developer.rgb))
                    Text("Liberaste \(ByteFormat.amount(b.freed)).").foregroundStyle(.white.opacity(0.9))
                    Text("\(ByteFormat.amount(model.available)) disponibles").foregroundStyle(.white.opacity(0.45))
                }
                .font(.system(size: m(13), weight: .medium))
            } else if model.scannedOnce {
                Text("\(ByteFormat.amount(model.available)) disponibles")
                    .font(.system(size: m(13), weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder private func footer(_ m: Metrics) -> some View {
        switch model.suggestion {
        case .scanning:
            FooterSpinner(text: "Buscando cosas que puedas liberar", m: m)
        case .clear(let c):
            Image(systemName: c.symbol).foregroundStyle(c.color).frame(width: m(16))
            Text(message(for: c))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: m(8))
            ActionButton(
                title: model.confirming == c ? "¿Seguro?" : (c == .caches ? "Limpiar cachés" : "Vaciar Papelera"),
                tint: model.confirming == c ? c.color : nil,
                disabled: model.isBusy, m: m
            ) { model.requestClear(c) }
        case .needsAccess:
            Image(systemName: "lock.fill").foregroundStyle(.white.opacity(0.45)).frame(width: m(16))
            Text("Para medir la Papelera hace falta Acceso total al disco.")
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: m(8))
            ActionButton(title: "Abrir Ajustes", m: m) { StorageModel.openFullDiskAccessSettings() }
        case .allGood:
            Image(systemName: "checkmark").foregroundStyle(Color(rgb: StorageCategory.developer.rgb)).frame(width: m(16))
            Text("Nada más que valga la pena limpiar por ahora.")
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
        }
    }

    private func message(for c: StorageCategory) -> String {
        let size = ByteFormat.amount(model.bytes[c] ?? 0)
        return c == .caches
            ? "Las cachés ocupan \(size). Las apps las regeneran solas."
            : "La Papelera guarda \(size) que ya borraste."
    }
}
