// fang-thumbs: FaNG's thumbnail worker. It finds media files whose thumbnail is missing or older than their
// contents, makes one 512 px WebP each, and records it. Files a client is waiting for go first.
//
// Sources, cheapest first: the preview a camera, Lightroom or Photoshop embedded (RAW, DNG and others;
// kept current by the apps that edit them), then a render: libvips (with libheif and ImageMagick) for
// images, FFmpeg for video (a representative frame, HDR tone-mapped). It reads the shares read-only,
// runs unprivileged and never writes next to the files.

import CLinuxFS
import Crypto
import FaNGCore
import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Logging
import PostgresNIO

let environment = ProcessInfo.processInfo.environment
let config = try Config.fromEnvironment()
let logger = {
    var logger = Logger(label: "fang-thumbs")
    logger.logLevel = config.logLevel
    return logger
}()
// Only the shares fang-storaged serves (one whose folder is missing, not writable or an Unraid root is left out).
// fang-storaged writes the served shares at its start: on a first start it may not be there yet.
while !FileManager.default.fileExists(atPath: config.sharesFile) { sleep(5) }
let shares = try Share.loadAll(sharesFile: config.sharesFile).filter { $0.problem(needsWritableMount: false) == nil }
let folder = environment["FANG_THUMBNAILS"] ?? "/thumbnails"
let size = Int(environment["FANG_THUMB_SIZE"] ?? "") ?? 512
let quality = Int(environment["FANG_THUMB_QUALITY"] ?? "") ?? 80
// Half the CPUs at most (the host keeps the rest, and the container has a low CPU weight besides), and no
// more than fit in half the memory at 1 GB each (a 100-megapixel image or an 8K frame).
let workers = Resources.workers(cpuShare: 0.5, memoryPerWorker: 1 << 30, limit: 32, setting: "FANG_THUMB_WORKERS")
let client = PostgresClient(configuration: config.postgres, backgroundLogger: logger)

struct Job: Sendable {
    /// The item; for a version's job, the version's item.
    var id: UUID
    /// Set for a version's thumbnail.
    var version: Int64? = nil
    var share: String
    var path: String
    var name: String
    var contentVersion: Int64
}

struct Made: Sendable {
    var source: String
    var width: Int
    var height: Int
    var bytes: Int
}

struct Failure: Error, CustomStringConvertible {
    var description: String
}

/// Runs a tool with a time limit; returns its standard output, or throws with its error output.
///
/// Plain posix_spawn, poll and waitpid: Foundation's Process crashed (in libc) under many parallel runs
/// on Linux. Both pipes are drained as the tool runs, so it can't block on a full pipe, and a tool that
/// runs past the limit is killed.
@discardableResult
func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> Data {
    #if os(Linux)
    var outputPipe: [Int32] = [0, 0], errorPipe: [Int32] = [0, 0]
    guard outputPipe.withUnsafeMutableBufferPointer({ Glibc.pipe($0.baseAddress!) }) == 0,
          errorPipe.withUnsafeMutableBufferPointer({ Glibc.pipe($0.baseAddress!) }) == 0
    else { throw Failure(description: "pipe failed") }
    var actions = posix_spawn_file_actions_t()
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errorPipe[1], 2)
    posix_spawn_file_actions_addclose(&actions, outputPipe[0])
    posix_spawn_file_actions_addclose(&actions, errorPipe[0])
    let argv = (["nice", "-n", "10", tool] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = posix_spawnp(&pid, "nice", &actions, nil, argv, environ)
    close(outputPipe[1])
    close(errorPipe[1])
    defer {
        close(outputPipe[0])
        close(errorPipe[0])
    }
    guard spawned == 0 else { throw Failure(description: "couldn't start \(tool)") }

    var output = Data(), errors = Data()
    var open = [outputPipe[0], errorPipe[0]]
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while !open.isEmpty {
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            throw Failure(description: "\(tool) timed out")
        }
        var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        guard poll(&fds, nfds_t(fds.count), Int32(min(left, 1) * 1000)) >= 0 else { continue }
        for entry in fds where entry.revents != 0 {
            let count = read(entry.fd, &buffer, buffer.count)
            if count > 0 {
                if entry.fd == outputPipe[0] {
                    output.append(contentsOf: buffer[0..<count])
                } else if errors.count < 64 * 1024 {
                    errors.append(contentsOf: buffer[0..<count])
                }
            } else {
                open.removeAll { $0 == entry.fd }
            }
        }
    }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    guard status == 0 else {
        let message = String(decoding: errors, as: UTF8.self)
        throw Failure(description: "\(tool): " + message.split(separator: "\n").suffix(2).joined(separator: " "))
    }
    return output
    #else
    throw Failure(description: "fang-thumbs runs on Linux")
    #endif
}

