import RouteCore
import UserNotifications

/// Posts a notification when a route enters a failure state (SPEC §11 M4), once per rule and phase.
@MainActor
final class Notifier {
    private var notified: Set<String> = []
    private var authorizationRequested = false

    func update(_ statuses: [RouteStatus], appName: (String) -> String) {
        let failing = statuses.filter { $0.phase == .failed || $0.phase == .noPermission }
        let keys = Set(failing.map { "\($0.id)-\($0.phase.rawValue)" })
        for status in failing where !notified.contains("\(status.id)-\(status.phase.rawValue)") {
            let name = appName(status.bundleID)
            switch status.phase {
            case .noPermission:
                post(title: "오디오 캡처 권한이 필요합니다",
                     body: "\(name) 소리를 \(status.device.name)로 보내려면 시스템 설정에서 SoundLanes의 오디오 녹음 권한을 켜 주세요.")
            default:
                post(title: "\(name) 라우팅 실패",
                     body: "\(status.device.name)로 보내지 못했습니다. 자동으로 다시 시도합니다. \(status.message ?? "")")
            }
        }
        // Forget phases that recovered so a later failure notifies again.
        notified = keys
    }

    private func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
