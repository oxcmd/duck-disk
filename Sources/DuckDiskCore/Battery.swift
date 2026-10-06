import Foundation
import IOKit
import IOKit.ps

public struct BatteryStatus: Sendable {
    /// 0...100
    public var percent: Int
    public var isCharging: Bool
    public var onAC: Bool
    /// Minutes, nil while macOS is still estimating.
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var cycleCount: Int?
    /// Full-charge capacity as a share of design capacity, 0...100.
    public var healthPercent: Int?
    public var condition: String?
    public var temperatureC: Double?
    public var adapterWatts: Int?
}

public enum Battery {
    /// nil on Macs without a battery.
    public static func read() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let toEmpty = desc[kIOPSTimeToEmptyKey] as? Int
            let toFull = desc[kIOPSTimeToFullChargeKey] as? Int
            var status = BatteryStatus(
                percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesToEmpty: (toEmpty ?? -1) > 0 ? toEmpty : nil,
                minutesToFull: (toFull ?? -1) > 0 ? toFull : nil,
                condition: desc["BatteryHealth"] as? String)
            readSmartBattery(into: &status)
            return status
        }
        return nil
    }

    /// Cycle count, health and temperature from the AppleSmartBattery registry entry.
    static func readSmartBattery(into status: inout BatteryStatus) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }
        status.cycleCount = dict["CycleCount"] as? Int
        let design = dict["DesignCapacity"] as? Int ?? 0
        let full = dict["NominalChargeCapacity"] as? Int ?? dict["AppleRawMaxCapacity"] as? Int ?? 0
        if design > 0 && full > 0 { status.healthPercent = min(100, Int(Double(full) / Double(design) * 100)) }
        if let t = dict["Temperature"] as? Int { status.temperatureC = Double(t) / 100 }
        if let adapter = dict["AdapterDetails"] as? [String: Any], let w = adapter["Watts"] as? Int, w > 0 {
            status.adapterWatts = w
        }
    }
}
