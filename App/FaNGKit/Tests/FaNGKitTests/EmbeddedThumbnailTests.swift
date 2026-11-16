import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FaNGKit

struct EmbeddedThumbnailTests {
    /// A noisy 3000×2000 JPEG (so it's well over the header length), optionally with an embedded EXIF thumbnail.
    private func makeJPEG(embedThumbnail: Bool) throws -> Data {
        let width = 3000, height = 2000
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<4000 {
            context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1)
            context.fill(CGRect(x: .random(in: 0..<3000), y: .random(in: 0..<2000), width: 40, height: 40))
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImageDestinationEmbedThumbnail: embedThumbnail,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func extractsEmbeddedThumbnailFromHeaderOnly() throws {
        let jpeg = try makeJPEG(embedThumbnail: true)
        #expect(UInt64(jpeg.count) > EmbeddedThumbnail.headerLength)
        let header = jpeg.prefix(Int(EmbeddedThumbnail.headerLength))

        let thumbnail = try #require(EmbeddedThumbnail.jpeg(fromHeader: header, maxPixelSize: 256))
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= 256)
    }

    @Test func returnsNilWithoutEmbeddedThumbnail() throws {
        let jpeg = try makeJPEG(embedThumbnail: false)
        let header = jpeg.prefix(Int(EmbeddedThumbnail.headerLength))
        #expect(EmbeddedThumbnail.jpeg(fromHeader: header, maxPixelSize: 256) == nil)
    }

    @Test func onlyImagesMayHaveThumbnails() {
        #expect(EmbeddedThumbnail.mayHaveThumbnail(.jpeg))
        #expect(EmbeddedThumbnail.mayHaveThumbnail(.heic))
        #expect(!EmbeddedThumbnail.mayHaveThumbnail(.pdf))
    }
}
