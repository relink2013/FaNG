import FaNGKit
import FileProvider
import UniformTypeIdentifiers

class FileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    /// Set once the domain's connection exists: a FaNG server has a trash; plain SMB deletes are permanent.
    nonisolated(unsafe) static var trashAvailable = false

    private let record: ItemRecord

    init(_ record: ItemRecord) {
        self.record = record
    }

    /// The server. File Provider requires a non-empty name; Files and Finder show the domain's display name.
    static func root(rootID: String, name: String) -> FileProviderItem {
        let remote = RemoteItem(path: "", name: name, isDirectory: true, size: 0, modified: .distantPast, created: .distantPast, fileID: 0)
        return FileProviderItem(ItemRecord(id: rootID, parentID: rootID, remote: remote))
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(record.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(record.parentID)
    }

    var filename: String {
        record.name
    }

    var contentType: UTType {
        if record.isDirectory { return .folder }
        return UTType(filenameExtension: (record.name as NSString).pathExtension) ?? .data
    }

    var documentSize: NSNumber? {
        record.isDirectory ? nil : NSNumber(value: record.size)
    }

    var creationDate: Date? {
        record.created
    }

    var contentModificationDate: Date? {
        record.modified
    }

    private var isRoot: Bool { record.id == NSFileProviderItemIdentifier.rootContainer.rawValue }

    /// The shares, at the top level. They can't be renamed, moved or deleted over SMB.
    private var isShare: Bool { !isRoot && record.isDirectory && record.parentID == NSFileProviderItemIdentifier.rootContainer.rawValue }

    var capabilities: NSFileProviderItemCapabilities {
        if isRoot { return [.allowsReading, .allowsContentEnumerating] }
        // A server copy still making this item: nothing to open yet (a folder shows empty until it's done).
        // One whose copy failed can only be deleted (nothing of it is on disk).
        switch record.job {
        case "copying": return record.isDirectory ? [.allowsContentEnumerating] : []
        case "failed": return [.allowsDeleting]
        default: break
        }
        // Read only by the server's permissions: Files and Finder offer no edit, rename, move or delete at all,
        // instead of letting one fail afterwards.
        if record.readOnly {
            return record.isDirectory ? [.allowsReading, .allowsContentEnumerating, .allowsEvicting] : [.allowsReading, .allowsEvicting]
        }
        // Without .allowsEvicting, Files and Finder offer no "Remove Download".
        if isShare { return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsEvicting] }
        var capabilities: NSFileProviderItemCapabilities = record.isDirectory
            ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsEvicting]
            : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsEvicting]
        if Self.trashAvailable {
            capabilities.insert(.allowsTrashing)
        }
        return capabilities
    }

    /// Finder tags in the form File Provider uses: an archived dictionary {"v": 1, "t": [[name, color], …]}.
    /// The server and SMB clients keep Finder's own form, "name\ncolor" strings.
    var tagData: Data? {
        guard !record.tags.isEmpty else { return nil }
        let pairs: [[Any]] = record.tags.map { tag in
            let parts = tag.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return [String(parts[0]), Int(parts.count > 1 ? parts[1] : "0") ?? 0]
        }
        return try? NSKeyedArchiver.archivedData(withRootObject: ["v": 1, "t": pairs] as NSDictionary, requiringSecureCoding: false)
    }

    /// The tags in `tagData` from the system (nil means none), as "name\ncolor" strings.
    static func tags(from data: Data?) -> [String] {
        guard let data else { return [] }
        let classes = [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self]
        if let archive = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSDictionary,
           let pairs = archive["t"] as? [[Any]] {
            return pairs.compactMap { pair in
                guard let name = pair.first as? String else { return nil }
                return "\(name)\n\((pair.count > 1 ? pair[1] as? Int : nil) ?? 0)"
            }
        }
        // Finder's own form, in case the system passes it through.
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
    }

    /// Extended attributes the system syncs (a folder's symbol or emoji, "Where from", …), as the server keeps
    /// them; a Mac over plain SMB sees the same ones as named streams.
    var extendedAttributes: [String: Data] {
        record.xattrs
    }

    /// What the File Provider UI extension's actions test: "Versions…" on FaNG-server files, "Resolve
    /// Conflict…" on files with an open conflict, "Copy To…" and "Move To…" on FaNG-server files and folders.
    var userInfo: [AnyHashable: Any]? {
        guard Self.trashAvailable, !isRoot, !isShare, record.parentID != NSFileProviderItemIdentifier.trashContainer.rawValue else { return nil }
        // While a server copy makes the item (or after it failed) only the decorations' values apply.
        if let job = record.job {
            return job == "copying"
                ? [FileProviderKeys.copying: true, FileProviderKeys.progress: record.progress ?? 0]
                : [FileProviderKeys.copyFailed: true]
        }
        if record.isDirectory { return [FileProviderKeys.transfer: true] }
        return [FileProviderKeys.fang: true, FileProviderKeys.transfer: true,
                FileProviderKeys.conflict: record.tags.contains(FileProviderKeys.conflictTag)]
    }

    /// The conflict badge (declared in Info.plist) on a file with an open conflict, next to its red tag.
    static let conflictDecoration = NSFileProviderItemDecorationIdentifier(
        rawValue: (Bundle.main.bundleIdentifier ?? "com.rlx.fang.provider") + ".conflict")

    /// A server copy making the item ("Copying 42%"), or one that failed (both declared in Info.plist).
    static let copyingDecoration = NSFileProviderItemDecorationIdentifier(
        rawValue: (Bundle.main.bundleIdentifier ?? "com.rlx.fang.provider") + ".copying")
    static let copyFailedDecoration = NSFileProviderItemDecorationIdentifier(
        rawValue: (Bundle.main.bundleIdentifier ?? "com.rlx.fang.provider") + ".copyFailed")

    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        switch record.job {
        case "copying": return [Self.copyingDecoration]
        case "failed": return [Self.copyFailedDecoration]
        default: return record.tags.contains(FileProviderKeys.conflictTag) ? [Self.conflictDecoration] : nil
        }
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: record.contentVersion, metadataVersion: record.metadataVersion)
    }
}
