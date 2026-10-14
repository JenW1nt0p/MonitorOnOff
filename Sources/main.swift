import AppKit
import Foundation

if CommandLine.arguments.contains("--localization-diagnostics") {
    do {
        let snapshot: [String: Any] = [
            "language": L10n.language,
            "strings": try L10n.snapshot(),
            "samples": [
                "status.tooltip_disabled": L10n.format("status.tooltip_disabled", 2),
                "display.external_name": L10n.format("display.external_name", UInt32(42)),
                "error.enumerate": L10n.format("error.enumerate", Int32(1000)),
                "error.configure": L10n.format("error.configure", L10n.text("error.commit"), Int32(1000)),
                "error.for_display": L10n.format("error.for_display", "Sample Display", "Sample Error"),
                "restore.incomplete_details": L10n.format("restore.incomplete_details", "Sample Display")
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--quit-running") {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.DisplayOutputSwitch")
        .filter { $0.processIdentifier != getpid() }
    guard running.allSatisfy({ $0.terminate() }) else {
        fputs(L10n.text("cli.quit_busy") + "\n", stderr)
        exit(1)
    }
    let deadline = Date().addingTimeInterval(10)
    while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard running.allSatisfy({ $0.isTerminated }) else {
        fputs(L10n.text("cli.quit_wait") + "\n", stderr)
        exit(1)
    }
} else if let index = CommandLine.arguments.firstIndex(of: "--login-item"), index + 1 < CommandLine.arguments.count {
    let choice = CommandLine.arguments[index + 1]
    guard choice == "enable" || choice == "disable" else {
        fputs(L10n.text("cli.login_usage") + "\n", stderr)
        exit(1)
    }
    do {
        try LoginItems().setEnabled(choice == "enable")
        print(LoginItemState.systemState.rawValue)
    } catch {
        fputs(L10n.format("error.login_setting", error.localizedDescription) + "\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--diagnostics") {
    do {
        let displays = try DisplaySystem.enumerate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Diagnostics: Codable {
            let backendAvailable: Bool
            let loginItemStatus: String
            let language: String
            let displays: [DisplayRecord]
        }
        let result = Diagnostics(backendAvailable: DOSBackendAvailable(), loginItemStatus: LoginItemState.systemState.rawValue, language: L10n.language, displays: displays)
        print(String(data: try encoder.encode(result), encoding: .utf8)!)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else {
    let app = NSApplication.shared
    var testReportURL: URL?
    if let index = CommandLine.arguments.firstIndex(of: "--ui-test"), index + 1 < CommandLine.arguments.count {
        testReportURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    let controller = MenuController(testReportURL: testReportURL)
    app.delegate = controller
    app.run()
}
