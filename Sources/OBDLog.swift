import Foundation
import Observation

/// In-app diagnostics log. Every command sent to the adapter and every raw
/// reply is recorded here, so a "connected but no data" problem can be
/// diagnosed on the phone itself — no Mac/Xcode console required in the car.
///
/// `log(_:)` is callable from any isolation (the transports and the line
/// engine are actors); it prints to the Xcode console too when attached.
@Observable
final class OBDLog {
    static let shared = OBDLog()

    private(set) var lines: [String] = []
    private let maxLines = 400

    var text: String { lines.joined(separator: "\n") }

    func clear() { lines.removeAll() }

    @MainActor
    func append(_ message: String) {
        lines.append("\(Self.formatter.string(from: Date()))  \(message)")
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    nonisolated static func log(_ message: String) {
        print("[OBD] \(message)")
        Task { @MainActor in shared.append(message) }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
