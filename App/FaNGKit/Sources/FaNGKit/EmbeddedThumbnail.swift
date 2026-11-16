import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Extracts the preview an image file already carries (the EXIF thumbnail in JPEGs, the embedded
/// preview in HEIC and most RAW formats) from the first bytes of the file. Never decodes the full
/// image, so it stays within the iOS extension's memory limit.
public enum EmbeddedThumbnail {
    /// How much of the file's start to read. Embedded previews normally sit in the first few hundred KB.
    public static let headerLength: UInt64 = 512 * 1024

    /// Whether a file of this type may carry an embedded preview worth asking for.
    public static func mayHaveThumbnail(_ type: UTType) -> Bool {
        type.conforms(to: .image)
    }

    /// JPEG data of the embedded preview, scaled to fit `maxPixelSize`, or nil if there isn't one in `header`.
    public static func jpeg(fromHeader header: Data, maxPixelSize: Int) -> Data? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, header as CFData, false)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