/// A still image to a WebP thumbnail (shrink-on-load, sRGB, EXIF orientation applied, metadata dropped).
func renderImage(_ input: String, to output: String) throws {
    try run("vipsthumbnail", [input, "--size", "\(size)x\(size)", "--export-profile", "srgb",
                              "-o", "\(output)[Q=\(quality),strip,effort=4]"])
}

/// The largest preview embedded in the file, written to `output` with the file's orientation; false if none.
func extractEmbedded(_ input: String, to output: String) -> Bool {
    for tag in ["JpgFromRaw", "PreviewImage", "OtherImage", "PhotoshopThumbnail", "ThumbnailImage"] {
        if let data = try? run("exiftool", ["-b", "-\(tag)", input]), data.count > 1024 {
            guard FileManager.default.createFile(atPath: output, contents: data) else { return false }
            _ = try? run("exiftool", ["-q", "-overwrite_original", "-TagsFromFile", input, "-Orientation", output])
            return true
        }
    }
    return false
}

func renderVideo(_ input: String, to output: String) throws {
    let probe = try run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                    "format=duration:stream=color_transfer", "-of", "default=nw=1", input], timeout: 30)
    var duration = 0.0, transfer = ""
    for line in String(decoding: probe, as: UTF8.self).split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        if parts[0] == "duration" { duration = Double(parts[1]) ?? 0 }
        if parts[0] == "color_transfer" { transfer = parts[1] }
    }
    // HDR (PQ or HLG, as iPhones record) is tone-mapped to SDR, or it looks washed out.
    // No picture to take a frame from (a .mov with only sound, a voice memo): say so plainly.
    guard String(decoding: probe, as: UTF8.self).contains("color_transfer=") else { throw Failure(description: "no video track (sound only)") }
    let toneMap = ["smpte2084", "arib-std-b67"].contains(transfer)
        ? "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p,"
        : ""
    let seek = duration > 2 ? min(duration * 0.1, 30) : 0
    try run("ffmpeg", ["-v", "error", "-threads", "2", "-y", "-ss", String(format: "%.2f", seek), "-i", input, "-map", "0:v:0", "-an",
                       "-vf", "\(toneMap)thumbnail=n=30,scale=w=\(size):h=\(size):force_original_aspect_ratio=decrease",
                       "-frames:v", "1", "-c:v", "libwebp", "-quality", "\(quality)", output])
}

/// Makes one thumbnail into `output`.
func make(_ input: String, ext: String, output: String, scratch: String) throws -> String {
    if Thumbnails.videoExtensions.contains(ext) {
        try renderVideo(input, to: output)
        return "video"
    }
    if ext == "icns" {
        // macOS icons: the largest image in the icon family (ImageMagick has no ICNS reader).
        try run("icns2png", ["-x", "-o", scratch, input])
        // icns2png names them "<icon>_<width>x<height>x<depth>.png".
        func width(_ name: String) -> Int {
            let size = name.split(separator: "_").last ?? ""
            return Int(size.split(separator: "x").first ?? "") ?? 0
        }
        let pngs = try FileManager.default.contentsOfDirectory(atPath: scratch).filter { $0.hasSuffix(".png") }
        let largest = pngs.max { width($0) < width($1) }
        guard let largest else { throw Failure(description: "no image in the icon") }
        try renderImage(scratch + "/" + largest, to: output)
        return "rendered"
    }
    if Thumbnails.rawExtensions.contains(ext) || ext == "psd" || ext == "psb" {
        let embedded = scratch + "/embedded.jpg"
        if extractEmbedded(input, to: embedded), (try? renderImage(embedded, to: output)) != nil {
            return "embedded"
        }
    }
    do {
        try renderImage(input, to: output)
        return "rendered"
    } catch {
        // Some files libvips can't open still carry a preview.
        let embedded = scratch + "/embedded.jpg"
        guard extractEmbedded(input, to: embedded) else { throw error }
        try renderImage(embedded, to: output)
        return "embedded"
    }
}

