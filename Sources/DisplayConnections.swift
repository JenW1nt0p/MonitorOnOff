import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

struct DisplayHardwareIdentity: Codable, Equatable {
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32

    init(displayID: UInt32) {
        vendor = CGDisplayVendorNumber(displayID)
        product = CGDisplayModelNumber(displayID)
        serial = CGDisplaySerialNumber(displayID)
    }

    init?(edid: Data) {
        let bytes = [UInt8](edid)
        guard bytes.count >= 16,
              Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0] else { return nil }
        vendor = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        product = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        serial = (0..<4).reduce(0) { $0 | UInt32(bytes[12 + $1]) << (8 * $1) }
    }

    var isValid: Bool { vendor != 0 && product != 0 }
}

struct DisplayConnection: Equatable {
    let path: String
    let hardware: DisplayHardwareIdentity
}

enum DisplayConnections {
    private static func properties(_ service: io_service_t) -> [String: Any] {
        var result: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &result, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return result?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private static func path(_ service: io_service_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard IORegistryEntryGetPath(service, kIOServicePlane, &buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }

    static func connected() -> [DisplayConnection] {
        var connections: [DisplayConnection] = []
        var modernHardware: [DisplayHardwareIdentity] = []
        // Apple Silicon 的输出关闭不撤销端口 HPD；拔线则变为 Low。
        // 不能用 LinkRate/屏幕 online 区分这两种情况。
        for serviceClass in ["IOPortTransportStateDisplayPort", "IODisplayConnect"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                defer { IOObjectRelease(service) }
                let info: [String: Any]
                if serviceClass == "IOPortTransportStateDisplayPort" {
                    info = properties(service)
                    guard (info["HPD_State"] as? NSNumber)?.intValue == 2 else { continue }
                } else {
                    // Intel 使用当前仍存在的显示器连接服务，缓存信息不作为连接证据。
                    info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] ?? [:]
                }
                guard let edid = (info["EDID"] ?? info[kIODisplayEDIDKey]) as? Data,
                      let hardware = DisplayHardwareIdentity(edid: edid), hardware.isValid,
                      let servicePath = path(service) else { continue }
                if serviceClass == "IODisplayConnect" && modernHardware.contains(hardware) { continue }
                connections.append(DisplayConnection(path: servicePath, hardware: hardware))
                if serviceClass == "IOPortTransportStateDisplayPort" { modernHardware.append(hardware) }
            }
        }
        return connections
    }

    static func matching(_ hardware: DisplayHardwareIdentity, in connections: [DisplayConnection]) -> [DisplayConnection] {
        guard hardware.isValid else { return [] }
        return connections.filter { $0.hardware == hardware }
    }

    static func isConnected(_ record: DisplayRecord) -> Bool {
        let id = DisplaySystem.resolve(record)
        let hardware = record.hardware ?? DisplayHardwareIdentity(displayID: record.id)
        let online = CGDisplayIsOnline(id) != 0
        if record.connectionPath == nil && online {
            return record.uuid.hasPrefix("display-id-") || DisplaySystem.uuid(for: id) == record.uuid
        }
        let matches = matching(hardware, in: connected())
        if let path = record.connectionPath {
            guard matches.contains(where: { $0.path == path }) else { return false }
            return !online || record.uuid.hasPrefix("display-id-") || DisplaySystem.uuid(for: id) == record.uuid
        }
        // 兼容旧记录；设备身份不唯一时不猜测拔掉的是哪一块屏幕。
        return matches.count == 1
    }
}
