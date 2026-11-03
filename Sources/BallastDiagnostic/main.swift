import BallastCore
import BallastWindowsKit
import Foundation

// Prints one memory snapshot and the advice for it, then exits, the Windows
// counterpart of `BALLAST_DIAGNOSTIC=1` on the Mac. Exits 1 if Windows would
// not report memory or processes.

let monitor = WindowsMonitor()
guard monitor.refresh(), let sample = monitor.sample else {
    print("FAILED could not read memory")
    exit(1)
}

let vm = sample.vm
print("TOTAL \(vm.totalBytes)")
print("USED \(vm.usedBytes)")
print("APP \(vm.appBytes)")
print("WIRED \(vm.wiredBytes)")
print("COMPRESSED \(vm.compressedBytes)")
print("CACHED \(vm.cachedBytes)")
print("FREE \(vm.freeBytes)")
print("PAGESIZE \(vm.pageSize)")
print("PRESSURE \(sample.pressure.rawValue) \(sample.pressure.label)")
print("PAGEFILE \(sample.swap.used) of \(sample.swap.total)")
print("DISKAVAIL \(sample.disk?.available ?? 0)")
print("PROCS \(sample.processes.count)")
print("READABLE \(sample.processes.filter { $0.memoryBytes > 0 }.count)")
print("WINDOWED \(sample.windowedPids.count)")

for group in monitor.groups.prefix(15) {
    let pids = group.pids.prefix(4).map(String.init).joined(separator: ",")
    let tags = [
        group.isRunningApp ? "app" : nil,
        group.isSystemOwned ? "system" : nil,
        Grouping.isEssential(group) ? "essential" : nil,
    ].compactMap { $0 }.joined(separator: ",")
    print("GROUP \(group.memoryBytes) \(group.processCount) \(pids) [\(tags)] \(group.name)")
}

for advice in monitor.advice {
    print("ADVICE \(advice.severity) \(advice.id) \(advice.headline) · \(advice.detail)")
}

exit(vm.totalBytes > 0 && !sample.processes.isEmpty ? 0 : 1)
