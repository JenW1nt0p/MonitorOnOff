import Foundation

enum L10n {
    // Bundle 按 macOS 首选语言选择 .lproj，也支持系统的单独应用语言设置。
    static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        // 显示器编号和系统错误码是标识符，不按地区插入千位分隔符。
        String(format: text(key), arguments: arguments)
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3" }

    static func snapshot() throws -> [String: String] {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"),
              let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: String] else {
            throw NSError(domain: "MonitorOnOff.Localization", code: 1)
        }
        return Dictionary(uniqueKeysWithValues: keys.keys.map { ($0, text($0)) })
    }
}
