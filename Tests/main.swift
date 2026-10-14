import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ title: String) {
    checks += 1
    guard condition() else { fatalError("失败：\(title)") }
    print("通过：\(title)")
}
func rejects(_ operation: () throws -> Void) -> Bool {
    do { try operation(); return false } catch { return true }
}
let internalScreen = DisplayRecord(uuid: "builtin", id: 1001, name: "内建屏", builtIn: true, enabled: true, online: true, main: true)
let external = DisplayRecord(uuid: "external", id: 1002, name: "外屏 A", builtIn: false, enabled: true, online: true, main: false)
let externalB = DisplayRecord(uuid: "external-b", id: 1003, name: "外屏 B", builtIn: false, enabled: true, online: true, main: false)
check(!DisplayPolicy.canDisable(internalScreen, among: [internalScreen, external]), "内建屏保护")
check(!DisplayPolicy.canDisable(external, among: [external]), "最后一块输出保护")
check(DisplayPolicy.canDisable(external, among: [internalScreen, external]), "有其他输出时允许关闭外屏")
var offline = internalScreen
offline.online = false
check(!DisplayPolicy.canDisable(external, among: [offline, external]), "离线屏不计入安全输出")
var disabled = internalScreen
disabled.enabled = false
check(!DisplayPolicy.canDisable(external, among: [disabled, external]), "关闭的屏不计入安全输出")
check(DisplayPolicy.merge([internalScreen], owned: [external.uuid: external]).contains(where: { $0.uuid == external.uuid && !$0.enabled }), "软件关闭后保留开启入口")

final class FakeSystem {
    var live = [internalScreen, external, externalB]
    var calls: [(UInt32, Bool)] = []
    var result = DOSResult(code: 0, stage: 0)
    var delayedEnable = false
    var identityMatches = true
    func manager(_ journal: RecoveryJournal) throws -> DisplayManager {
        try DisplayManager(journal: journal, setOutput: { [self] id, enabled in
            calls.append((id, enabled))
            guard result.code == 0 else { return result }
            if enabled && !delayedEnable {
                var record = id == externalB.id ? externalB : external
                record.id = id
                if !live.contains(where: { $0.id == id }) { live.append(record) }
            } else if !enabled { live.removeAll { $0.id == id } }
            return result
        }, enumerate: { [self] in live }, resolve: { $0.id }, enabled: { [self] id in
            live.contains { $0.id == id && $0.enabled && $0.online }
        }, matchesIdentity: { [self] _, _ in identityMatches })
    }
}
func journal(_ name: String) -> RecoveryJournal { RecoveryJournal(url: root.appendingPathComponent("\(name)/recovery.json")) }

let system = FakeSystem()
let persistentJournal = journal("success")
let manager = try system.manager(persistentJournal)
try manager.disable(external.uuid)
try manager.refresh()
check(manager.owned.count == 1 && manager.displays.contains(where: { $0.uuid == external.uuid && !$0.enabled }), "关闭后保存 UUID 和恢复记录")
check(system.live.contains(where: { $0.uuid == externalB.uuid }), "关闭 A 不影响 B")
let restarted = try system.manager(persistentJournal)
check(restarted.owned[external.uuid] != nil, "异常重启读取恢复记录")
try manager.disable(externalB.uuid)
check(manager.owned.count == 2, "独立关闭多个外屏")
check(manager.restoreAll().isEmpty && manager.owned.isEmpty, "批量恢复并清理恢复记录")
let restoredJournal = try persistentJournal.load()
check(restoredJournal.isEmpty, "恢复后持久化为空")

let failureSystem = FakeSystem()
failureSystem.result = DOSResult(code: 1000, stage: 3)
let failureManager = try failureSystem.manager(journal("failure"))
check(rejects { try failureManager.disable(external.uuid) } && failureManager.owned.isEmpty, "设置失败报告错误并撤回记录")
failureSystem.result = DOSResult(code: 1000, stage: 4)
check(rejects { try failureManager.disable(external.uuid) } && failureManager.owned[external.uuid] != nil, "提交失败保留恢复记录")

