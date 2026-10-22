import Observation
import ServiceManagement

/// "Launch at login" via `SMAppService` (SPEC §11 M3).
@MainActor @Observable
final class LoginItem {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var message: String?

    init() { updateMessage() }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "로그인 항목을 바꾸지 못했습니다: \(error.localizedDescription)"
            isEnabled = SMAppService.mainApp.status == .enabled
            return
        }
        isEnabled = SMAppService.mainApp.status == .enabled
        updateMessage()
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private func updateMessage() {
        message = SMAppService.mainApp.status == .requiresApproval
            ? "시스템 설정 > 일반 > 로그인 항목에서 SoundLanes를 허용해 주세요."
            : nil
    }
}
