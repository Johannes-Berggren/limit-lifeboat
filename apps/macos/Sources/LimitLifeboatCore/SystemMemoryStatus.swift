import Darwin
import Foundation

public enum MemoryPressureLevel: String, Sendable, Equatable {
    case normal
    case warning
    case critical
}

public struct SystemMemoryStatus: Equatable, Sendable {
    public let totalBytes: UInt64
    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    public let usedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: MemoryPressureLevel

    public var availableBytes: UInt64 {
        totalBytes > usedBytes ? totalBytes - usedBytes : 0
    }

    /// Share of physical memory in use, 0...1.
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }

    public init(totalBytes: UInt64, usedBytes: UInt64, swapUsedBytes: UInt64, pressure: MemoryPressureLevel) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }
}

public struct SystemMemoryReader: Sendable {
    public init() {}

    public func read() -> SystemMemoryStatus? {
        let total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        // mach_host_self() returns a new send right on every call; an
        // always-running app polling this must give it back.
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appMemory = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let used = appMemory
            + UInt64(stats.wire_count) * page
            + UInt64(stats.compressor_page_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0

        return SystemMemoryStatus(
            totalBytes: total,
            usedBytes: min(used, total),
            swapUsedBytes: swapUsed,
            pressure: pressureLevel()
        )
    }

    /// The kernel's own verdict, the same signal behind Activity Monitor's
    /// memory-pressure graph: 1 normal, 2 warning, 4 critical.
    private func pressureLevel() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        switch level {
        case 4:
            return .critical
        case 2:
            return .warning
        default:
            return .normal
        }
    }
}
