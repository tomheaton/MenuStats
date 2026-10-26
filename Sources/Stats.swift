import Darwin
import Foundation

private let host = mach_host_self()

struct CPUTicks {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

struct CPUUsage {
    var user: Double
    var system: Double
    var total: Double { user + system }
}

func readCPUTicks() -> CPUTicks? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let ticks = info.cpu_ticks
    return CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
}

// Tick counters are 32-bit and wrap, so subtract with overflow.
func cpuUsage(from old: CPUTicks, to new: CPUTicks) -> CPUUsage {
    let user = Double((new.user &- old.user) &+ (new.nice &- old.nice))
    let system = Double(new.system &- old.system)
    let idle = Double(new.idle &- old.idle)
    let total = user + system + idle
    guard total > 0 else { return CPUUsage(user: 0, system: 0) }
    return CPUUsage(user: user / total, system: system / total)
}

struct MemoryStats {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: MemoryPressure

    // Matches Activity Monitor's "Memory Used".
    var used: UInt64 { app + wired + compressed }
}

enum MemoryPressure: String {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"
}

func readMemory() -> MemoryStats? {
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }

    var pageSize: vm_size_t = 0
    host_page_size(host, &pageSize)
    let page = UInt64(pageSize)

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

    var level: Int32 = 1
    var levelSize = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
    let pressure: MemoryPressure = switch level {
    case 4: .critical
    case 2: .warning
    default: .normal
    }

    let purgeable = UInt64(info.purgeable_count)
    return MemoryStats(
        total: ProcessInfo.processInfo.physicalMemory,
        app: (UInt64(info.internal_page_count) - purgeable) * page,
        wired: UInt64(info.wire_count) * page,
        compressed: UInt64(info.compressor_page_count) * page,
        cached: (UInt64(info.external_page_count) + purgeable) * page,
        swapUsed: swap.xsu_used,
        swapTotal: swap.xsu_total,
        pressure: pressure
    )
}

struct AppMemory {
    var name: String
    var bytes: UInt64
    var processes: Int
}

// Sums each process's physical footprint under the outermost .app bundle in
// its path, so helpers count towards their app. Processes owned by other users
// can't be read without root and are skipped.
func topAppsByMemory(limit: Int) -> [AppMemory] {
    let capacity = Int(proc_listallpids(nil, 0)) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
    guard found > 0 else { return [] }

    var totals: [String: AppMemory] = [:]
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    for pid in pids.prefix(found) where pid > 0 {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard ok == 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }

        let name = appName(forExecutable: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        var entry = totals[name] ?? AppMemory(name: name, bytes: 0, processes: 0)
        entry.bytes += usage.ri_phys_footprint
        entry.processes += 1
        totals[name] = entry
    }
    return Array(totals.values.sorted { $0.bytes > $1.bytes }.prefix(limit))
}

private func appName(forExecutable path: String) -> String {
    if let bundleEnd = path.range(of: ".app/") {
        return (String(path[..<bundleEnd.lowerBound]) as NSString).lastPathComponent
    }
    return (path as NSString).lastPathComponent
}