func dimensions(_ path: String) -> (Int, Int) {
    guard let data = try? run("vipsheader", ["-f", "width", path], timeout: 10),
          let other = try? run("vipsheader", ["-f", "height", path], timeout: 10)
    else { return (0, 0) }
    return (Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            Int(String(decoding: other, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
}

/// A fingerprint of a file's contents: SHA-256 of its size and sampled bytes (all of it up to 1 MiB; else the
/// first and last 256 KiB and eight 32 KiB pieces between). Media files differ in their headers (times, serial
/// numbers) and sizes, so equal fingerprints mean the same picture; reading a sample keeps it cheap for a
/// 50 GB video. Files with the same fingerprint share one thumbnail, wherever they are.
func fingerprint(_ path: String) -> String? {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0 else { return nil }
    let size = Int64(st.st_size)
    var hasher = SHA256()
    hasher.update(data: Data("fang-fp1 \(size)".utf8))
    var buffer = [UInt8](repeating: 0, count: 256 << 10)
    func take(_ offset: Int64, _ length: Int) -> Bool {
        var done = 0
        while done < length {
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, length - done, off_t(offset) + off_t(done)) }
            if count <= 0 { return false }
            done += count
        }
        hasher.update(data: buffer[0..<length])
        return true
    }
    if size <= 1 << 20 {
        var offset: Int64 = 0
        while offset < size {
            let length = Int(min(Int64(buffer.count), size - offset))
            guard take(offset, length) else { return nil }
            offset += Int64(length)
        }
    } else {
        guard take(0, 256 << 10) else { return nil }
        for piece in 1...8 {
            guard take(size * Int64(piece) / 9, 32 << 10) else { return nil }
        }
        guard take(size - (256 << 10), 256 << 10) else { return nil }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// The thumbnail already made for this fingerprint (ready or failed), if any.
func blob(_ fingerprint: String) async throws -> (status: String, made: Made?, error: String?)? {
    let rows = try await client.query("""
        SELECT status, source, width, height, bytes, error FROM thumbnail_blobs WHERE fingerprint = \(fingerprint) AND kind = \(Thumbnails.blobKind)
        """, logger: logger)
    for try await (status, source, width, height, bytes, error) in rows.decode((String, String?, Int32?, Int32?, Int32?, String?).self) {
        let made = status == "ready" ? Made(source: source ?? "", width: Int(width ?? 0), height: Int(height ?? 0), bytes: Int(bytes ?? 0)) : nil
        return (status, made, error)
    }
    return nil
}

func process(_ job: Job) async {
    let ext = (job.name as NSString).pathExtension.lowercased()
    guard let share = shares.first(where: { $0.name == job.share }) else { return }
    let input = share.path + "/" + job.path
    // Not at its path right now (its folder is being moved, trashed or put back): noted as missing, which is
    // tried again an hour later, not a failure for good (that left 140,000 items without thumbnails forever).
    // (stat, not access: access ignores the worker's capability to read any file, and called everything missing.)
    var st = stat()
    if stat(input, &st) != 0 && errno == ENOENT {
        try? await record(job, nil, error: "missing: the file wasn't at its path", fingerprint: nil)
        return
    }
    // The same contents anywhere (another folder, share, pool or user, or this file's own earlier version)
    // already have a thumbnail: point at it instead of making it again.
    let contents = fingerprint(input)
    if let contents, let existing = try? await blob(contents) {
        try? await record(job, existing.made, error: existing.error, fingerprint: contents)
        return
    }
    let destination = folder + "/" + (contents.map { Thumbnails.relativePath(ofBlob: $0) }
        ?? job.version.map { Thumbnails.relativePath(ofVersion: $0) } ?? Thumbnails.relativePath(of: job.id))
    let scratch = NSTemporaryDirectory() + "fang-thumbs-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: scratch) }
    let output = scratch + "/thumbnail.webp"
    // libvips reads "[...]" in a name as load options, so tools get a plainly named link to the file.
    let link = scratch + "/input" + (ext.isEmpty ? "" : "." + ext)
    do {
        if access(input, R_OK) == 0 {
            guard symlink(input, link) == 0 else { throw Failure(description: "couldn't link the file") }
        } else {
            // The tools can't open it (a root-owned file with a restrictive mode: they check with access(), which
            // ignores this worker's capability to read any file). This worker can: up to 512 MB, a private copy.
            guard st.st_size <= 512 << 20 else { throw Failure(description: "permissions: the file is too big to copy and the tools may not read it") }
            guard copyReadable(input, to: link) else { throw Failure(description: "permissions: the file couldn't be read") }
        }
        let source: String
        do {
            source = try make(link, ext: ext, output: output, scratch: scratch)
        } catch where "\(error)".contains("does not exist") && isSymlink(link) {
            // The tools couldn't open it through the link (a folder above it or the file itself is root-owned with
            // a restrictive mode, and the tools check with access(), which ignores this worker's capability to read
            // any file). This worker can read it: a private copy, up to 512 MB, and once more.
            guard st.st_size <= 512 << 20 else { throw Failure(description: "permissions: the file is too big to copy and the tools may not read it") }
            unlink(link)
            guard copyReadable(input, to: link) else { throw Failure(description: "permissions: the file couldn't be read") }
            source = try make(link, ext: ext, output: output, scratch: scratch)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: output)[.size] as? Int) ?? 0
        guard bytes > 0 else { throw Failure(description: "empty thumbnail") }
        let (width, height) = dimensions(output)
        try FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let temporary = destination + ".\(UUID().uuidString.prefix(8)).tmp"
        try FileManager.default.moveItem(atPath: output, toPath: temporary)
        guard rename(temporary, destination) == 0 else { throw Failure(description: "couldn't store the thumbnail") }
        let made = Made(source: source, width: width, height: height, bytes: bytes)
        if let contents { try await recordBlob(contents, made, error: nil) }
        try await record(job, made, error: nil, fingerprint: contents)
    } catch {
        // The file's path stays out of the log and the database: names can be private.
        var info = stat()
        let route = isSymlink(link) ? "link" : (lstat(link, &info) == 0 ? "copy of \(info.st_size) bytes" : "no input")
        let message = "[\(route)] " + String(describing: error).replacingOccurrences(of: input, with: "<file>")
        // Shared by contents only when the contents are the problem: a file that was missing or unreadable at the
        // moment must not make every identical file anywhere fail without being tried.
        let environmental = ["does not exist", "permissions:", "missing:", "Permission denied", "timed out", "couldn't link"]
            .contains { message.contains($0) }
        // A damaged or unusual file (a video cut short, a .mov with only sound) is normal in a large library: one
        // debug line each and a count every 10 minutes, not a log full of them. Anything else is worth a warning.
        if environmental {
            logger.warning("No thumbnail for an item (\(ext)) for now: \(message)")
        } else {
            logger.debug("No thumbnail for an item (\(ext)): \(message)")
            unusable.add(ext)
        }
        if let contents, !environmental { try? await recordBlob(contents, nil, error: String(message.prefix(500))) }
        try? await record(job, nil, error: String(message.prefix(500)), fingerprint: contents)
    }
}

/// Files no thumbnail can be made from (their contents), counted for a summary line every 10 minutes.
final class Unusable: @unchecked Sendable {
    private let lock = NSLock()
    private var byKind: [String: Int] = [:]

    func add(_ ext: String) { lock.withLock { byKind[ext, default: 0] += 1 } }

    /// The count since the last call, as "12 (mov 9, jpg 3)", or nil if none.
    func take() -> String? {
        let counts = lock.withLock { () -> [String: Int] in
            defer { byKind = [:] }
            return byKind
        }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return nil }
        return "\(total) (" + counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")"
    }
}
let unusable = Unusable()

func isSymlink(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
}

/// Copies a file this worker may read (with its capability) but the tools may not, into `path`.
func copyReadable(_ source: String, to path: String) -> Bool {
    let input = open(source, O_RDONLY | O_CLOEXEC)
    guard input >= 0 else { return false }
    defer { close(input) }
    let output = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard output >= 0 else { return false }
    defer { close(output) }
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
        if count == 0 { return true }
        if count < 0 { return false }
        guard buffer.withUnsafeBytes({ write(output, $0.baseAddress, count) }) == count else { return false }
    }
}

