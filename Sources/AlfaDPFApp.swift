import SwiftUI

@main
struct AlfaDPFApp: App {
    @State private var session = MonitorSession()

    var body: some Scene {
        WindowGroup {
            PhoneRootView(session: session)
        }
    }
}

struct PhoneRootView: View {
    @Bindable var session: MonitorSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StatusCard(status: session.status)
                    ActionButton(session: session)
                    LiveDataSection(live: session.live)
                    DPFSection(dpf: session.dpf, lastEvent: session.lastRegenEvent)
                    Footer()
                }
                .padding()
            }
            .navigationTitle("AlfaDPF")
        }
    }
}

// MARK: - Subviews

private struct StatusCard: View {
    let status: MonitorSession.Status

    var body: some View {
        let (label, tint) = display(status)
        HStack(spacing: 12) {
            Circle().fill(tint).frame(width: 10, height: 10)
            Text(label).font(.headline)
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func display(_ s: MonitorSession.Status) -> (String, Color) {
        switch s {
        case .idle:         return ("Idle",        .gray)
        case .connecting:   return ("Connecting…", .orange)
        case .running:      return ("Connected",   .green)
        case .failed(let m):return (m,             .red)
        }
    }
}

private struct ActionButton: View {
    @Bindable var session: MonitorSession

    var body: some View {
        Button(action: toggle) {
            Text(session.status == .running ? "Disconnect" : "Connect to OBD")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(session.status == .running ? Color.red : Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func toggle() {
        switch session.status {
        case .running: session.stop()
        default:       session.start()
        }
    }
}

private struct LiveDataSection: View {
    let live: Mode01Reader.Live

    var body: some View {
        SectionHeader("Live data")
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            Tile(title: "RPM",       value: live.rpm.map { String(format: "%.0f", $0) })
            Tile(title: "Speed",     value: live.speedKph.map { "\(Int($0)) km/h" })
            Tile(title: "Coolant",   value: live.coolantC.map { "\(Int($0))°C" })
            Tile(title: "Intake",    value: live.intakeTempC.map { "\(Int($0))°C" })
            Tile(title: "Load",      value: live.engineLoadPct.map { String(format: "%.0f%%", $0) })
        }
    }
}

private struct DPFSection: View {
    let dpf: DPFState
    let lastEvent: String?

    var body: some View {
        SectionHeader("DPF status")
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            Tile(title: "Soot",         value: dpf.sootMassGrams.map { String(format: "%.1f g", $0) })
            Tile(title: "Since regen",  value: dpf.distanceSinceLastRegenKm.map { "\(Int($0)) km" })
            Tile(title: "Exhaust",      value: dpf.exhaustTempC.map { "\(Int($0))°C" })
            Tile(title: "Regen",        value: dpf.regenActive.map { $0 ? "ACTIVE" : "idle" })
        }
        if let lastEvent {
            Text(lastEvent).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct Footer: View {
    var body: some View {
        Text("DPF values require Alfa/FCA Mode 22 PIDs. Until those are configured in Models.swift, only live Mode 01 data will populate.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }
}

private struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3.weight(.semibold)).padding(.top, 8)
    }
}

private struct Tile: View {
    let title: String
    let value: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
