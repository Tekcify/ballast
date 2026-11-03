import Foundation
import Testing
@testable import BallastCore
@testable import BallastWindowsKit

@MainActor
struct WindowsProbeTests {
    @Test func pressureFollowsMemoryLoadAndCommit() {
        #expect(Probes.windowsPressure(memoryLoad: 60, commitRatio: 0.5) == .normal)
        #expect(Probes.windowsPressure(memoryLoad: 85, commitRatio: 0.5) == .warning)
        #expect(Probes.windowsPressure(memoryLoad: 60, commitRatio: 0.9) == .warning)
        #expect(Probes.windowsPressure(memoryLoad: 96, commitRatio: 0.5) == .critical)
        #expect(Probes.windowsPressure(memoryLoad: 60, commitRatio: 0.97) == .critical)
    }

    @Test func fileTimesConvertToUnixDates() {
        // 1 January 1970 in FILETIME ticks.
        #expect(Probes.date(fromFileTime: 116_444_736_000_000_000) == Date(timeIntervalSince1970: 0))
        #expect(Probes.date(fromFileTime: 0) == nil)
    }

    @Test func exeNamesLoseTheirFolderAndExtension() {
        #expect(Probes.exeBaseName("chrome.exe") == "chrome")
        #expect(Probes.exeBaseName("C:\\Program Files\\Microsoft VS Code\\Code.EXE") == "Code")
        #expect(Probes.exeBaseName("Memory Compression") == "Memory Compression")
    }

    @Test func wideStringsRoundTripThroughFixedBuffers() {
        var buffer: (UInt16, UInt16, UInt16, UInt16) = (9, 9, 9, 9)
        writeWide("Ballast", to: &buffer)
        #expect(readWide(buffer) == "Bal")
        #expect("hi".wide == [104, 105, 0])
    }

    @Test func systemAndEssentialProcessesAreNeverSuggested() {
        func group(_ name: String, path: String?, system: Bool) -> AppGroup {
            AppGroup(
                id: path ?? name, name: name, bundleIdentifier: nil, bundlePath: path,
                projectPath: nil, pids: [1], memoryBytes: 1 << 30, cpuPercent: 0,
                isApproximate: false, isSystemOwned: system, isRunningApp: true,
                isFrontmost: false, isHidden: false, startedAt: Date()
            )
        }
        #expect(Grouping.isEssential(group("Windows Explorer", path: "C:\\Windows\\explorer.exe", system: true)))
        #expect(Grouping.isEssential(group("Desktop Window Manager", path: "C:\\Windows\\System32\\dwm.exe", system: true)))
        #expect(!Grouping.isEssential(group("Google Chrome", path: "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", system: false)))
    }

    @Test func liveSampleReadsThisMachine() throws {
        let sample = try #require(Probes.windowsSample())
        #expect(sample.vm.totalBytes > 0)
        #expect(sample.vm.usedBytes <= sample.vm.totalBytes)
        let me = pid_t(ProcessInfo.processInfo.processIdentifier)
        let current = try #require(sample.processes.first { $0.pid == me })
        #expect(current.memoryBytes > 0)
        #expect(current.path != nil)
    }
}