func recordBlob(_ fingerprint: String, _ made: Made?, error: String?) async throws {
    try await client.query("""
        INSERT INTO thumbnail_blobs (fingerprint, kind, status, source, width, height, bytes, error)
        VALUES (\(fingerprint), \(Thumbnails.blobKind), \(made == nil ? "failed" : "ready"), \(made?.source), \(made?.width),
                \(made?.height), \(made?.bytes), \(error))
        ON CONFLICT (fingerprint, kind) DO NOTHING
        """, logger: logger)
}

func record(_ job: Job, _ made: Made?, error: String?, fingerprint: String?) async throws {
    // Kept by contents now: a file of its own from before goes (another hard link to it may stay with a copy).
    if fingerprint != nil {
        unlink(folder + "/" + (job.version.map { Thumbnails.relativePath(ofVersion: $0) } ?? Thumbnails.relativePath(of: job.id)))
    }
    if let version = job.version {
        try await client.query("""
            INSERT INTO version_thumbnails (version, status, source, width, height, bytes, error, fingerprint, updated)
            VALUES (\(version), \(made == nil ? "failed" : "ready"), \(made?.source), \(made?.width), \(made?.height),
                    \(made?.bytes), \(error), \(fingerprint), now())
            ON CONFLICT (version) DO UPDATE SET status = excluded.status, source = excluded.source, width = excluded.width,
                height = excluded.height, bytes = excluded.bytes, error = excluded.error, fingerprint = excluded.fingerprint, updated = now()
            """, logger: logger)
        try await client.query("DELETE FROM version_thumbnail_wanted WHERE version = \(version)", logger: logger)
        return
    }
    try await client.query("""
        INSERT INTO thumbnails (item, content_version, status, source, width, height, bytes, error, fingerprint, updated)
        VALUES (\(job.id), \(job.contentVersion), \(made == nil ? "failed" : "ready"), \(made?.source),
                \(made?.width), \(made?.height), \(made?.bytes), \(error), \(fingerprint), now())
        ON CONFLICT (item) DO UPDATE SET content_version = excluded.content_version, status = excluded.status,
            source = excluded.source, width = excluded.width, height = excluded.height, bytes = excluded.bytes,
            error = excluded.error, fingerprint = excluded.fingerprint, updated = now()
        """, logger: logger)
    try await client.query("DELETE FROM thumbnail_wanted WHERE item = \(job.id)", logger: logger)
}

