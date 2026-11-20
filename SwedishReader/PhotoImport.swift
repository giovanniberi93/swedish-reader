import Foundation
import ImageIO
import UIKit

struct ImportedPhoto {
    var imageData: Data
    var thumbnailData: Data
    var takenAt: Date?
    /// Position in the photo picker selection, used when capture dates are missing or equal.
    var pickIndex: Int
}

enum PhotoImport {
    /// Downscales the photo (rotated upright) and reads its capture date from EXIF.
    static func process(_ original: Data, pickIndex: Int) -> ImportedPhoto? {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let image = jpeg(from: source, maxPixels: 2400, quality: 0.85),
              let thumbnail = jpeg(from: source, maxPixels: 240, quality: 0.7)
        else { return nil }
        return ImportedPhoto(imageData: image, thumbnailData: thumbnail, takenAt: captureDate(source), pickIndex: pickIndex)
    }

    /// Oldest photo first. Photos without a date go last, in the order they were picked.
    static func ordered(_ photos: [ImportedPhoto]) -> [ImportedPhoto] {
        photos.sorted { a, b in
            switch (a.takenAt, b.takenAt) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.pickIndex < b.pickIndex
            }
        }
    }

    private static func jpeg(from source: CGImageSource, maxPixels: Int, quality: CGFloat) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: quality)
    }

    private static func captureDate(_ source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let value = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
