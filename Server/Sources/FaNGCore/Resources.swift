import Foundation

/// What this machine (or this container) lets FaNG use, so every pool of workers sizes itself to the hardware
/// it runs on instead of a number picked for one server. A container's limits come first: its CPU quota
/// (`cpu.max`) and memory limit (`memory.max`, cgroup v2), then the CPUs it may run on and the memory that's
/// free on the host.
public enum Resources {
    /// CPUs this process may use (at least 1).
    public static let cpus: Int = {
        var count = ProcessInfo.processInfo.activeProcessorCount
        if let quota = readSystemFile("/sys/fs/cgroup/cpu.max") {
            let parts = quota.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2, let limit = Double(parts[0]), let period = Double(parts[1]), period > 0 {
                count = min(count, max(1, Int((limit / period).rounded(.up))))
            }
        }
        return max(1, count)
    }()

    /// Bytes of memory this process may use: the container's limit, or what the host has available now.
    public static let memory: Int64 = {
        var available = Int64.max
        if let text = readSystemFile("/sys/fs/cgroup/memory.max"),
           let limit = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            available = limit
        }
        if let info = readSystemFile("/proc/meminfo") {
            for line in info.split(separator: "\n") where line.hasPrefix("MemAvailable:") {
                let kilobytes = line.split(separator: " ").dropFirst().first.flatMap { Int64($0) } ?? 0
                if kilobytes > 0 { available = min(available, kilobytes * 1024) }
            }
        }
        return available == .max ? 4 << 30 : available
    }()

    /// How many workers to run for one kind of work.
    ///
    /// - `cpuShare`: the part of the CPUs it may keep busy (CPU-heavy work like thumbnails leaves the rest to
    ///   the host; disk-bound work can go above 1, since its workers mostly wait).
    /// - `memoryPerWorker`: what one worker may need at most; together they stay inside half the memory, so a
    ///   burst of big files can't push the host (or the container) into the OOM killer.
    /// - `limit`: an upper bound where more workers stop helping.
    /// - `setting`: an environment variable that overrides it (a number), for hosts that want something else.
    public static func workers(cpuShare: Double, memoryPerWorker: Int64, limit: Int, setting: String? = nil) -> Int {
        if let setting, let value = ProcessInfo.processInfo.environment[setting].flatMap(Int.init), value > 0 {
            return value
        }
        let byCPU = max(1, Int((Double(cpus) * cpuShare).rounded(.down)))
        let byMemory = max(1, Int(memory / 2 / max(memoryPerWorker, 1)))
        return max(1, min(byCPU, byMemory, limit))
    }

    /// One line for the log: what the process found.
    public static var summary: String {
        "\(cpus) CPUs, \(memory >> 20) MB memory"
    }
}

/// A /proc or /sys file, read to its end. They report a size of 0, and Foundation's String(contentsOfFile:)
/// can stop after the first read: /proc/self/mountinfo came back cut short, without the mounts start.sh adds
/// last (a share's ZFS datasets), so their changes went unwatched.
public func readSystemFile(_ path: String) -> String? {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var data = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count < 0 { if errno == EINTR { continue }; return nil }
        if count == 0 { break }
        data += buffer[0..<count]
    }
    return String(decoding: data, as: UTF8.self)
}