/// Versions a client asked for a thumbnail of first (they're only made when asked), then media items whose
/// thumbnail is missing or older than their contents, the ones clients wait for first.
func nextJobs(limit: Int) async throws -> [Job] {
    let jobs = try await versionJobs(limit: limit)
    return jobs + (try await itemJobs(limit: limit - jobs.count))
}

func versionJobs(limit: Int) async throws -> [Job] {
    let rows = try await client.query("""
        SELECT v.id, v.item, v.share, v.path FROM version_thumbnail_wanted w
        JOIN versions v ON v.id = w.version
        LEFT JOIN version_thumbnails t ON t.version = v.id
        WHERE t.version IS NULL
        ORDER BY w.requested
        LIMIT \(limit)
        """, logger: logger)
    var jobs: [Job] = []
    for try await (version, item, share, path) in rows.decode((Int64, UUID, String, String).self) {
        // Versions keep the file's extension, which says how to render them; the content version isn't used.
        jobs.append(Job(id: item, version: version, share: share, path: path, name: (path as NSString).lastPathComponent, contentVersion: 0))
    }
    return jobs
}

func itemJobs(limit: Int) async throws -> [Job] {
    guard limit > 0 else { return [] }
    let extensions = Array(Thumbnails.allExtensions)
    let rows = try await client.query("""
        SELECT i.id, i.share, i.path, i.name, i.content_version FROM items i
        LEFT JOIN thumbnails t ON t.item = i.id
        LEFT JOIN thumbnail_wanted w ON w.item = i.id
        WHERE NOT i.deleted AND NOT i.trashed AND NOT i.is_dir AND i.job_state IS NULL
            AND left(i.path, 6) <> '.fang-' AND position('/.fang-' in i.path) = 0
            AND i.ext = ANY(\(extensions))
            AND (t.item IS NULL OR t.content_version <> i.content_version
                 OR (t.status = 'failed' AND t.error LIKE 'missing%' AND t.updated < now() - interval '1 hour'))
            AND NOT EXISTS (SELECT 1 FROM thumbnail_copies c WHERE c.item = i.id)
        ORDER BY w.requested IS NULL, w.requested, i.seq DESC
        LIMIT \(limit)
        """, logger: logger)
    var jobs: [Job] = []
    for try await (id, share, path, name, version) in rows.decode((UUID, String, String, String, Int64).self) {
        jobs.append(Job(id: id, share: share, path: path, name: name, contentVersion: version))
    }
    return jobs
}

