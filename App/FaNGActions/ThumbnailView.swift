import ImageIO
import SwiftUI

/// A small square thumbnail made by the FaNG server (WebP, read with ImageIO), or the item's icon while
/// it loads or when there's none. Loaded thumbnails are kept for as long as the sheet is open.
struct ThumbnailView: View {
    /// What the thumbnail is of: the same key shows the same picture without asking again.
    let key: String
    let isDirectory: Bool
    var side: CGFloat = 40
    let load: () async -> Data?

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: isDirectory ? "folder.fill" : "doc")
                    .font(.system(size: side * 0.5))
                    .foregroundStyle(isDirectory ? Color.accentColor : .secondary)
            }
        }
        .frame(width: side, height: side)
        .task(id: key) {
            guard !isDirectory else { return }
            if let cached = ThumbnailCache.shared.image(for: key) {
                image = cached
                return
            }
            guard let data = await load(), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return }
            ThumbnailCache.shared.store(decoded, for: key)
            image = decoded
        }
    }
}

/// Thumbnails already shown, by key (they're small: 512 px WebP, about 20 KB each).
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 300
    }

    func image(for key: String) -> CGImage? { cache.object(forKey: key as NSString) }
    func store(_ image: CGImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}
