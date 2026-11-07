import Foundation
import IOKit.ps

/// Los datos del Mac que el panel muestra en Ajustes. Todo de APIs públicas y
/// barato de leer, porque esto viaja en cada estado.
enum SystemInfo {

    /// Lo que no cambia en toda la sesión se lee una sola vez.
    private static let staticFacts: [String: Any] = {
        var facts: [String: Any] = [:]
        facts["chip"] = sysctl("machdep.cpu.brand_string") ?? sysctl("hw.model") ?? "Mac"
        facts["model"] = sysctl("hw.model") ?? ""
        facts["host"] = Host.current().localizedName ?? ""

        let version = ProcessInfo.processInfo.operatingSystemVersion
        facts["macos"] = version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"

        let bytes = ProcessInfo.processInfo.physicalMemory
        facts["memory"] = "\(bytes / 1_073_741_824) GB"
        facts["cores"] = ProcessInfo.processInfo.processorCount
        return facts
    }()

    static func snapshot() -> [String: Any] {
        var payload = staticFacts
        payload["uptime"] = Int(ProcessInfo.processInfo.systemUptime)
        if let battery = battery() {
            payload["battery"] = battery
        }
        return payload
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` en un Mac de sobremesa, que es justo lo que queremos: así el
    /// panel no enseña una fila de batería vacía en un Mac mini.
    private static func battery() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            var battery: [String: Any] = [
                "percent": Int((Double(current) / Double(max) * 100).rounded()),
                "charging": (info[kIOPSIsChargingKey] as? Bool) ?? false,
                "plugged": (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
            ]
            // El sistema devuelve -1 mientras recalcula la estimación.
            if let minutes = info[kIOPSTimeToEmptyKey] as? Int, minutes > 0 {
                battery["minutes"] = minutes
            }
            return battery
        }
        return nil
    }
}