/// Files a server copy made get their original's thumbnail, not a new one: the same file is linked under the
/// copy's name (a hard link, so every copy shares the one file; a reflink or plain copy where that fails).
/// The original's thumbnail is only replaced by renaming a new file into place, so an edit of the original
/// later never changes the copy's. Only taken while the original's thumbnail is still for the contents
/// that were copied; otherwise the copy gets its own made as usual.
func adoptCopies() async throws -> Int {
    let rows = try await client.query("""
        SELECT c.item, c.source, i.content_version, t.status, t.fingerprint IS NOT NULL
        FROM thumbnail_copies c
        JOIN items i ON i.id = c.item
        JOIN thumbnails t ON t.item = c.source AND t.content_version = c.source_version
        LIMIT 5000
        """, logger: logger)
    var found: [(item: UUID, source: UUID, ready: Bool)] = []
    for try await (item, source, _, status, shared) in rows.decode((UUID, UUID, Int64, String, Bool).self) {
        // A thumbnail kept by contents is already shared: the copy just points at it, no file to link.
        found.append((item, source, status == "ready" && !shared))
    }
    let notes = found
    // The links, several at a time (one at a time, each took ~2 ms on ZFS).
    let failed = LinkFailures()
    let linkers = min(workers, 16)
    DispatchQueue.concurrentPerform(iterations: min(linkers, max(notes.count, 1))) { worker in
        for index in stride(from: worker, to: notes.count, by: linkers) where notes[index].ready {
            let note = notes[index]
            if !linkThumbnail(of: note.source, for: note.item) { failed.add(note.item) }  // Made as usual instead.
        }
    }
    let unlinkable = failed.items
    // In three statements for the whole batch (one per file made a 170,000-file copy take 11 minutes).
    let linked = notes.map(\.item).filter { !unlinkable.contains($0) }
    if !linked.isEmpty {
        try await client.query("""
            INSERT INTO thumbnails (item, content_version, status, source, width, height, bytes, error, fingerprint, updated)
            SELECT c.item, i.content_version, t.status, t.source, t.width, t.height, t.bytes, t.error, t.fingerprint, now()
            FROM thumbnail_copies c
            JOIN items i ON i.id = c.item
            JOIN thumbnails t ON t.item = c.source AND t.content_version = c.source_version
            WHERE c.item = ANY(\(linked))
            ON CONFLICT (item) DO UPDATE SET content_version = excluded.content_version, status = excluded.status,
                source = excluded.source, width = excluded.width, height = excluded.height, bytes = excluded.bytes,
                error = excluded.error, fingerprint = excluded.fingerprint, updated = now()
            """, logger: logger)
        try await client.query("DELETE FROM thumbnail_wanted WHERE item = ANY(\(linked))", logger: logger)
    }
    let done = linked + Array(unlinkable)
    if !done.isEmpty {
        try await client.query("DELETE FROM thumbnail_copies WHERE item = ANY(\(done))", logger: logger)
    }
    return done.count
}

