import Foundation
import OSLog

/// A small rolling log in the App Group (Library/Diagnostics/extension.log), for failures that only happen
/// on one device or one network: it can be copied off a device with Xcode's device tools, where the system
/// log can't be read. Lines carry timings, item IDs and errors, never file names or paths.
public enum DiagnosticLog {
    private static let lock = NSLock()
    private static let limit = 1 << 20

    private static let file: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: FaNGKit.appGroupIdentifier)?
        .appending(path: "Library/Diagnostics/extension.log")

    /// The same notes in the system log (Console, `log show`), where a Mac's App Group container can't be read
    /// from the shell.
    private static let logger = Logger(subsystem: "com.rlx.fang.kit", category: "diagnostics")

    public static func note(_ message: @autoclosure () -> String) {
        let text = message()
        logger.notice("\(text, privacy: .public)")
        guard let file else { return }
        let line = "\(Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) \(text)\n"
        lock.withLock {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > limit {
                let previous = file.deletingPathExtension().appendingPathExtension("1.log")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: file, to: previous)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }
}
