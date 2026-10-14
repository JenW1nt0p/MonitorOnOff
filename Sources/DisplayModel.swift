import AppKit
import CoreGraphics

struct DisplayRecord: Codable, Equatable {
    let uuid: String
    var id: UInt32
    var name: String
    var builtIn: Bool
    var enabled: Bool
    var online: Bool
    var main: Bool
    var usesFallbackName: Bool? = nil
    var hardware: DisplayHardwareIdentity? = nil
    var connectionPath: String? = nil

    var localizedName: String {
        guard usesFallbackName == true else { return name }
        return builtIn ? L10n.text("display.builtin_name") : L10n.format("display.external_name", id)
    }
}

enum DisplayPolicy {
    static func canDisable(_ target: DisplayRecord, among displays: [DisplayRecord]) -> Bool {
        // 保护内建屏，并且至少保留一块有输出的屏幕。
        !target.builtIn && target.enabled && displays.contains {
            $0.uuid != target.uuid && $0.enabled && $0.online
        }
    }

    static func merge(_ live: [DisplayRecord], owned: [String: DisplayRecord], connected: (DisplayRecord) -> Bool) -> [DisplayRecord] {
        var merged = Dictionary(live.filter(connected).map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        // 只为仍有物理连接的软件关闭设备补回开启入口。
        for (uuid, record) in owned where merged[uuid] == nil && connected(record) {
            var remembered = record
            remembered.enabled = false
            remembered.online = false
            remembered.main = false
            merged[uuid] = remembered
        }
        return merged.values.sorted {
            if $0.builtIn != $1.builtIn { return $0.builtIn }
            if $0.localizedName != $1.localizedName { return $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}

enum DisplaySystem {
    static func uuid(for id: UInt32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard DOSCopyDisplayUUID(id, &buffer, buffer.count) else { return "display-id-\(id)" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func resolve(_ record: DisplayRecord) -> UInt32 {
        if record.uuid.hasPrefix("display-id-") { return record.id }
        let resolved = record.uuid.withCString { DOSDisplayIDForUUID($0) }
        return resolved == kCGNullDirectDisplay ? record.id : resolved
    }

    static func isEnabled(_ id: UInt32) -> Bool {
        CGDisplayIsOnline(id) != 0 && (CGDisplayIsActive(id) != 0 || CGDisplayIsInMirrorSet(id) != 0 || CGDisplayIsInHWMirrorSet(id) != 0)
    }

    static func enumerate() throws -> [DisplayRecord] {
        var count: UInt32 = 0
        var error = CGGetOnlineDisplayList(0, nil, &count)
        guard error == .success else { throw DisplayFailure(message: L10n.format("error.enumerate", error.rawValue)) }
        // 预留插拔过程的数量变化；CGGetOnlineDisplayList 对容量有明确限制。
        let capacity = max(count + 8, 16)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        error = CGGetOnlineDisplayList(capacity, &ids, &count)
        guard error == .success else { throw DisplayFailure(message: L10n.format("error.enumerate", error.rawValue)) }
        var names: [UInt32: String] = [:]
        let connections = DisplayConnections.connected()
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return ids.prefix(Int(count)).map { id in
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let hardware = DisplayHardwareIdentity(displayID: id)
            let matches = DisplayConnections.matching(hardware, in: connections)
            return DisplayRecord(uuid: uuid(for: id), id: id,
                name: names[id] ?? (builtIn ? L10n.text("display.builtin_name") : L10n.format("display.external_name", id)),
                builtIn: builtIn, enabled: isEnabled(id), online: CGDisplayIsOnline(id) != 0,
                main: CGDisplayIsMain(id) != 0, usesFallbackName: names[id] == nil,
                hardware: hardware, connectionPath: matches.count == 1 ? matches[0].path : nil)
        }
    }
}

struct DisplayFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class RecoveryJournal {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DisplayOutputSwitch/recovery.json")
    }

    func load() throws -> [String: DisplayRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: DisplayRecord].self, from: Data(contentsOf: url))
    }

    func save(_ records: [String: DisplayRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: .atomic)
    }
}

final class DisplayManager {
    private(set) var owned: [String: DisplayRecord] = [:]
    private(set) var displays: [DisplayRecord] = []
    let journal: RecoveryJournal
    let setOutput: (UInt32, Bool) -> DOSResult
    let enumerate: () throws -> [DisplayRecord]
    let resolve: (DisplayRecord) -> UInt32
    let enabled: (UInt32) -> Bool
    let matchesIdentity: (UInt32, DisplayRecord) -> Bool
    let connected: (DisplayRecord) -> Bool

    var connectedOwned: [DisplayRecord] { displays.filter { owned[$0.uuid] != nil } }

    init(journal: RecoveryJournal = RecoveryJournal(),
         setOutput: @escaping (UInt32, Bool) -> DOSResult = { DOSSetDisplayEnabled($0, $1) },
         enumerate: @escaping () throws -> [DisplayRecord] = DisplaySystem.enumerate,
         resolve: @escaping (DisplayRecord) -> UInt32 = DisplaySystem.resolve,
         enabled: @escaping (UInt32) -> Bool = DisplaySystem.isEnabled,
         connected: @escaping (DisplayRecord) -> Bool = DisplayConnections.isConnected,
         matchesIdentity: @escaping (UInt32, DisplayRecord) -> Bool = { id, record in
             CGDisplayIsOnline(id) == 0 || record.uuid.hasPrefix("display-id-") || DisplaySystem.uuid(for: id) == record.uuid
         }) throws {
        self.journal = journal
        self.setOutput = setOutput
        self.enumerate = enumerate
        self.resolve = resolve
        self.enabled = enabled
        self.connected = connected
        self.matchesIdentity = matchesIdentity
        owned = try journal.load()
        try refresh()
    }

    func refresh() throws {
        let previous = Dictionary(displays.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let live = try enumerate().map { record -> DisplayRecord in
            var updated = record
            // CG 在线列表可能晚于端口拔线；沿用已确认的端口路径进行独立检查。
            if updated.connectionPath == nil {
                updated.connectionPath = previous[record.uuid]?.connectionPath ?? owned[record.uuid]?.connectionPath
            }
            return updated
        }
        // 回调可能早于驱动更新；仅在主动恢复并确认输出后移除恢复记录。
        displays = DisplayPolicy.merge(live, owned: owned, connected: connected)
    }

    func disable(_ uuid: String) throws {
        try refresh()
        guard let record = displays.first(where: { $0.uuid == uuid }),
              DisplayPolicy.canDisable(record, among: displays) else {
            throw DisplayFailure(message: L10n.text("error.disable_protected"))
        }
        // 先持久化恢复信息；写入失败时不关闭屏幕。
        var next = owned
        next[uuid] = record
        try journal.save(next)
        owned = next
        let result = setOutput(record.id, false)
        guard result.code == 0 else {
            // 提交失败可能已产生部分变化，保留恢复入口。
            if result.stage != 4 {
                next.removeValue(forKey: uuid)
                try journal.save(next)
                owned = next
            }
            throw failure(result)
        }
        var remembered = record
        remembered.enabled = false
        remembered.online = false
        owned[uuid] = remembered
        displays = DisplayPolicy.merge(displays.filter { $0.uuid != uuid }, owned: owned, connected: connected)
    }

    func enable(_ uuid: String) throws {
        // 菜单打开后仍可能拔线；执行前再枚举，缺席设备不提交配置。
        try refresh()
        guard let record = displays.first(where: { $0.uuid == uuid }), connected(record) else { return }
        let id = resolve(record)
        // UUID 能重新解析时优先使用新 ID；旧 ID 不得指向另一块在线屏幕。
        if !matchesIdentity(id, record) {
            throw DisplayFailure(message: L10n.text("error.identity_changed"))
        }
        if enabled(id) {
            var next = owned
            next.removeValue(forKey: uuid)
            try journal.save(next)
            owned = next
            return
        }
        let result = setOutput(id, true)
        guard result.code == 0 else { throw failure(result) }
        // 部分驱动延迟更新状态，由调用方稍后检查并移除恢复记录。
        if enabled(id) {
            var next = owned
            next.removeValue(forKey: uuid)
            try journal.save(next)
            owned = next
        }
    }

    func restoreAll() -> [String] {
        var errors: [String] = []
        do { try refresh() } catch { return [error.localizedDescription] }
        for record in connectedOwned.sorted(by: { $0.name < $1.name }) {
            do { try enable(record.uuid) }
            catch { errors.append(L10n.format("error.for_display", record.localizedName, error.localizedDescription)) }
        }
        return errors
    }

    private func failure(_ result: DOSResult) -> DisplayFailure {
        let stages = [1: "error.unsupported", 2: "error.begin", 3: "error.set_output", 4: "error.commit"]
        return DisplayFailure(message: L10n.format("error.configure", L10n.text(stages[Int(result.stage)] ?? "error.switch"), result.code))
    }
}