/// Links the original's thumbnail file for a copy (hard link; reflink or plain copy where that fails).
func linkThumbnail(of source: UUID, for item: UUID) -> Bool {
    let from = folder + "/" + Thumbnails.relativePath(of: source), to = folder + "/" + Thumbnails.relativePath(of: item)
    unlink(to)
    if link(from, to) == 0 { return true }
    if errno == ENOENT {  // The folder for the copy's ID isn't there yet.
        try? FileManager.default.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if link(from, to) == 0 { return true }
    }
    return fang_clone(from, to) == 0
}

final class LinkFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<UUID>()
    func add(_ id: UUID) { lock.withLock { _ = set.insert(id) } }
    var items: Set<UUID> { lock.withLock { set } }
}

/// Notes for copies whose original changed since (or lost its thumbnail): those are made as usual. And notes
/// for copies that never got their items (a copy that failed after noting them). Once after the batches: run
/// with every batch, it read all waiting notes each time.
func dropStaleCopies() async throws {
    try await client.query("""
        DELETE FROM thumbnail_copies c WHERE
            (EXISTS (SELECT 1 FROM items i WHERE i.id = c.item)
             AND NOT EXISTS (SELECT 1 FROM thumbnails t WHERE t.item = c.source AND t.content_version = c.source_version))
            OR (c.created < now() - interval '1 hour' AND NOT EXISTS (SELECT 1 FROM items i WHERE i.id = c.item))
        """, logger: logger)
}

/// Thumbnails of items that are gone.
func removeOrphans() async throws {
    // Items deleted (or whose records are gone): their own files go; shared ones go below once unused.
    let rows = try await client.query("""
        DELETE FROM thumbnails t WHERE NOT EXISTS (SELECT 1 FROM items i WHERE i.id = t.item AND NOT i.deleted)
        RETURNING t.item, t.fingerprint IS NULL
        """, logger: logger)
    for try await (id, own) in rows.decode((UUID, Bool).self) where own {
        try? FileManager.default.removeItem(atPath: folder + "/" + Thumbnails.relativePath(of: id))
    }
    try await client.query("""
        DELETE FROM thumbnail_wanted w WHERE NOT EXISTS (SELECT 1 FROM items i WHERE i.id = w.item AND NOT i.deleted)
        """, logger: logger)
    // Versions removed with their item for good (or by retention), and requests for them.
    let versions = try await client.query("""
        DELETE FROM version_thumbnails t WHERE NOT EXISTS (SELECT 1 FROM versions v WHERE v.id = t.version)
        RETURNING t.version, t.fingerprint IS NULL
        """, logger: logger)
    for try await (version, own) in versions.decode((Int64, Bool).self) where own {
        try? FileManager.default.removeItem(atPath: folder + "/" + Thumbnails.relativePath(ofVersion: version))
    }
    // Shared thumbnails nothing points at any more (made over an hour ago, so one being recorded stays).
    let blobs = try await client.query("""
        DELETE FROM thumbnail_blobs b WHERE b.created < now() - interval '1 hour'
            AND NOT EXISTS (SELECT 1 FROM thumbnails t WHERE t.fingerprint = b.fingerprint)
            AND NOT EXISTS (SELECT 1 FROM version_thumbnails v WHERE v.fingerprint = b.fingerprint)
        RETURNING b.fingerprint, b.kind
        """, logger: logger)
    for try await (fingerprint, kind) in blobs.decode((String, String).self) {
        try? FileManager.default.removeItem(atPath: folder + "/" + Thumbnails.relativePath(ofBlob: fingerprint, kind: kind))
    }
    try await client.query("""
        DELETE FROM version_thumbnail_wanted w WHERE NOT EXISTS (SELECT 1 FROM versions v WHERE v.id = w.version)
        """, logger: logger)
}

