import Foundation
import Logging
import PostgresNIO

/// Which files get thumbnails, and where they're kept. One WebP per item, rebuilt when its contents
/// change; clients that need another format get it converted on the way out, never stored twice.
public enum Thumbnails {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "apng", "gif", "webp", "heic", "heif", "hif", "avif", "tif", "tiff",
        "bmp", "dib", "ico", "cur", "icns", "tga", "psd", "psb", "jxl", "jp2", "j2k", "jpf", "jpx", "exr", "hdr",
        "dpx", "svg", "svgz", "ppm", "pgm", "pbm", "pnm", "pfm", "xcf", "qoi", "dds", "pcx", "eps",
    ]
    /// Camera RAW: rendered from the preview the camera (or Lightroom, Photoshop) embedded.
    public static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f",
        "3fr", "erf", "kdc", "mos", "mrw", "dcr", "iiq", "rwl", "gpr", "fff",
    ]
    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "wmv", "asf", "flv", "f4v", "mpg", "mpeg", "m2v", "mpe",
        "ts", "m2ts", "mts", "vob", "3gp", "3g2", "ogv", "mxf", "dv", "hevc", "h264", "y4m", "gifv",
    ]
    public static var allExtensions: Set<String> { imageExtensions.union(rawExtensions).union(videoExtensions) }

    /// The thumbnail file of an item, inside the thumbnails folder.
    public static func relativePath(of item: UUID) -> String {
        let id = item.uuidString.lowercased()
        return "\(id.prefix(2))/\(id).webp"
    }

    /// The shared file of a thumbnail made from contents with this fingerprint, inside the thumbnails folder.
    public static func relativePath(ofBlob fingerprint: String, kind: String = blobKind) -> String {
        "blobs/\(kind)/\(fingerprint.prefix(2))/\(fingerprint).webp"
    }

    /// The kind of preview thumbnails are (others can be added next to it).
    public static let blobKind = "thumb"

    /// The thumbnail file of a version, inside the thumbnails folder.
    public static func relativePath(ofVersion version: Int64) -> String {
        "versions/\(String(format: "%02x", version & 0xff))/\(version).webp"
    }
}

extension ItemStore {
    /// True if the item's thumbnail is ready for its current contents.
    public func thumbnailReady(_ id: UUID) async throws -> Bool {
        let rows = try await client.query("""
            SELECT 1 FROM thumbnails t JOIN items i ON i.id = t.item
            WHERE t.item = \(id) AND t.status = 'ready' AND t.content_version = i.content_version
            """, logger: logger)
        for try await _ in rows { return true }
        return false
    }

    /// True if making the item's thumbnail failed for its current contents (so waiting won't help).
    public func thumbnailFailed(_ id: UUID) async throws -> Bool {
        let rows = try await client.query("""
            SELECT 1 FROM thumbnails t JOIN items i ON i.id = t.item
            WHERE t.item = \(id) AND t.status = 'failed' AND t.content_version = i.content_version
            """, logger: logger)
        for try await _ in rows { return true }
        return false
    }

    /// Notes, for the files a server copy made, the originals they came from (copy ID → original ID), where the
    /// original's thumbnail is current: fang-thumbs then links it instead of making the same one again.
    /// Recorded before the copies' items, so fang-thumbs never starts on them first.
    public func recordThumbnailCopies(_ sources: [(copy: UUID, source: UUID)]) async throws {
        for start in stride(from: 0, to: sources.count, by: 1000) {
            let batch = sources[start..<min(start + 1000, sources.count)]
            var bindings = PostgresBindings()
            var rows: [String] = []
            for (index, pair) in batch.enumerated() {
                rows.append("($\(index * 2 + 1)::uuid, $\(index * 2 + 2)::uuid)")
                bindings.append(pair.copy)
                bindings.append(pair.source)
            }
            let sql = """
                INSERT INTO thumbnail_copies (item, source, source_version)
                SELECT v.item, v.source, s.content_version FROM (VALUES \(rows.joined(separator: ", "))) AS v(item, source)
                JOIN items s ON s.id = v.source
                JOIN thumbnails t ON t.item = s.id AND t.content_version = s.content_version
                ON CONFLICT (item) DO NOTHING
                """
            try await client.query(PostgresQuery(unsafeSQL: sql, binds: bindings), logger: logger)
        }
    }

    /// The item's thumbnail file (inside the thumbnails folder), if it's ready for its current contents.
    public func thumbnailFile(_ id: UUID) async throws -> String? {
        let rows = try await client.query("""
            SELECT t.fingerprint FROM thumbnails t JOIN items i ON i.id = t.item
            WHERE t.item = \(id) AND t.status = 'ready' AND t.content_version = i.content_version
            """, logger: logger)
        for try await fingerprint in rows.decode(String?.self) {
            return fingerprint.map { Thumbnails.relativePath(ofBlob: $0) } ?? Thumbnails.relativePath(of: id)
        }
        return nil
    }

