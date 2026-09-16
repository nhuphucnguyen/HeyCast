import AppKit
import ServiceManagement

/// Public-API haptic feedback (replaces RustCast's private MTActuator use).
enum HapticsService {
    static func tick(enabled: Bool) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment, performanceTime: .now
        )
    }

    static func failure(enabled: Bool) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic, performanceTime: .now
        )
    }
}

/// Login item via the modern ServiceManagement API.
enum LoginItemService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("SwiftCast: SMAppService error: \(error.localizedDescription)")
        }
    }
}
