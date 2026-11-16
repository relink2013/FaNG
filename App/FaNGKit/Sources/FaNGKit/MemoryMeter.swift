import Darwin
import Foundation

/// The extension's peak memory, measured after each operation (no timer: idle costs nothing) and kept in
/// the App Group, so it can be read off a device without a profiler attached. iOS ends File Provider
/// extensions at about 20 MB, so this is the number to watch.
public final class MemoryMeter: @unchecked Sendable {
    public struct Peak: Codable, Sendable {
        public var bytes: UInt64
        public var operation: String
        public var at: Date
    }

    private let url: URL
    private let lock = NSLock()
    private var peak: Peak?

    public init(folder: URL) {
        url = folder.appending(path: "extension-memory.json")
        peak = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Peak.self, from: $0) }
    }

    /// The process's physical footprint now (what iOS counts against the limit).
    public static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Records the footprint after `operation`, keeping it if it's a new peak.
    public func measure(after operation: String) {
        let bytes = Self.footprint()
        let updated: Peak? = lock.withLock {
            guard bytes > (peak?.bytes ?? 0) else { return nil }
            peak = Peak(bytes: bytes, operation: operation, at: Date())
            return peak
        }
        if let updated, let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public var current: Peak? {
        lock.withLock { peak }
    }
}
