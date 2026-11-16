import FileProvider
import Foundation

/// The File Provider UI extension's channel to the File Provider extension, for the versions view and the
/// Copy To / Move To sheet. The UI extension never talks to the server itself: on macOS it runs inside Finder's window, and macOS counts its network
/// use against Finder, which has no Local Network permission. The File Provider extension does the work
/// with the connection it already has.
public enum VersionsService {
    public static let name = NSFileProviderServiceName("com.rlx.fang.versions")

    public static var interface: NSXPCInterface {
        NSXPCInterface(with: VersionsServiceProtocol.self)
    }

    /// A file's history as the versions view shows it.
    public struct History: Codable, Sendable {
        public var item: FangItem
        public var versions: [FangAPI.VersionInfo]
        /// This device as the server names it in versions.
        public var device: String

        public init(item: FangItem, versions: [FangAPI.VersionInfo], device: String) {
            self.item = item
            self.versions = versions
            self.device = device
        }
    }

    /// Where downloaded versions go: the App Group's caches, which both extensions can read.
    public static func downloadFolder(for version: Int64) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FaNGKit.appGroupIdentifier)?
            .appending(path: "Library/Caches/Versions/\(version)")
    }

    /// An error as it crosses the connection: its readable message survives.
    public static func transportable(_ error: Error) -> NSError {
        NSError(domain: "com.rlx.fang.versions", code: (error as NSError).code,
                userInfo: [NSLocalizedDescriptionKey: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription])
    }
}

/// What the File Provider extension serves (values cross as JSON or plain types).
@objc public protocol VersionsServiceProtocol {
    /// JSON of `VersionsService.History`.
    func history(itemID: String, reply: @escaping (Data?, Error?) -> Void)
    func restore(version: Int64, reply: @escaping (Error?) -> Void)
    /// `action` is a `FangAPI.Resolution` raw value; `version` is -1 for none.
    func resolve(itemID: String, action: String, version: Int64, reply: @escaping (Error?) -> Void)
    /// Downloads a version into `VersionsService.downloadFolder(for:)` as `name`; replies with the file's path.
    func download(version: Int64, name: String, reply: @escaping (String?, Error?) -> Void)
    /// JSON of `[FangItem]`: the items as the server has them now (unknown ones left out).
    func items(itemIDs: [String], reply: @escaping (Data?, Error?) -> Void)
    /// JSON of `[FangItem]`: what's in a folder (folders first, then files, by name; hidden ones left out);
    /// "" for the shares' top folders.
    func children(parentID: String, reply: @escaping (Data?, Error?) -> Void)
    /// An item's thumbnail (`version` -1), or a version's (WebP data); nil if there's none.
    func thumbnail(itemID: String, version: Int64, reply: @escaping (Data?, Error?) -> Void)
    /// Copies (`operation` "copy") or moves ("move") items into a folder on the server, one after another.
    /// Replies with JSON of `[FangItem]`, the copies or moved items, or the first error.
    func transfer(operation: String, itemIDs: [String], parentID: String, reply: @escaping (Data?, Error?) -> Void)
}
