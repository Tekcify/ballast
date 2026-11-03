import BallastCore
import Foundation
import WinSDK

/// One process as Windows reports it.
package nonisolated struct WindowsProcess: Sendable {
    package var pid: pid_t
    package var parentPid: pid_t
    /// Exe name without `.exe`, such as `chrome`.
    package var name: String
    /// Full image path, or nil when Windows will not tell us (protected and
    /// system processes).
    package var path: String?
    /// Roughly Task Manager's Memory column: the smaller of the private bytes
    /// and the working set, which approximates the private working set.
    package var memoryBytes: UInt64
    /// Cumulative kernel plus user CPU time, in nanoseconds.
    package var cpuNanos: UInt64?
    package var startedAt: Date?
    /// Services run in session 0, apart from anything a person signed in to.
    package var isService = false
}

/// Everything one refresh reads from Windows.
package nonisolated struct WindowsSample: Sendable {
    package var vm: Probes.VMSample
    package var swap: Probes.SwapSample
    package var pressure: Probes.Pressure
    package var disk: Probes.DiskSample?
    package var processes: [WindowsProcess]
    /// Processes that own a visible top-level window.
    package var windowedPids: Set<pid_t>
    /// Processes with at least one visible window that is not minimised.
    package var restoredPids: Set<pid_t>
    package var frontmostPid: pid_t?
    package var at: Date
}