/// Whether there may be work: the latest change number, and whether a client asked for anything. When the
/// queue was empty and neither moved, the queue query (a scan of every media item) isn't run again: run every
/// 3 s while idle, it kept the database reading all the time.
func activity() async throws -> (seq: Int64, asked: Bool) {
    let rows = try await client.query("""
        SELECT coalesce((SELECT max(seq) FROM items), 0),
            EXISTS (SELECT 1 FROM thumbnail_wanted) OR EXISTS (SELECT 1 FROM version_thumbnail_wanted)
                OR EXISTS (SELECT 1 FROM thumbnail_copies)
        """, logger: logger)
    for try await (seq, asked) in rows.decode((Int64, Bool).self) { return (seq, asked) }
    return (0, true)
}

/// The highest applied migration, or 0 if the database isn't ready.
func schemaVersion() async -> Int {
    guard let rows = try? await client.query("SELECT coalesce(max(version), 0) FROM schema_migrations", logger: logger) else { return 0 }
    do {
        for try await version in rows.decode(Int.self) { return version }
    } catch {}
    return 0
}

try await withThrowingDiscardingTaskGroup { group in
    group.addTask { await client.run() }
    group.addTask {
        while true {
            try await Task.sleep(for: .seconds(600))
            if let summary = unusable.take() {
                logger.info("No thumbnail possible for \(summary) files in the last 10 minutes: damaged, cut short, or without a picture (the admin page counts them as failed)")
            }
        }
    }
    // The shares changed (fang-storaged restarted with others, or home folders): start again with them.
    group.addTask {
        let start = try? FileManager.default.attributesOfItem(atPath: config.sharesFile)[.modificationDate] as? Date
        while true {
            try await Task.sleep(for: .seconds(30))
            let now = try? FileManager.default.attributesOfItem(atPath: config.sharesFile)[.modificationDate] as? Date
            if now != start {
                logger.info("The served shares changed; restarting to use them")
                exit(0)
            }
        }
    }
    // fang-storaged applies the migrations: wait until all of them are in (the queries below need the
    // newest columns; starting earlier crashed until Docker's restarts caught up).
    while await schemaVersion() < Migrations.latest {
        try await Task.sleep(for: .seconds(2))
    }
    logger.info("Making \(size) px WebP thumbnails into \(folder) with \(workers) workers (\(Resources.summary))")
    var lastCleanup = Date.distantPast
    var idleAt: Int64?  // The change number when the queue was last found empty.
    var lastQueueCheck = Date.distantPast
    while true {
        if Date().timeIntervalSince(lastCleanup) > 3600 {
            try? await removeOrphans()
            lastCleanup = Date()
        }
        let jobs: [Job]
        let now: (seq: Int64, asked: Bool)
        do {
            // Read before the queue, so a change that lands meanwhile is seen next round.
            now = try await activity()
            // Idle: nothing changed and nobody asked. The queue is still looked at every ten minutes (files that
            // were missing are retried an hour later).
            if now.seq == idleAt, !now.asked, Date().timeIntervalSince(lastQueueCheck) < 600 {
                try await Task.sleep(for: .seconds(3))
                continue
            }
            // Copies first: linking thousands takes a moment, making them again would take hours.
            while try await adoptCopies() > 0 {}
            try await dropStaleCopies()
            jobs = try await nextJobs(limit: workers * 4)
            lastQueueCheck = Date()
        } catch {
            // The database restarting, or busy: wait and try again rather than exit.
            logger.warning("Couldn't read the queue: \(String(describing: error))")
            try await Task.sleep(for: .seconds(5))
            continue
        }
        if jobs.isEmpty {
            idleAt = now.seq
            try await Task.sleep(for: .seconds(3))
            continue
        }
        idleAt = nil
        await withTaskGroup(of: Void.self) { batch in
            var running = 0
            for job in jobs {
                if running == workers {
                    await batch.next()
                    running -= 1
                }
                batch.addTask { await process(job) }
                running += 1
            }
        }
    }
}
