import Foundation
import ServiceManagement

enum LoginItemState: String {
    case disabled, enabled, requiresApproval, notFound

    static var systemState: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .disabled
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
}

final class LoginItems {
    private let isInitialized: () -> Bool
    private let markInitialized: () -> Void
    private let readState: () -> LoginItemState
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(isInitialized: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: "loginItemDefaultApplied") },
         markInitialized: @escaping () -> Void = { UserDefaults.standard.set(true, forKey: "loginItemDefaultApplied") },
         readState: @escaping () -> LoginItemState = { .systemState },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.isInitialized = isInitialized
        self.markInitialized = markInitialized
        self.readState = readState
        self.register = register
        self.unregister = unregister
    }

    var state: LoginItemState { readState() }

    func enableByDefaultOnce() throws {
        guard !isInitialized() else { return }
        // 只设置一次默认值，之后尊重菜单或系统设置中的关闭选择。
        markInitialized()
        if state == .enabled || state == .requiresApproval { return }
        try register()
    }

    func setEnabled(_ enabled: Bool) throws {
        markInitialized()
        if enabled {
            if state == .enabled || state == .requiresApproval { return }
            try register()
        } else {
            if state == .disabled || state == .notFound { return }
            try unregister()
        }
    }
}