/// Windows has no kernel "memory pressure" level like macOS, so Ballast derives
/// one from how full physical memory and the commit limit are.
nonisolated extension Probes {
    package static func windowsPressure(memoryLoad: UInt32, commitRatio: Double) -> Pressure {
        if memoryLoad >= 95 || commitRatio >= 0.95 { return .critical }
        if memoryLoad >= 85 || commitRatio >= 0.85 { return .warning }
        return .normal
    }

    /// Reads memory, page file, disk, processes and windows in one go.
    package static func windowsSample() -> WindowsSample? {
        var status = MEMORYSTATUSEX()
        status.dwLength = DWORD(MemoryLayout<MEMORYSTATUSEX>.size)
        guard GlobalMemoryStatusEx(&status) else { return nil }

        var performance = PERFORMANCE_INFORMATION()
        let performanceSize = DWORD(MemoryLayout<PERFORMANCE_INFORMATION>.size)
        performance.cb = performanceSize
        guard K32GetPerformanceInfo(&performance, performanceSize) else { return nil }

        let page = UInt64(performance.PageSize)
        let total = UInt64(performance.PhysicalTotal) * page
        let available = UInt64(performance.PhysicalAvailable) * page
        let commit = UInt64(performance.CommitTotal) * page
        let commitLimit = UInt64(performance.CommitLimit) * page

        let processes = processList()
        // The "Memory Compression" process holds the compressed store.
        let compressed = processes.first { $0.name == "Memory Compression" }?.memoryBytes ?? 0
        let wired = UInt64(performance.KernelNonpaged) * page
        let used = total > available ? total - available : 0
        let app = used > wired + compressed ? used - wired - compressed : 0

        let vm = VMSample(
            pageSize: page,
            totalBytes: total,
            wiredBytes: wired,
            compressedBytes: compressed,
            appBytes: app,
            cachedBytes: UInt64(performance.SystemCache) * page,
            freeBytes: available,
            pageInsBytes: 0,
            pageOutsBytes: 0
        )

        // Windows backs commit beyond physical memory with the page file, so
        // that overflow is the closest match to macOS swap.
        let pageFile = commitLimit > total ? commitLimit - total : 0
        let swap = SwapSample(
            total: pageFile,
            used: min(commit > total ? commit - total : 0, pageFile),
            encrypted: false
        )

        let ratio = commitLimit > 0 ? Double(commit) / Double(commitLimit) : 0
        let windows = windowCensus()

        return WindowsSample(
            vm: vm,
            swap: swap,
            pressure: windowsPressure(memoryLoad: UInt32(status.dwMemoryLoad), commitRatio: ratio),
            disk: windowsDisk(),
            processes: processes,
            windowedPids: windows.windowed,
            restoredPids: windows.restored,
            frontmostPid: frontmostPid(),
            at: Date()
        )
    }

    // MARK: Disk

    /// Free space on the drive holding the user's profile.
    package static func windowsDisk() -> DiskSample? {
        let profile = ProcessInfo.processInfo.environment["USERPROFILE"] ?? "C:\\"
        let root = String(profile.prefix(3))
        var free = ULARGE_INTEGER()
        var total = ULARGE_INTEGER()
        var totalFree = ULARGE_INTEGER()
        guard GetDiskFreeSpaceExW(root.wide, &free, &total, &totalFree) else { return nil }
        return DiskSample(total: UInt64(total.QuadPart), available: UInt64(free.QuadPart))
    }

    // MARK: Processes

    package static func processList() -> [WindowsProcess] {
        guard let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0),
              snapshot != invalidHandleValue
        else { return [] }
        defer { CloseHandle(snapshot) }

        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        guard Process32FirstW(snapshot, &entry) else { return [] }

        var out: [WindowsProcess] = []
        repeat {
            if entry.th32ProcessID != 0 {
                out.append(read(
                    pid: entry.th32ProcessID,
                    parent: entry.th32ParentProcessID,
                    exeFile: readWide(entry.szExeFile)
                ))
            }
        } while Process32NextW(snapshot, &entry)
        return out
    }

    private static func read(pid: DWORD, parent: DWORD, exeFile: String) -> WindowsProcess {
        var process = WindowsProcess(
            pid: pid_t(bitPattern: pid),
            parentPid: pid_t(bitPattern: parent),
            name: exeBaseName(exeFile),
            path: nil,
            memoryBytes: 0,
            cpuNanos: nil,
            startedAt: nil
        )
        var session: DWORD = 0
        if ProcessIdToSessionId(pid, &session) { process.isService = session == 0 }

        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else {
            return process
        }
        defer { CloseHandle(handle) }

        process.path = imagePath(handle)

        var counters = PROCESS_MEMORY_COUNTERS_EX()
        let size = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS_EX>.size)
        counters.cb = size
        let readMemory = withUnsafeMutablePointer(to: &counters) { pointer in
            pointer.withMemoryRebound(to: PROCESS_MEMORY_COUNTERS.self, capacity: 1) {
                K32GetProcessMemoryInfo(handle, $0, size)
            }
        }
        if readMemory {
            let workingSet = UInt64(counters.WorkingSetSize)
            let privateBytes = UInt64(counters.PrivateUsage)
            process.memoryBytes = process.name == "Memory Compression"
                ? workingSet
                : min(workingSet, privateBytes)
        }

        var created = FILETIME()
        var exited = FILETIME()
        var kernel = FILETIME()
        var user = FILETIME()
        if GetProcessTimes(handle, &created, &exited, &kernel, &user) {
            process.cpuNanos = (ticks(kernel) + ticks(user)) * 100
            process.startedAt = date(fromFileTime: ticks(created))
        }
        return process
    }

    package static func imagePath(_ handle: HANDLE) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 1024)
        var size = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(handle, 0, &buffer, &size) else { return nil }
        return String(decoding: buffer[0..<Int(size)], as: UTF16.self)
    }

    /// `chrome.exe` or `C:\Program Files\...\chrome.exe` becomes `chrome`.
    package static func exeBaseName(_ file: String) -> String {
        let last = file.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? file
        return last.lowercased().hasSuffix(".exe") ? String(last.dropLast(4)) : last
    }

    // MARK: Time

    package static func ticks(_ time: FILETIME) -> UInt64 {
        UInt64(time.dwHighDateTime) << 32 | UInt64(time.dwLowDateTime)
    }

    /// FILETIME counts 100 ns ticks since 1601; Unix time starts in 1970.
    package static func date(fromFileTime ticks: UInt64) -> Date? {
        guard ticks > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
    }

    // MARK: Windows on screen

    private nonisolated final class WindowCensus {
        var windowed: Set<pid_t> = []
        var restored: Set<pid_t> = []
    }

    /// Which processes own visible top-level windows, and which of those have
    /// one that is not minimised.
    package static func windowCensus() -> (windowed: Set<pid_t>, restored: Set<pid_t>) {
        let census = WindowCensus()
        withExtendedLifetime(census) {
            let context = LPARAM(Int(bitPattern: Unmanaged.passUnretained(census).toOpaque()))
            EnumWindows({ hwnd, context in
                guard let hwnd, let raw = UnsafeRawPointer(bitPattern: Int(context)) else { return true }
                let census = Unmanaged<WindowCensus>.fromOpaque(raw).takeUnretainedValue()
                guard IsWindowVisible(hwnd), GetWindow(hwnd, UINT(GW_OWNER)) == nil else { return true }
                var pid: DWORD = 0
                GetWindowThreadProcessId(hwnd, &pid)
                census.windowed.insert(pid_t(bitPattern: pid))
                if !IsIconic(hwnd) { census.restored.insert(pid_t(bitPattern: pid)) }
                return true
            }, context)
        }
        return (census.windowed, census.restored)
    }

    package static func frontmostPid() -> pid_t? {
        guard let window = GetForegroundWindow() else { return nil }
        var pid: DWORD = 0
        GetWindowThreadProcessId(window, &pid)
        return pid == 0 ? nil : pid_t(bitPattern: pid)
    }

    // MARK: Names

    /// The exe's own description, such as "Google Chrome" for `chrome.exe`.
    package static func fileDescription(of path: String) -> String? {
        let widePath = path.wide
        var ignored: DWORD = 0
        let size = GetFileVersionInfoSizeW(widePath, &ignored)
        guard size > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: Int(size))
        guard GetFileVersionInfoW(widePath, 0, size, &data) else { return nil }

        var pointer: UnsafeMutableRawPointer?
        var length: UINT = 0
        guard VerQueryValueW(data, "\\VarFileInfo\\Translation".wide, &pointer, &length),
              let translation = pointer, length >= 4
        else { return nil }
        let language = translation.load(as: UInt16.self)
        let codePage = translation.load(fromByteOffset: 2, as: UInt16.self)

        for field in ["FileDescription", "ProductName"] {
            let key = "\\StringFileInfo\\" + hex4(language) + hex4(codePage) + "\\" + field
            var value: UnsafeMutableRawPointer?
            var count: UINT = 0
            guard VerQueryValueW(data, key.wide, &value, &count), let value, count > 1 else { continue }
            let text = String(decodingCString: value.assumingMemoryBound(to: WCHAR.self), as: UTF16.self)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private static func hex4(_ value: UInt16) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    package static func windowsDirectory() -> String? {
        var buffer = [WCHAR](repeating: 0, count: 512)
        let length = GetWindowsDirectoryW(&buffer, UINT(buffer.count))
        guard length > 0, Int(length) < buffer.count else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF16.self)
    }
}
