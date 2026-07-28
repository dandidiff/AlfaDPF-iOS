import Foundation
import UserNotifications

struct AlertAuthorizationState: Equatable, Sendable {
    enum Authorization: Equatable, Sendable {
        case checking
        case notDetermined
        case denied
        case authorized
    }

    var authorization: Authorization
    var timeSensitiveEnabled: Bool
    var siriAnnouncementsEnabled: Bool
    var carPlayEnabled: Bool
    var alertEnabled: Bool
    var lockScreenEnabled: Bool
    var soundEnabled: Bool

    static let checking = AlertAuthorizationState(
        authorization: .checking,
        timeSensitiveEnabled: false,
        siriAnnouncementsEnabled: false,
        carPlayEnabled: false,
        alertEnabled: false,
        lockScreenEnabled: false,
        soundEnabled: false
    )

    var canSendTimeSensitiveAlerts: Bool {
        authorization == .authorized
            && timeSensitiveEnabled
            && alertEnabled
            && lockScreenEnabled
            && soundEnabled
    }

    var needsSettingsAttention: Bool {
        switch authorization {
        case .denied:
            return true
        case .authorized:
            return !timeSensitiveEnabled
                || !siriAnnouncementsEnabled
                || !alertEnabled
                || !lockScreenEnabled
                || !soundEnabled
        case .checking, .notDetermined:
            return false
        }
    }
}

/// Handles regeneration alerts through iOS local notifications. The app
/// delegate opts into foreground presentation, so the same banner and system
/// sound work whether the app is visible or in the background.
actor AlertService {
    private static let regenCategoryIdentifier = "DPF_REGEN_ALERT"

    func currentAuthorizationState() async -> AlertAuthorizationState {
        let center = UNUserNotificationCenter.current()
        registerCategory(on: center)
        return state(from: await center.notificationSettings())
    }

    @discardableResult
    func configure() async -> AlertAuthorizationState {
        let center = UNUserNotificationCenter.current()
        registerCategory(on: center)

        let currentSettings = await center.notificationSettings()
        guard currentSettings.authorizationStatus == .notDetermined else {
            log(settings: currentSettings)
            return state(from: currentSettings)
        }

        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .sound, .badge, .carPlay]
            )
            let settings = await center.notificationSettings()
            if granted {
                log(settings: settings)
            } else {
                OBDLog.log("notifications: permission denied")
            }
            return state(from: settings)
        } catch {
            OBDLog.log("notifications: authorization failed: \(error.localizedDescription)")
            return state(from: await center.notificationSettings())
        }
    }

    private func registerCategory(on center: UNUserNotificationCenter) {
        let regenCategory = UNNotificationCategory(
            identifier: Self.regenCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: [.allowInCarPlay]
        )
        center.setNotificationCategories([regenCategory])
    }

    private func state(from settings: UNNotificationSettings) -> AlertAuthorizationState {
        let authorization: AlertAuthorizationState.Authorization
        switch settings.authorizationStatus {
        case .notDetermined:
            authorization = .notDetermined
        case .denied:
            authorization = .denied
        case .authorized, .provisional, .ephemeral:
            authorization = .authorized
        @unknown default:
            authorization = .denied
        }

        return AlertAuthorizationState(
            authorization: authorization,
            timeSensitiveEnabled: settings.timeSensitiveSetting == .enabled,
            siriAnnouncementsEnabled: settings.announcementSetting == .enabled,
            carPlayEnabled: settings.carPlaySetting == .enabled,
            alertEnabled: settings.alertSetting == .enabled,
            lockScreenEnabled: settings.lockScreenSetting == .enabled,
            soundEnabled: settings.soundSetting == .enabled
        )
    }

    func notifyRegenStarted(cloggingPercent: Double?) async {
        let body: String
        if let cloggingPercent {
            body = String(
                format: "Rigenerazione iniziata — DPF al %.0f%%. Non spegnere il motore.",
                cloggingPercent
            )
        } else {
            body = "Rigenerazione iniziata. Non spegnere il motore."
        }
        await post(
            title: "Rigenerazione DPF iniziata",
            body: body
        )
    }

    func notifyRegenFinished(duration: TimeInterval) async {
        let min = max(1, Int((duration / 60).rounded()))
        await post(
            title: "Rigenerazione DPF terminata",
            body: "Rigenerazione completata — \(min) min."
        )
    }

    func notifyTest() async {
        await post(
            title: "Test avviso AlfaDPF",
            body: "Test a schermo bloccato: se Siri è abilitata, deve leggere questo avviso.",
            delay: 5
        )
    }

    // MARK: - Private

    private func post(title: String, body: String, delay: TimeInterval? = nil) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        log(settings: settings)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.regenCategoryIdentifier
        // A DPF regeneration is time-sensitive vehicle information: it should
        // arrive immediately and may break through Focus when the user allows
        // Time Sensitive notifications for DPF Monitor.
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: delay.map {
                UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false)
            }
        )
        do {
            try await UNUserNotificationCenter.current().add(req)
            OBDLog.log(
                "notification queued: \(title), "
                + (delay.map { "delivery in \(Int($0)) s" } ?? "immediate delivery")
            )
        } catch {
            OBDLog.log("notification failed: \(error.localizedDescription)")
        }
    }

    private func log(settings: UNNotificationSettings) {
        OBDLog.log(
            "notifications: status=\(settings.authorizationStatus.rawValue) "
            + "(alerts=\(settings.alertSetting.rawValue), "
            + "lockScreen=\(settings.lockScreenSetting.rawValue), "
            + "sound=\(settings.soundSetting.rawValue), "
            + "carPlay=\(settings.carPlaySetting.rawValue), "
            + "timeSensitive=\(settings.timeSensitiveSetting.rawValue), "
            + "announce=\(settings.announcementSetting.rawValue))"
        )
    }
}
