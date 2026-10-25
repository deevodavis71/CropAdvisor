import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PhotoMetadata {
    var camera: String?
    var lens: String?
    var exposure: String?
    var fullPixelSize: CGSize = .zero
    /// Properties to carry over into exported files (EXIF, TIFF, GPS…).
    var properties: [CFString: Any] = [:]
}

enum ImageLoaderError: LocalizedError {
    case unreadable(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Could not decode “\(url.lastPathComponent)”."
        }
    }
}

enum ImageLoader {
    static let workingLongSide: CGFloat = 1600

    static let supportedTypes: [UTType] = {
        var types: [UTType] = [.rawImage, .image]
        if let nef = UTType(filenameExtension: "nef") { types.insert(nef, at: 0) }
        return types
    }()

    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Decodes a RAW file (NEF etc.) with Core Image's RAW pipeline, falling back to a
    /// regular image decode. The result is oriented and has its origin at (0, 0).
    /// - Parameter maxLongSide: downscale target; `nil` decodes at full resolution.
    static func loadImage(url: URL, maxLongSide: CGFloat?) throws -> CIImage {
        var image: CIImage?
        if let raw = CIRAWFilter(imageURL: url) {
            if let maxLongSide {
                let native = raw.nativeSize
                let long = max(native.width, native.height)
                if long > 0 { raw.scaleFactor = Float(min(1, maxLongSide / long)) }
            }
            image = raw.outputImage
        }
        if image == nil {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard var result = image, !result.extent.isEmpty, !result.extent.isInfinite else {
            throw ImageLoaderError.unreadable(url)
        }
        result = result.transformed(by: .init(translationX: -result.extent.minX, y: -result.extent.minY))

        if let maxLongSide {
            let long = max(result.extent.width, result.extent.height)
            if long > maxLongSide * 1.05 {
                let s = maxLongSide / long
                result = result.transformed(by: .init(scaleX: s, y: s), highQualityDownsample: true)
                result = result.transformed(by: .init(translationX: -result.extent.minX, y: -result.extent.minY))
            }
        }
        return result
    }

    static func metadata(for url: URL) -> PhotoMetadata {
        var meta = PhotoMetadata()
        if let raw = CIRAWFilter(imageURL: url) {
            raw.scaleFactor = 1
            meta.fullPixelSize = raw.outputImage?.extent.size ?? raw.nativeSize
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return meta
        }
        meta.properties = props
        if meta.fullPixelSize == .zero,
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            meta.fullPixelSize = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]

        if let model = tiff?[kCGImagePropertyTIFFModel] as? String {
            let make = (tiff?[kCGImagePropertyTIFFMake] as? String) ?? ""
            meta.camera = model.uppercased().hasPrefix(make.uppercased()) || make.isEmpty
                ? model : "\(make.capitalized) \(model)"
        }
        meta.lens = (exif?[kCGImagePropertyExifLensModel] as? String) ?? (aux?[kCGImagePropertyExifAuxLensModel] as? String)

        var parts: [String] = []
        // Manual lenses report zeros for focal length and aperture.
        if let focal = exif?[kCGImagePropertyExifFocalLength] as? Double, focal > 0 { parts.append(String(format: "%.0f mm", focal)) }
        if let f = exif?[kCGImagePropertyExifFNumber] as? Double, f > 0 { parts.append(String(format: "f/%.1f", f)) }
        if let t = exif?[kCGImagePropertyExifExposureTime] as? Double {
            parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
        meta.exposure = parts.isEmpty ? nil : parts.joined(separator: " · ")
        return meta
    }

    static func render(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8,
                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

/// Rotates an image to level the horizon and crops to the largest upright rectangle
/// that contains no empty corners. Proportional, so the same angle gives matching
/// normalized geometry at preview and full resolution.
enum Straightener {
    /// Largest axis-aligned rectangle inside a `size` rectangle rotated by `angle`.
    static func inscribedSize(_ size: CGSize, angle: CGFloat) -> CGSize {
        let w = size.width, h = size.height
        guard w > 0, h > 0, abs(angle) > 1e-6 else { return size }
        let widthIsLonger = w >= h
        let long = widthIsLonger ? w : h, short = widthIsLonger ? h : w
        let s = abs(sin(angle)), c = abs(cos(angle))
        if short <= 2 * s * c * long || abs(s - c) < 1e-10 {
            let x = 0.5 * short
            return widthIsLonger ? CGSize(width: x / s, height: x / c) : CGSize(width: x / c, height: x / s)
        }
        let cos2a = c * c - s * s
        return CGSize(width: (w * c - h * s) / cos2a, height: (h * c - w * s) / cos2a)
    }

    /// `angle` is in radians, counter-clockwise (Core Image convention).
    static func apply(_ image: CIImage, angle: CGFloat) -> CIImage {
        guard abs(angle) > 1e-5 else { return image }
        let ext = image.extent
        let center = CGPoint(x: ext.midX, y: ext.midY)
        let t = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
        let size = inscribedSize(ext.size, angle: angle)
        let w = floor(size.width), h = floor(size.height)
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        return image.clampedToExtent()
            .transformed(by: t)
            .cropped(to: rect)
            .transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
    }
}
