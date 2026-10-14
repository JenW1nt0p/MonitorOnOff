import AppKit
import CoreGraphics
import ServiceManagement

private func displayChanged(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ context: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag), let context else { return }
    let controller = Unmanaged<MenuController>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { controller.scheduleRefresh() }
}

final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var manager: DisplayManager!
    private var timer: Timer?
    private var pendingRefresh: DispatchWorkItem?
    private var busy = false
    private var quitting = false
    private var callbackRegistered = false
    private var lastError: String?
    private let testReportURL: URL?
    private var testReport: [String: Bool] = [:]
    private let loginItems = LoginItems()
    private var loginItemError: String?

    init(testReportURL: URL? = nil) {
        self.testReportURL = testReportURL
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "local.DisplayOutputSwitch"
        if testReportURL == nil && NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "MonitorOnOff")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "MonitorOnOff"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        do {
            let journal = testReportURL.map { RecoveryJournal(url: $0.appendingPathExtension("isolated-state")) } ?? RecoveryJournal()
            manager = try DisplayManager(journal: journal)
        }
        catch { lastError = error.localizedDescription }
        let context = Unmanaged.passUnretained(self).toOpaque()
        callbackRegistered = CGDisplayRegisterReconfigurationCallback(displayChanged, context) == .success
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        rebuildMenu()
        if testReportURL != nil {
            // 原生事件循环测试只读取屏幕和菜单；使用独立记录，不切换真实输出。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.runMenuTest() }
            return
        }
        // 上次异常退出遗留的记录：只恢复本工具关闭的屏幕。
        if let manager, !manager.owned.isEmpty { restoreAll(thenQuit: false) }
        do { try loginItems.enableByDefaultOnce() }
        catch { loginItemError = L10n.format("error.login_enable", error.localizedDescription) }
        rebuildMenu()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if manager == nil || manager.owned.isEmpty { return .terminateNow }
        if busy { return .terminateCancel }
        guard !quitting else { return .terminateLater }
        restoreAll(thenQuit: true)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let testReportURL {
            testReport["terminationReached"] = true
            do {
                let data = try JSONSerialization.data(withJSONObject: testReport, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: testReportURL, options: .atomic)
            } catch { fputs(L10n.format("error.test_report", error.localizedDescription) + "\n", stderr) }
        }
        timer?.invalidate()
        pendingRefresh?.cancel()
        if callbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayChanged, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        rebuildMenu()
    }

    func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func refresh() {
        guard let manager, !busy else { return }
        do { try manager.refresh(); lastError = nil }
        catch { lastError = error.localizedDescription }
        let disabled = manager.displays.filter { !$0.enabled && manager.owned[$0.uuid] != nil }.count
        statusItem?.button?.title = disabled == 0 ? "" : " \(disabled)"
        statusItem?.button?.toolTip = disabled == 0 ? "MonitorOnOff" : L10n.format("status.tooltip_disabled", disabled)
    }

    private func item(_ title: String, action: Selector? = nil, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled && !busy
        return item
    }

    private func runMenuTest() {
        let items = statusItem.menu?.items ?? []
        let displayItems = items.filter { $0.submenu != nil }
        testReport = [
            "statusItemCreated": statusItem != nil,
            "statusButtonVisible": statusItem.button?.window?.isVisible == true,
            "statusIconPresent": statusItem.button?.image != nil,
            "displayMenuMatchesEnumeration": manager != nil && displayItems.count == manager.displays.count,
            "refreshActionPresent": items.contains { $0.action == #selector(refreshAction) && $0.isEnabled },
            "restoreActionPresent": items.contains { $0.action == #selector(restoreAction) },
            "loginItemActionPresent": items.contains { $0.action == #selector(loginItemAction) && $0.isEnabled },
            "loginItemCheckMatchesSystem": items.first { $0.action == #selector(loginItemAction) }?.state == loginCheckState,
            "quitActionPresent": items.contains { $0.action == #selector(quitAction) && $0.isEnabled },
            "builtInProtected": (manager?.displays.filter(\.builtIn) ?? []).allSatisfy { display in
                guard let toggle = displayItems.compactMap({ $0.submenu?.items.first }).first(where: { ($0.representedObject as? String) == display.uuid }) else { return false }
                return toggle.title == L10n.text(display.enabled ? "output.off" : "output.on") && toggle.isEnabled == (!display.enabled && DOSBackendAvailable())
            },
            "localizedMenuMatches": items.contains { $0.action == #selector(quitAction) && $0.title == L10n.text("menu.quit") }
                && items.contains { $0.action == #selector(loginItemAction) && $0.title == L10n.text("menu.login") },
            "localizationLoaded": L10n.text("output.off") != "output.off",
            "noOutputChanges": manager != nil && manager.owned.isEmpty
        ]
        if let testReportURL {
            let menuRows = items.map { item in ["title": item.title, "children": item.submenu?.items.map(\.title) ?? []] as [String: Any] }
            do {
                let snapshot: [String: Any] = ["language": L10n.language, "menus": menuRows, "strings": try L10n.snapshot()]
                try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
                    .write(to: testReportURL.appendingPathExtension("localization.json"), options: .atomic)
            } catch { testReport["localizationLoaded"] = false }
        }
        testReport["quitHandlerCalled"] = true
        quitAction()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        menu.addItem(item("MonitorOnOff", enabled: false))
        menu.addItem(.separator())
        if !DOSBackendAvailable() {
            menu.addItem(item(L10n.text("menu.unsupported"), enabled: false))
        }
        if let error = lastError { menu.addItem(item(error, enabled: false)) }
        if let manager {
            if manager.displays.isEmpty { menu.addItem(item(L10n.text("menu.no_displays"), enabled: false)) }
            for display in manager.displays {
                let suffix = display.builtIn ? L10n.text("display.builtin_suffix") : (display.main ? L10n.text("display.main_suffix") : "")
                let label = item(display.localizedName + suffix)
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                let title = L10n.text(display.enabled ? "output.off" : "output.on")
                let allowed = display.enabled ? DisplayPolicy.canDisable(display, among: manager.displays) : true
                let toggle = item(title, action: #selector(toggleDisplay(_:)), enabled: allowed && DOSBackendAvailable())
                toggle.representedObject = display.uuid
                submenu.addItem(toggle)
                submenu.addItem(item(L10n.text(display.enabled ? "status.on" : "status.off"), enabled: false))
                if display.builtIn {
                    submenu.addItem(item(L10n.text("safety.builtin"), enabled: false))
                } else if display.enabled && !allowed {
                    submenu.addItem(item(L10n.text("safety.last_display"), enabled: false))
                } else if !display.online {
                    submenu.addItem(item(L10n.text("safety.reconnect"), enabled: false))
                }
                label.submenu = submenu
                label.state = display.enabled ? .on : .off
                menu.addItem(label)
            }
            menu.addItem(.separator())
            menu.addItem(item(L10n.text("menu.restore"), action: #selector(restoreAction), enabled: !manager.owned.isEmpty && DOSBackendAvailable()))
        }
        menu.addItem(item(L10n.text("menu.refresh"), action: #selector(refreshAction)))
        menu.addItem(.separator())
        let loginItem = item(L10n.text("menu.login"), action: #selector(loginItemAction))
        loginItem.state = loginCheckState
        menu.addItem(loginItem)
        if loginItems.state == .requiresApproval {
            menu.addItem(item(L10n.text("menu.approve_login"), action: #selector(loginSettingsAction)))
        }
        if let error = loginItemError { menu.addItem(item(error, enabled: false)) }
        menu.addItem(.separator())
        menu.addItem(item(L10n.text("menu.about"), action: #selector(aboutAction)))
        menu.addItem(item(L10n.text("menu.quit"), action: #selector(quitAction), key: "q"))
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard !busy, let uuid = sender.representedObject as? String,
              let display = manager.displays.first(where: { $0.uuid == uuid }) else { return }
        busy = true
        do {
            if display.enabled { try manager.disable(uuid) }
            else { try manager.enable(uuid) }
        } catch {
            busy = false
            showError(error.localizedDescription)
            refresh()
            return
        }
        // 配置提交后，给 WindowServer 和驱动留出更新列表的时间。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.busy = false
            self.refresh()
            if display.enabled {
                if self.manager.displays.first(where: { $0.uuid == uuid })?.enabled == true {
                    self.showError(L10n.text("error.output_still_on"))
                }
            } else {
                if DisplaySystem.isEnabled(DisplaySystem.resolve(display)) {
                    do { try self.manager.enable(uuid) } catch { self.showError(error.localizedDescription) }
                } else {
                    self.showError(L10n.text("error.output_not_restored"))
                }
            }
        }
    }

    private func restoreAll(thenQuit: Bool) {
        guard let manager, !busy else { return }
        busy = true
        quitting = thenQuit
        let errors = manager.restoreAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            // 驱动更新后再确认；保留未能确认的恢复记录。
            var remainingErrors = errors
            for record in Array(manager.owned.values) {
                if DisplaySystem.isEnabled(DisplaySystem.resolve(record)) {
                    do { try manager.enable(record.uuid) }
                    catch { remainingErrors.append(error.localizedDescription) }
                }
            }
            self.busy = false
            self.refresh()
            if manager.owned.isEmpty {
                if thenQuit { NSApp.reply(toApplicationShouldTerminate: true) }
                return
            }
            let names = manager.owned.values.map(\.localizedName).sorted().joined(separator: L10n.text("list.separator"))
            let explanation = L10n.format("restore.incomplete_details", names)
                + (remainingErrors.isEmpty ? "" : "\n\n" + remainingErrors.joined(separator: "\n"))
            if thenQuit {
                let alert = NSAlert()
                alert.messageText = L10n.text("restore.incomplete_title")
                alert.informativeText = explanation
                alert.addButton(withTitle: L10n.text("restore.stay"))
                alert.addButton(withTitle: L10n.text("restore.quit_keep_record"))
                NSApp.activate(ignoringOtherApps: true)
                let shouldQuit = alert.runModal() == .alertSecondButtonReturn
                self.quitting = false
                NSApp.reply(toApplicationShouldTerminate: shouldQuit)
            } else { self.showError(explanation) }
        }
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MonitorOnOff"
        alert.informativeText = text
        alert.addButton(withTitle: L10n.text("button.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func restoreAction() { restoreAll(thenQuit: false) }
    @objc private func refreshAction() { refresh(); rebuildMenu() }
    @objc private func quitAction() { if !busy { NSApp.terminate(nil) } }
    private var loginCheckState: NSControl.StateValue {
        switch loginItems.state {
        case .enabled: return .on
        case .requiresApproval: return .mixed
        case .disabled, .notFound: return .off
        }
    }

    @objc private func loginItemAction() {
        let state = loginItems.state
        do {
            try loginItems.setEnabled(state != .enabled && state != .requiresApproval)
            loginItemError = nil
        } catch {
            loginItemError = L10n.format("error.login_setting", error.localizedDescription)
            showError(loginItemError!)
        }
        rebuildMenu()
    }

    @objc private func loginSettingsAction() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func aboutAction() {
        let alert = NSAlert()
        alert.messageText = "MonitorOnOff \(L10n.version)"
        alert.informativeText = L10n.text("about.details")
        alert.addButton(withTitle: L10n.text("button.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