    /// A version's thumbnail file, if it's ready.
    public func versionThumbnailFile(_ version: Int64) async throws -> String? {
        let rows = try await client.query("SELECT fingerprint FROM version_thumbnails WHERE version = \(version) AND status = 'ready'", logger: logger)
        for try await fingerprint in rows.decode(String?.self) {
            return fingerprint.map { Thumbnails.relativePath(ofBlob: $0) } ?? Thumbnails.relativePath(ofVersion: version)
        }
        return nil
    }

    /// Puts these items at the front of the thumbnail queue, unless theirs is ready (a folder being opened).
    public func wantThumbnails(_ ids: [UUID]) async throws {
        try await client.query("""
            INSERT INTO thumbnail_wanted (item)
            SELECT i.id FROM items i LEFT JOIN thumbnails t ON t.item = i.id
            WHERE i.id = ANY(\(ids)) AND i.job_state IS NULL AND (t.item IS NULL OR t.content_version <> i.content_version)
            ON CONFLICT DO NOTHING
            """, logger: logger)
    }

    /// Puts the item at the front of the thumbnail queue.
    public func wantThumbnail(_ id: UUID) async throws {
        try await client.query("INSERT INTO thumbnail_wanted (item) VALUES (\(id)) ON CONFLICT DO NOTHING", logger: logger)
    }
}

/// Where the server's own storage goes, for the app (so space never grows without an explanation).
public struct StorageReport: Codable, Sendable {
    public struct Part: Codable, Sendable {
        public var items: Int64
        public var bytes: Int64
    }
    public var trash: Part
    public var versions: Part
    public var thumbnails: Part
    public var databaseBytes: Int64
    /// Records of deleted items kept for devices that haven't synced yet.
    public var deletedRecords: Int64
    public var trashDays: Int
    public var versionDays: Int
    public var deletedRecordDays: Int
}

extension ItemStore {
    public func storageReport() async throws -> StorageReport {
        func part(_ sql: String) async throws -> StorageReport.Part {
            for try await (count, bytes) in try await client.query(PostgresQuery(unsafeSQL: sql), logger: logger).decode((Int64, Int64).self) {
                return .init(items: count, bytes: bytes)
            }
            return .init(items: 0, bytes: 0)
        }
        func number(_ sql: String) async throws -> Int64 {
            for try await value in try await client.query(PostgresQuery(unsafeSQL: sql), logger: logger).decode(Int64.self) { return value }
            return 0
        }
        let environment = ProcessInfo.processInfo.environment
        return StorageReport(
            trash: try await part("SELECT count(*), coalesce(sum(size), 0)::bigint FROM items WHERE NOT deleted AND left(path, 11) = '.fang-trash'"),
            versions: try await part("SELECT count(*), coalesce(sum(size), 0)::bigint FROM versions"),
            thumbnails: try await part("""
                SELECT (SELECT count(*) FROM thumbnail_blobs) + (SELECT count(*) FROM thumbnails WHERE fingerprint IS NULL AND status = 'ready')
                    + (SELECT count(*) FROM version_thumbnails WHERE fingerprint IS NULL AND status = 'ready'),
                    (SELECT coalesce(sum(bytes), 0) FROM thumbnail_blobs)::bigint
                    + (SELECT coalesce(sum(bytes), 0) FROM thumbnails WHERE fingerprint IS NULL)::bigint
                    + (SELECT coalesce(sum(bytes), 0) FROM version_thumbnails WHERE fingerprint IS NULL)::bigint
                """),
            databaseBytes: try await number("SELECT pg_database_size(current_database())"),
            deletedRecords: try await number("SELECT count(*) FROM items WHERE deleted"),
            trashDays: 30,
            versionDays: Int(environment["FANG_VERSION_DAYS"] ?? "") ?? 365,
            deletedRecordDays: Int(environment["FANG_DELETED_RECORD_DAYS"] ?? "") ?? 30)
    }
}

extension ItemStore {
    /// "ready", "failed", or nil if the version's thumbnail isn't made yet.
    public func versionThumbnailStatus(_ version: Int64) async throws -> String? {
        let rows = try await client.query("SELECT status FROM version_thumbnails WHERE version = \(version)", logger: logger)
        for try await status in rows.decode(String.self) { return status }
        return nil
    }

    /// Asks the thumbnail worker for a version's thumbnail (versions only get one when asked).
    public func wantVersionThumbnail(_ version: Int64) async throws {
        try await client.query("INSERT INTO version_thumbnail_wanted (version) VALUES (\(version)) ON CONFLICT DO NOTHING", logger: logger)
    }
}
