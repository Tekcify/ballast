import BallastCore
import Foundation
import Darwin

/// Thin wrappers over the Mach and libproc calls the monitor depends on.
/// All of these are safe to call from a background thread. The sample types
/// they return live in BallastCore, so other platforms can produce them too.
nonisolated extension Probes {
    // MARK: Virtual memory

    nonisolated static func vmSample() -> VMSample? {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, raw, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }

        var page: vm_size_t = 0
        guard host_page_size(mach_host_self(), &page) == KERN_SUCCESS else { return nil }
        let ps = UInt64(page)

        let purgeable = UInt64(stats.purgeable_count)
        let external = UInt64(stats.external_page_count)
        let internalPages = UInt64(stats.internal_page_count)

        return VMSample(
            pageSize: ps,
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            wiredBytes: UInt64(stats.wire_count) * ps,
            compressedBytes: UInt64(stats.compressor_page_count) * ps,
            appBytes: internalPages.subtractingReportingOverflow(purgeable).partialValue * ps,
            cachedBytes: (external + purgeable) * ps,
            freeBytes: UInt64(stats.free_count + stats.speculative_count) * ps,
            pageInsBytes: UInt64(stats.pageins) * ps,
            pageOutsBytes: UInt64(stats.pageouts) * ps
        )
    }

    nonisolated static func swapSample() -> SwapSample? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapSample(total: usage.xsu_total, used: usage.xsu_used, encrypted: usage.xsu_encrypted != 0)
    }

    nonisolated static func pressure() -> Pressure {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return .normal
        }
        return Pressure(rawValue: Int(value)) ?? .normal
    }

    // MARK: Processes

    nonisolated struct RawProcess: Sendable {
        var pid: pid_t
        var ppid: pid_t
        var uid: uid_t
        var name: String
        var execPath: String?
        /// `phys_footprint` where readable, otherwise resident size from `ps`.
        var memoryBytes: UInt64
        /// True when the figure is a resident-size fallback rather than a footprint.
        var memoryIsApproximate: Bool
        /// Cumulative CPU nanoseconds, or nil when not readable.
        var cpuNanos: UInt64?
        var startedAt: Date
    }

    nonisolated static func processList() -> [RawProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = size / stride + 64
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * stride
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }

        let count = min(size / stride, capacity)
        let fallback = residentSizeFallback()
        var out: [RawProcess] = []
        out.reserveCapacity(count)

        for index in 0..<count {
            let entry = buffer[index]
            let pid = entry.kp_proc.p_pid
            guard pid > 0 else { continue }

            let comm = withUnsafePointer(to: entry.kp_proc.p_comm) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            let path = execPath(pid)
            let usage = resourceUsage(pid)
            let seconds = TimeInterval(entry.kp_proc.p_un.__p_starttime.tv_sec)
            let micros = TimeInterval(entry.kp_proc.p_un.__p_starttime.tv_usec) / 1_000_000

            out.append(RawProcess(
                pid: pid,
                ppid: entry.kp_eproc.e_ppid,
                uid: entry.kp_eproc.e_ucred.cr_uid,
                name: path.map { ($0 as NSString).lastPathComponent } ?? comm,
                execPath: path,
                memoryBytes: usage?.footprint ?? fallback[pid] ?? 0,
                memoryIsApproximate: usage == nil,
                cpuNanos: usage.map { $0.userNanos + $0.systemNanos },
                startedAt: Date(timeIntervalSince1970: seconds + micros)
            ))
        }
        return out
    }

    nonisolated static func execPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    private struct Usage {
        var footprint: UInt64
        var userNanos: UInt64
        var systemNanos: UInt64
    }

    /// `rusage_info_t` is declared `void *`, but the call expects the address of the
    /// struct itself rather than a pointer to a pointer. Rebinding keeps that honest.
    private nonisolated static func resourceUsage(_ pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let slots = MemoryLayout<rusage_info_v4>.size / MemoryLayout<rusage_info_t?>.size
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: slots) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0, info.ri_phys_footprint > 0 else { return nil }
        return Usage(
            footprint: info.ri_phys_footprint,
            userNanos: info.ri_user_time,
            systemNanos: info.ri_system_time
        )
    }

    /// Root-owned processes refuse `proc_pid_rusage` without elevated privileges.
    /// One `ps` call per refresh fills those gaps with resident size.
    private nonisolated static func residentSizeFallback() -> [pid_t: UInt64] {
        guard let output = Shell.run("/bin/ps", ["-axo", "pid=,rss="]) else { return [:] }
        var map: [pid_t: UInt64] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = pid_t(parts[0]), let kb = UInt64(parts[1]) else { continue }
            map[pid] = kb * 1024
        }
        return map
    }

    /// Working directory of a process. Used to tell a live dev server's cache
    /// apart from an abandoned one before offering it for deletion.
    nonisolated static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size) }
        guard rc > 0 else { return nil }
        let path = withUnsafePointer(to: info.pvi_cdir.vip_path) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }

    /// Working directory of every readable process under `home`, used to protect
    /// a cache that a live dev server is still writing to.
    nonisolated static func liveWorkingDirectories(home: String) -> [String: String] {
        var map: [String: String] = [:]
        for process in processList() {
            guard let cwd = workingDirectory(process.pid), cwd.hasPrefix(home) else { continue }
            map[cwd] = process.name
        }
        return map
    }

    /// The process working inside `projectRoot`, if any.
    nonisolated static func holder(of projectRoot: String, in live: [String: String]) -> String? {
        live.first { $0.key == projectRoot || $0.key.hasPrefix(projectRoot + "/") }?.value
    }

    // MARK: Disk

    nonisolated static func diskSample(at url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> DiskSample? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskSample(total: UInt64(total), available: UInt64(max(available, 0)))
    }
}
