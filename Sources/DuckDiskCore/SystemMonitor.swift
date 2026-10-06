import Foundation
import Darwin

public struct CPUSample: Sendable {
    /// 0...1 across all cores.
    public var total: Double
    public var user: Double
    public var system: Double
    /// 0...1 per core.
    public var cores: [Double]

    public init(total: Double, user: Double, system: Double, cores: [Double]) {
        self.total = total
        self.user = user
        self.system = system
        self.cores = cores
    }
}

public struct MemorySample: Sendable {
    public var total: Int64
    public var app: Int64
    public var wired: Int64
    public var compressed: Int64
    public var cached: Int64
    public var free: Int64
    public var swapUsed: Int64
    public var swapTotal: Int64
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    public var pressureLevel: Int

    public var used: Int64 { app + wired + compressed }
    public var pressureTitle: String {
        switch pressureLevel {
        case 4: return "Critical"
        case 2: return "Elevated"
        default: return "Normal"
        }
    }
}

public struct ProcessSample: Identifiable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let path: String
    /// Percent of one core (can exceed 100 on multi-threaded processes).
    public let cpu: Double
    public let memory: Int64
}

/// Samples CPU, memory and per-process usage. Keep one instance alive: CPU figures are deltas.
public final class SystemMonitor: @unchecked Sendable {
    private var lastCoreTicks: [[UInt32]] = []
    private var lastProcessTimes: [Int32: (UInt64, Date)] = [:]
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    public init() {}

    public func sampleCPU() -> CPUSample {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUSample(total: 0, user: 0, system: 0, cores: []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for c in 0..<Int(cpuCount) {
            ticks.append((0..<states).map { UInt32(bitPattern: info[c * states + $0]) })
        }
        defer { lastCoreTicks = ticks }
        guard lastCoreTicks.count == ticks.count else {
            return CPUSample(total: 0, user: 0, system: 0, cores: Array(repeating: 0, count: ticks.count))
        }
        var cores: [Double] = []
        var sumUser = 0.0, sumSys = 0.0, sumAll = 0.0
        for (now, before) in zip(ticks, lastCoreTicks) {
            let d = (0..<states).map { Double(now[$0] &- before[$0]) }
            let user = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let sys = d[Int(CPU_STATE_SYSTEM)]
            let all = d.reduce(0, +)
            cores.append(all > 0 ? (user + sys) / all : 0)
            sumUser += user; sumSys += sys; sumAll += all
        }
        return CPUSample(total: sumAll > 0 ? (sumUser + sumSys) / sumAll : 0,
                         user: sumAll > 0 ? sumUser / sumAll : 0,
                         system: sumAll > 0 ? sumSys / sumAll : 0, cores: cores)
    }

    public func sampleMemory() -> MemorySample {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = Int64(vm_kernel_page_size)
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard kr == KERN_SUCCESS else {
            return MemorySample(total: total, app: 0, wired: 0, compressed: 0, cached: 0, free: total,
                                swapUsed: 0, swapTotal: 0, pressureLevel: 1)
        }
        let app = Int64(stats.internal_page_count &- stats.purgeable_count) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        let cached = Int64(stats.external_page_count + stats.purgeable_count) * page
        let free = max(0, total - app - wired - compressed - cached)

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        var pressure: Int32 = 1
        var psize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &psize, nil, 0)
        return MemorySample(total: total, app: app, wired: wired, compressed: compressed, cached: cached,
                            free: free, swapUsed: Int64(swap.xsu_used), swapTotal: Int64(swap.xsu_total),
                            pressureLevel: Int(pressure))
    }

    /// Processes this user can inspect, with CPU since the previous call and physical footprint.
    public func sampleProcesses() -> [ProcessSample] {
        let now = Date()
        var out: [ProcessSample] = []
        var seen: [Int32: (UInt64, Date)] = [:]
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in Self.allPIDs() {
            var usage = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard r == 0 else { continue }
            let cpuTime = usage.ri_user_time + usage.ri_system_time
            seen[pid] = (cpuTime, now)
            var cpu = 0.0
            if let (before, at) = lastProcessTimes[pid] {
                let wall = now.timeIntervalSince(at)
                if wall > 0, cpuTime >= before {
                    cpu = Double(cpuTime - before) * timebase / 1e9 / wall * 100
                }
            }
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = len > 0 ? String(cString: pathBuf) : ""
            let name = Self.displayName(pid: pid, path: path)
            out.append(ProcessSample(pid: pid, name: name, path: path, cpu: cpu,
                                     memory: Int64(usage.ri_phys_footprint)))
        }
        lastProcessTimes = seen
        return out
    }

    static func displayName(pid: Int32, path: String) -> String {
        if let range = path.range(of: ".app/Contents/MacOS/") {
            let appPath = path[..<range.lowerBound]
            let appName = PathFormat.lastComponent(String(appPath))
            let exe = PathFormat.lastComponent(path)
            return exe == appName ? appName : exe
        }
        if !path.isEmpty { return PathFormat.lastComponent(path) }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        return String(cString: name)
    }

    public static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return pids.prefix(Int(max(0, n))).filter { $0 > 0 }
    }
}
