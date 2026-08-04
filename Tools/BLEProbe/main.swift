import Foundation

// Live probe for the BLE transport, runnable on a Mac near the car.
// Exercises the exact code the iOS app ships: BLEConnection + ELM327 +
// Mode01Reader + DPF PIDs.
//
// Build & run:
//   swiftc Sources/Models.swift Sources/OBDLog.swift Sources/OBDTransport.swift \
//          Sources/OBDConnection.swift Sources/BLEConnection.swift Sources/ELM327.swift \
//          Sources/Mode01.swift Tools/BLEProbe/main.swift -o /tmp/ble_probe && /tmp/ble_probe
//
// Prerequisites: dongle in the OBD port, ignition on, Bluetooth enabled on
// the Mac. First run asks for Bluetooth permission for your terminal app.

func log(_ message: String) {
    print(message)
    fflush(stdout)
}

func fmt(_ value: Double?, _ unit: String) -> String {
    value.map { String(format: "%.1f %@", $0, unit) } ?? "—"
}

log("Scanning for a Vlink/OBD dongle over BLE (30 s)…")
let ble = BLEConnection()
await ble.start()
do {
    try await ble.isReady()
} catch {
    log("✗ \(error.localizedDescription)")
    await ble.stop()
    exit(1)
}

log("✓ Dongle connected.")

let elm = ELM327(connection: ble)
do {
    try await elm.initializeSession()
    log("✓ ELM327 init OK.")
} catch {
    log("✗ ELM init failed: \(error)")
    await ble.stop()
    exit(1)
}

log("\n— Standard Mode 01 (when supported by the ECU) —")
let mode01 = Mode01Reader(connection: ble)
let live = await mode01.poll()
log("RPM:      \(fmt(live.rpm, ""))")
log("Speed:    \(fmt(live.speedKph, "km/h"))")
log("Coolant:  \(fmt(live.coolantC, "°C"))")
log("Intake:   \(fmt(live.intakeTempC, "°C"))")
log("Load:     \(fmt(live.engineLoadPct, "%"))")
log("Turbo:    \(fmt(live.turboBoostBar, "bar"))")

log("\n— Alfa/FCA Mode 22 DPF PIDs —")
let dpfPIDs: [(String, DPFPID, String)] = [
    ("Clogging",        .cloggingPercent,      "%"),
    ("Exhaust temp",    .exhaustTempC,         "°C"),
    ("Regen progress",  .regenProgressPercent, "%"),
    ("Dist since regen", .distanceSinceRegenKm, "km"),
    ("Total regens",    .totalRegenCount,      ""),
]
var dpfHits = 0
for (label, pid, unit) in dpfPIDs {
    do {
        let bytes = try await elm.readMode22(pid: pid.rawValue)
        let value = try pid.decode(bytes: bytes)
        dpfHits += 1
        log("\(label): \(String(format: "%.1f", value)) \(unit)")
    } catch {
        log("\(label): NO DATA (\(error))")
    }
}

log("")
if dpfHits == dpfPIDs.count {
    log("✓ All DPF PIDs answered — the app will be fully functional on this car.")
} else if dpfHits > 0 {
    log("△ \(dpfHits)/\(dpfPIDs.count) DPF PIDs answered — partial DPF data on this car.")
} else {
    log("✗ No DPF PIDs answered — Mode 01 works, but this ECU variant needs different PIDs.")
}

await ble.stop()
exit(0)