let delayedSystem = FakeSystem()
let delayedManager = try delayedSystem.manager(journal("delayed"))
try delayedManager.disable(external.uuid)
delayedSystem.delayedEnable = true
try delayedManager.enable(external.uuid)
check(delayedManager.owned[external.uuid] != nil, "开启尚未生效时保留恢复记录")
delayedSystem.delayedEnable = false
try delayedManager.enable(external.uuid)
check(delayedManager.owned.isEmpty, "确认开启后才清理恢复记录")

let identitySystem = FakeSystem()
let identityManager = try identitySystem.manager(journal("identity"))
try identityManager.disable(external.uuid)
identitySystem.identityMatches = false
let previousCalls = identitySystem.calls.count
check(rejects { try identityManager.enable(external.uuid) } && identitySystem.calls.count == previousCalls, "编号被其他屏幕占用时拒绝操作")

let blockedRoot = root.appendingPathComponent("not-a-directory")
try Data("blocked".utf8).write(to: blockedRoot)
let journalSystem = FakeSystem()
let journalManager = try journalSystem.manager(RecoveryJournal(url: blockedRoot.appendingPathComponent("recovery.json")))
check(rejects { try journalManager.disable(external.uuid) } && journalSystem.calls.isEmpty, "恢复记录无法保存时禁止关闭")

let protectedSystem = FakeSystem()
protectedSystem.live = [external]
let protectedManager = try protectedSystem.manager(journal("last-screen"))
check(rejects { try protectedManager.disable(external.uuid) } && protectedSystem.calls.isEmpty, "执行时再次检查最后一块输出")

final class FakeLoginItems {
    var initialized = false
    var state: LoginItemState = .disabled
    var registrations = 0
    var removals = 0
    var failRegistration = false

    func controller() -> LoginItems {
        LoginItems(isInitialized: { [self] in initialized }, markInitialized: { [self] in initialized = true },
            readState: { [self] in state }, register: { [self] in
                registrations += 1
                if failRegistration { throw DisplayFailure(message: "模拟系统拒绝注册") }
                state = .enabled
            }, unregister: { [self] in removals += 1; state = .disabled })
    }
}

let loginSystem = FakeLoginItems()
try loginSystem.controller().enableByDefaultOnce()
check(loginSystem.state == .enabled && loginSystem.registrations == 1, "首次启动默认注册登录项")
try loginSystem.controller().enableByDefaultOnce()
check(loginSystem.registrations == 1, "再次启动不重复注册")
try loginSystem.controller().setEnabled(false)
try loginSystem.controller().enableByDefaultOnce()
check(loginSystem.state == .disabled && loginSystem.removals == 1 && loginSystem.registrations == 1, "菜单关闭后重启仍保持关闭")
try loginSystem.controller().setEnabled(true)
check(loginSystem.state == .enabled && loginSystem.registrations == 2, "菜单可以重新开启自启动")
loginSystem.state = .disabled
try loginSystem.controller().enableByDefaultOnce()
check(loginSystem.state == .disabled && loginSystem.registrations == 2, "尊重系统设置中关闭登录项的选择")

let approvalSystem = FakeLoginItems()
approvalSystem.state = .requiresApproval
try approvalSystem.controller().enableByDefaultOnce()
check(approvalSystem.state == .requiresApproval && approvalSystem.registrations == 0, "等待系统批准时不反复注册")
try approvalSystem.controller().setEnabled(false)
check(approvalSystem.state == .disabled && approvalSystem.removals == 1, "待批准的登录项也可关闭")

let deniedSystem = FakeLoginItems()
deniedSystem.failRegistration = true
check(rejects { try deniedSystem.controller().enableByDefaultOnce() } && deniedSystem.state == .disabled, "注册失败向调用者报告且不伪称已开启")
try deniedSystem.controller().enableByDefaultOnce()
check(deniedSystem.registrations == 1, "默认注册失败后不反复打扰用户")
deniedSystem.failRegistration = false
try deniedSystem.controller().setEnabled(true)
check(deniedSystem.state == .enabled, "注册失败后支持从菜单手动重试")

let existingSystem = FakeLoginItems()
existingSystem.state = .enabled
try existingSystem.controller().enableByDefaultOnce()
check(existingSystem.registrations == 0, "已开启的系统登录项不重复注册")

print("共 \(checks) 项检查通过；测试未调用真实输出切换或修改系统登录项。")
