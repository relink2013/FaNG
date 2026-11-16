import FaNGKit
import FileProvider
import FileProviderUI
import SwiftUI

/// The File Provider UI extension's one view controller. Files and Finder show it for "Versions…" and
/// "Resolve Conflict…" (declared in Info.plist; FaNG items say in `userInfo` where those apply). Both open
/// the same versions view; for a conflict, the conflicting edits come first.
final class ActionViewController: FPUIActionExtensionViewController {
    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
        let context = extensionContext
        let domain = context.domainIdentifier?.rawValue ?? ""
        switch actionIdentifier {
        case "com.rlx.fang.action.copy", "com.rlx.fang.action.move":
            let model = TransferModel(
                operation: actionIdentifier.hasSuffix(".copy") ? .copy : .move,
                domainIdentifier: domain,
                itemIdentifiers: itemIdentifiers.map(\.rawValue),
                done: { context.completeRequest() },
                reveal: { folder, items in await Self.reveal(folder: folder, items: items, context: context) }
            )
            show(TransferView(model: model))
        default:
            let model = VersionsModel(
                domainIdentifier: domain,
                itemID: itemIdentifiers.first?.rawValue ?? "",
                done: { context.completeRequest() }
            )
            show(VersionsView(model: model))
        }
    }

    /// Shows where a copy or move went. On macOS, Finder reveals the items (selected in a window of their
    /// folder), or the folder if they aren't on this Mac yet: this sheet runs in Finder's sandbox, where
    /// opening a folder through Launch Services is refused ("does not have permission to open"), but
    /// asking Finder to reveal it isn't. On iOS, Files opens at the folder.
    @MainActor private static func reveal(folder: URL, items: [URL], context: FPUIActionExtensionContext) async -> Bool {
        #if os(macOS)
        let urls = items.isEmpty ? [folder] : items
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        return true
        #else
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = folder.path
        guard let files = components.url else { return false }
        return await withCheckedContinuation { continuation in
            context.open(files) { continuation.resume(returning: $0) }
        }
        #endif
    }

    override func prepare(forError error: Error) {
        // FaNG signs in from the app (a device token); there's nothing to enter here.
        extensionContext.cancelRequest(withError: error)
    }

    private func show(_ content: some View) {
        #if os(macOS)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        preferredContentSize = NSSize(width: 520, height: 560)
        #else
        let host = UIHostingController(rootView: content)
        #endif
        addChild(host)
        host.view.frame = view.bounds
        #if os(macOS)
        host.view.autoresizingMask = [.width, .height]
        #else
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        self.view.addSubview(host.view)
        #if os(iOS)
        host.didMove(toParent: self)
        #endif
    }
}
