import Foundation
import IOKit

// Mirrors the kernel's SMCKeyData_t (80 bytes). `padding` makes up for
// SMCKeyInfo's trailing alignment, which Swift doesn't add inside a struct.
struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuLimit: UInt32 = 0
    var gpuLimit: UInt32 = 0
    var memoryLimit: UInt32 = 0
}

struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParams {
    var key: UInt32 = 0
    var version = SMCVersion()
    var limitData = SMCLimitData()
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMC {
    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    private func call(_ input: inout SMCParams) -> SMCParams? {
        var output = SMCParams()
        var outputSize = MemoryLayout<SMCParams>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParams>.stride, &output, &outputSize)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    func keyCount() -> Int {
        guard let bytes = read("#KEY")?.bytes, bytes.count >= 4 else { return 0 }
        return Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
    }

    func key(at index: Int) -> String? {
        var input = SMCParams()
        input.command = 8
        input.data32 = UInt32(index)
        return call(&input).map { fourCC($0.key) }
    }

    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        var input = SMCParams()
        input.key = fourCC(key)
        input.command = 9
        guard let info = call(&input)?.keyInfo else { return nil }

        input.keyInfo.dataSize = info.dataSize
        input.command = 5
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return (fourCC(info.dataType), bytes)
    }

    // Apple Silicon reports temperatures and fan speeds as little-endian floats.
    func float(_ key: String) -> Double? {
        guard let value = read(key), value.type == "flt ", value.bytes.count == 4 else { return nil }
        return Double(value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
    }
}

struct Fan {
    var rpm: Double
    var maxRPM: Double
}

struct SensorReadings {
    var cpuAverage: Double?
    var cpuHottest: Double?
    var gpuAverage: Double?
    var fans: [Fan]
}

final class Sensors {
    private let smc: SMC
    private let cpuKeys: [String]
    private let gpuKeys: [String]
    let fanCount: Int

    // Sensor key names vary by chip, so they're found once by prefix rather
    // than hardcoded. On M1 and M2, Tp and Te are the performance and
    // efficiency cores and Tg is the GPU.
    init?() {
        guard let smc = SMC() else { return nil }
        var cpuKeys: [String] = []
        var gpuKeys: [String] = []
        for index in 0..<smc.keyCount() {
            guard let key = smc.key(at: index), key.hasPrefix("T"), smc.float(key) != nil else { continue }
            if key.hasPrefix("Tp") || key.hasPrefix("Te") {
                cpuKeys.append(key)
            } else if key.hasPrefix("Tg") {
                gpuKeys.append(key)
            }
        }
        self.smc = smc
        self.cpuKeys = cpuKeys
        self.gpuKeys = gpuKeys
        fanCount = Int(smc.read("FNum")?.bytes.first ?? 0)
    }

    func read() -> SensorReadings {
        let cpu = cpuKeys.compactMap(temperature)
        let gpu = gpuKeys.compactMap(temperature)
        let fans = (0..<fanCount).compactMap { index -> Fan? in
            guard let rpm = smc.float("F\(index)Ac"), let maxRPM = smc.float("F\(index)Mx") else { return nil }
            return Fan(rpm: rpm, maxRPM: maxRPM)
        }
        return SensorReadings(cpuAverage: average(cpu), cpuHottest: cpu.max(), gpuAverage: average(gpu), fans: fans)
    }

    // Idle or powered-down sensors read 0.
    private func temperature(_ key: String) -> Double? {
        guard let value = smc.float(key), value > 0, value < 150 else { return nil }
        return value
    }
}

private func average(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
}

private func fourCC(_ string: String) -> UInt32 {
    string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}

private func fourCC(_ value: UInt32) -> String {
    String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, as: UTF8.self)
}
