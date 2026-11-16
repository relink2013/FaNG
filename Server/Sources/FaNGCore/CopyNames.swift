import Foundation

/// Names for copies and moved items, the way Finder picks them: a copy into the item's own folder is
/// "Name copy.ext", then "Name copy 2.ext", …; anywhere else the item keeps its name, and a name that's
/// taken becomes "Name 2.ext", "Name 3.ext", …
public enum CopyNames {
    /// The `attempt`th name to try (0 first).
    public static func candidate(_ name: String, isDirectory: Bool, sameFolder: Bool, attempt: Int) -> String {
        let (base, ext) = split(name, isDirectory: isDirectory)
        let suffix: String
        if sameFolder {
            suffix = attempt == 0 ? " copy" : " copy \(attempt + 1)"
        } else {
            suffix = attempt == 0 ? "" : " \(attempt + 1)"
        }
        return base + suffix + ext
    }

    /// True for a name a client may ask for: one path component, not FaNG's own, not "." or "..".
    public static func isAcceptable(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && !name.hasPrefix(".fang-") && name.utf8.count <= 255
    }

    /// The name before the extension, and the extension with its dot ("" for folders and names without one,
    /// or a name that's only an extension, like ".profile").
    private static func split(_ name: String, isDirectory: Bool) -> (String, String) {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex
        else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
}
