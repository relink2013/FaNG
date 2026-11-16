import Foundation

/// Identifiers shared by the FaNG app and its extensions.
public enum FaNGKit {
    /// App Group shared by the app and the File Provider extension.
    /// Must match both `.entitlements` files and `NSExtensionFileProviderDocumentGroup` in the extension's Info.plist.
    public static let appGroupIdentifier = "group.com.rlx.fang"
}
