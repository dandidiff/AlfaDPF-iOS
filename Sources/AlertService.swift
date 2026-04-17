import Foundation
import AVFoundation
import UserNotifications

/// Handles regen alerts: local notification + audible chime routed through
/// whatever output is active (car speakers when CarPlay is connected).
///
/// The audio-session configuration is the fix for Car Scanner's "no sound"
/// bug: `.playback` + `.duckOthers` is what actually ducks the music and
/// routes our tone to the head unit.
actor AlertService {
    private var player: AVAudioPlayer?

    func configure() async {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true, options: [])

        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func notifyRegenStarted(cloggingPercent: Double?) async {
        let body: String
        if let cloggingPercent {
            body = String(format: "Regeneration started — DPF at %.0f%%.", cloggingPercent)
        } else {
            body = "Regeneration started."
        }
        await post(title: "DPF Regen", body: body, soundNamed: "regen_start")
        playTone(named: "regen_start")
    }

    func notifyRegenFinished(duration: TimeInterval) async {
        let min = Int(duration / 60)
        await post(
            title: "DPF Regen",
            body: "Regeneration complete — \(min) min.",
            soundNamed: "regen_end"
        )
        playTone(named: "regen_end")
    }

    // MARK: - Private

    private func post(title: String, body: String, soundNamed: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound(named: .init(rawValue: "\(soundNamed).caf"))
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(req)
    }

    private func playTone(named name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
    }
}
