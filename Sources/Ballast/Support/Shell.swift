import Foundation

nonisolated enum Shell {
    /// Runs a tool and returns stdout, or nil if it could not be launched or
    /// outlived `timeout`. Reads to end of file rather than polling, so a large
    /// listing cannot fill the pipe and deadlock.
    nonisolated static func run(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval = 120
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard !watchdog.isCancelled || process.terminationStatus == 0 || !data.isEmpty else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
