import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Optional real photographs for the demo archive.
///
/// The default demo draws its pictures (`DemoScenes`), which is the right default: the fixture
/// must build offline and depict nobody real. `saga demo --photos <folder>` swaps the drawn
/// scenes for an ordinary folder of photographs, so a website capture can show a camera roll.
/// The folder is read once, in filename order, and every picture is centre-cropped to a square
/// and re-encoded as JPEG, because the Gallery draws square tiles and the media files have to
/// be the same `.jpg` shape the importer produces.
enum DemoPhotoSource {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "avif"]

    /// Side of the square the demo stores, in pixels. The Gallery tile is ~210 pt at 2×.
    static let side = 640

    /// Image files in `folder`, sorted by filename so cycling through them is deterministic
    /// across runs and machines.
    static func imageFiles(in folder: URL) throws -> [URL] {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw DemoVault.GenerationError.photosFolderMissing(folder.path)
        }
        let names = try fm.contentsOfDirectory(atPath: folder.path)
        let files = names
            .filter { !$0.hasPrefix(".") && extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { folder.appendingPathComponent($0) }
        guard !files.isEmpty else { throw DemoVault.GenerationError.photosFolderEmpty(folder.path) }
        return files
    }

    /// Decodes every picture in the folder into a square JPEG. Throws when nothing decodes:
    /// a folder that yields no media would otherwise produce a silently drawn-scene demo.
    static func load(from folder: URL?) throws -> [Data] {
        guard let folder else { return [] }
        let files = try imageFiles(in: folder)
        var photos: [Data] = []
        for file in files {
            guard let data = squareJPEG(file) else {
                throw DemoVault.GenerationError.photosUnreadable(file.lastPathComponent)
            }
            photos.append(data)
        }
        return photos
    }

    /// Centre crop to a square, downscale and encode. `CreateThumbnailWithTransform` bakes in
    /// the EXIF orientation, which a plain `CGImageSourceCreateImageAtIndex` would drop.
    static func squareJPEG(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let edge = min(width, height)
        let crop = CGRect(x: (width - edge) / 2, y: (height - edge) / 2, width: edge, height: edge)
        guard let square = image.cropping(to: crop) else { return nil }

        let px = CGFloat(side)
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: px, height: px))
        guard let out = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
