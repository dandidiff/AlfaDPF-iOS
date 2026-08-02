import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DPFWidgetBundle: WidgetBundle {
    var body: some Widget {
        DPFActivityWidget()
    }
}

struct DPFActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DPFActivityAttributes.self) { context in
            LockScreenDPFView(context: context)
                .activityBackgroundTint(
                    context.state.isRegenerating
                    ? Color(red: 0.30, green: 0.105, blue: 0.015)
                    : Color(red: 0.055, green: 0.055, blue: 0.075)
                )
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "alfadpf://monitor"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DPFStateIcon(state: context.state, isStale: context.isStale, diameter: 54)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.isStale
                             ? String(localized: "NON AGGIORNATO")
                             : (context.state.isRegenerating
                                ? String(localized: "RIGENERAZIONE")
                                : String(localized: "INDICE ECU")))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(
                                context.isStale
                                ? Color.secondary
                                : (context.state.isRegenerating ? Color.orange : Color.secondary)
                            )
                        Text(context.isStale ? "—" : primaryStatus(context.state))
                            .font(.title2.bold().monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RegenPill(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(temperatureText(context.state.exhaustTemperatureC), systemImage: "thermometer.high")
                        Spacer()
                        Text(relativeUpdate(context.state.updatedAt))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                if context.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else if context.state.isRegenerating {
                    HStack(spacing: 2) {
                        Image(systemName: "flame.fill")
                        Text("RIGEN")
                            .font(.caption2.weight(.heavy))
                    }
                    .foregroundStyle(.orange)
                } else {
                    Image(systemName: "circle.hexagongrid.fill")
                        .foregroundStyle(loadTint(for: context.state.loadPercent))
                }
            } compactTrailing: {
                Text(context.isStale ? "—" : compactStatus(context.state))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(
                        !context.isStale && context.state.isRegenerating
                        ? .orange
                        : (context.isStale ? .gray : loadTint(for: context.state.loadPercent))
                    )
            } minimal: {
                if context.isStale {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(.secondary)
                } else if context.state.isRegenerating {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                } else {
                    DPFMiniGauge(load: context.state.loadPercent, diameter: 24)
                }
            }
            .keylineTint(
                !context.isStale && context.state.isRegenerating
                ? .orange
                : (context.isStale ? .gray : loadTint(for: context.state.loadPercent))
            )
            .widgetURL(URL(string: "alfadpf://monitor"))
        }
    }
}

private struct LockScreenDPFView: View {
    let context: ActivityViewContext<DPFActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            DPFStateIcon(state: context.state, isStale: context.isStale, diameter: 58)

            VStack(alignment: .leading, spacing: 3) {
                Text("ALFA DPF")
                    .font(.caption2.weight(.heavy))
                    .tracking(1.7)
                    .foregroundStyle(.red)
                Text(context.isStale
                     ? String(localized: "Dati non aggiornati")
                     : (context.state.isRegenerating
                        ? String(localized: "Rigenerazione attiva")
                        : loadStatus(context.state.loadPercent)))
                    .font(.headline)
                    .lineLimit(1)
                Text(context.isStale
                     ? String(localized: "Apri l’app per riconnettere")
                     : (context.state.isRegenerating
                     ? String(localized: "Non spegnere il motore")
                     : String(localized: "Filtro antiparticolato")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)
            RegenPill(state: context.state, isStale: context.isStale)
        }
        .padding(14)
        .overlay {
            if !context.isStale && context.state.isRegenerating {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.orange.opacity(0.85), lineWidth: 2)
            }
        }
    }
}

private struct DPFStateIcon: View {
    let state: DPFActivityAttributes.ContentState
    let isStale: Bool
    let diameter: CGFloat

    var body: some View {
        if isStale {
            ZStack {
                Circle().fill(Color.gray.opacity(0.15))
                Circle().stroke(Color.gray.opacity(0.7), lineWidth: max(3, diameter * 0.09))
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: diameter * 0.32, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: diameter, height: diameter)
            .accessibilityLabel("Dati DPF non aggiornati")
        } else if state.isRegenerating {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.18))
                Circle()
                    .stroke(Color.orange.opacity(0.85), lineWidth: max(3, diameter * 0.09))
                Image(systemName: "flame.fill")
                    .font(.system(size: diameter * 0.38, weight: .bold))
                    .foregroundStyle(.orange)
            }
            .frame(width: diameter, height: diameter)
            .accessibilityLabel("Rigenerazione DPF attiva")
        } else {
            DPFMiniGauge(load: state.loadPercent, diameter: diameter)
        }
    }
}

private struct DPFMiniGauge: View {
    let load: Double?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: max(3, diameter * 0.09))
            Circle()
                // The numeric FCA index may exceed 100; only the drawn arc is
                // capped so SwiftUI never receives an invalid trim fraction.
                .trim(from: 0, to: CGFloat(min(max(load ?? 0, 0), 100) / 100))
                .stroke(
                    loadTint(for: load),
                    style: StrokeStyle(lineWidth: max(3, diameter * 0.09), lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text(load.map(loadValue) ?? "—")
                .font(.system(size: diameter * 0.25, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct RegenPill: View {
    let state: DPFActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Image(systemName: isStale ? "clock.fill" : (state.isRegenerating ? "flame.fill" : "flame"))
                .foregroundStyle(
                    !isStale && state.isRegenerating ? Color.orange : Color.secondary
                )
            if isStale {
                Text("NON LIVE")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.secondary)
            } else if state.isRegenerating {
                Text("ATTIVA")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.orange)
                if let progress = state.regenProgressPercent, progress > 0 {
                    Text("\(loadValue(progress))%")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.orange)
                }
            } else {
                Text("standby")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private func loadTint(for load: Double?) -> Color {
    guard let load else { return .gray }
    if load > 95 { return .red }
    if load >= 85 { return .orange }
    return .green
}

private func loadValue(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func loadText(_ load: Double?) -> String {
    load.map { "\(loadValue($0))%" } ?? "—"
}

private func primaryStatus(_ state: DPFActivityAttributes.ContentState) -> String {
    guard state.isRegenerating else { return loadText(state.loadPercent) }
    if let progress = state.regenProgressPercent, progress > 0 {
        return String(format: String(localized: "ATTIVA · %@%%"), loadValue(progress))
    }
    return String(localized: "ATTIVA")
}

private func compactStatus(_ state: DPFActivityAttributes.ContentState) -> String {
    guard state.isRegenerating else { return loadText(state.loadPercent) }
    if let progress = state.regenProgressPercent, progress > 0 {
        return "\(loadValue(progress))%"
    }
    return String(localized: "ATTIVA")
}

private func loadStatus(_ load: Double?) -> String {
    guard let load else { return String(localized: "Dati non disponibili") }
    return String(format: String(localized: "Indice ECU %@%%"), loadValue(load))
}

private func temperatureText(_ temperature: Int?) -> String {
    temperature.map { "\($0) °C" } ?? "—"
}

private func relativeUpdate(_ date: Date) -> String {
    date.formatted(.relative(presentation: .named))
}
