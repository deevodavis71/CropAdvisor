import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Everything produced by analysing one photo.
struct AnalysisResult {
    var url: URL
    var metadata: PhotoMetadata
    /// Working-resolution image exactly as shot (for the "before" view).
    var original: CGImage
    /// Working-resolution image after straightening; crops are normalized to this.
    var base: CGImage
    var scene: SceneAnalysis
    var heatmap: CGImage?
    var engine: CropEngine
    var suggestions: [CropSuggestion]
}

enum LevelMode: String, CaseIterable {
    case auto = "Auto", on = "On", off = "Off"
}

enum Pipeline {
    /// Tilts outside this range are either negligible or probably intentional.
    static let straightenRange: ClosedRange<Double> = 0.3...12
    /// Print stage timings (used by the command-line mode).
    static var logTimings = false

    private static func timed<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let start = Date()
        defer { if logTimings { print(String(format: "  [%@ %.2f s]", label, Date().timeIntervalSince(start))) } }
        return try work()
    }

    static func analyze(url: URL, level: LevelMode) throws -> AnalysisResult {
        let working = try ImageLoader.loadImage(url: url, maxLongSide: ImageLoader.workingLongSide)
        guard let original = timed("decode", { ImageLoader.render(working) }) else { throw ImageLoaderError.unreadable(url) }

        let horizon = SceneAnalyzer.detectHorizonAngle(original)
        var scene = timed("vision") { SceneAnalyzer.analyze(original, detectedHorizonAngle: horizon, appliedRotation: 0) }
        var base = original

        if let h = horizon, straightenRange.contains(abs(Double(h)) * 180 / .pi),
           level == .on || (level == .auto && looksLikeLandscape(scene)),
           let levelled = ImageLoader.render(Straightener.apply(working, angle: -h)) {
            base = levelled
            scene = timed("vision (levelled)") { SceneAnalyzer.analyze(base, detectedHorizonAngle: horizon, appliedRotation: -h) }
        }
        let engine = CropEngine(scene: scene, cameraAspect: CGFloat(original.width) / CGFloat(original.height))
        var suggestions = timed("search") { engine.suggestions() }
        timed("aesthetics") { Aesthetics.rerank(&suggestions, in: base) }

        return AnalysisResult(url: url, metadata: ImageLoader.metadata(for: url), original: original,
                              base: base, scene: scene, heatmap: scene.saliency.heatmapImage(), engine: engine, suggestions: suggestions)
    }

    /// Vision's horizon detector also fires on perspective lines (roads, kerbs, tables), so only
    /// level automatically when the scene looks like a real horizon: no people or animals, and a
    /// sky clearly brighter than the foreground.
    static func looksLikeLandscape(_ scene: SceneAnalysis) -> Bool {
        guard !scene.subjects.contains(where: { $0.kind != .object }) else { return false }
        let lum = scene.luminance
        let sky = lum.mean(in: CGRect(x: 0, y: 0, width: 1, height: 0.25))
        let ground = lum.mean(in: CGRect(x: 0, y: 0.75, width: 1, height: 0.25))
        return sky - ground > 0.1
    }

    static func pixelRect(_ normalized: CGRect, in image: CGImage) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return CGRect(x: normalized.minX * w, y: normalized.minY * h,
                      width: normalized.width * w, height: normalized.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
    }

    static func crop(_ image: CGImage, to normalized: CGRect) -> CGImage? {
        image.cropping(to: pixelRect(normalized, in: image))
    }
}

/// Apple's on-device aesthetics model, used as a second opinion on the heuristic ranking.
enum Aesthetics {
    static func score(_ image: CGImage) -> Double? {
        let request = VNCalculateImageAestheticsScoresRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let obs = request.results?.first else { return nil }
        return (Double(obs.overallScore) + 1) / 2
    }

    static func rerank(_ suggestions: inout [CropSuggestion], in base: CGImage) {
        for i in suggestions.indices {
            if let crop = Pipeline.crop(base, to: suggestions[i].rect) {
                suggestions[i].score.aesthetic = score(crop)
            }
        }
        suggestions.sort { $0.score.total > $1.score.total }
    }
}

enum ExportFormat: String, CaseIterable {
    case jpeg = "JPEG"
    case tiff = "TIFF (16-bit)"
    case heic = "HEIC"

    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .heic: .heic
        }
    }
}

enum Exporter {
    /// Re-develops the RAW at full resolution, applies the same straightening and crop, and
    /// writes it with the original camera metadata.
    static func export(source: URL, crop: CGRect, rotation: CGFloat, to destination: URL, format: ExportFormat) throws {
        var image = try ImageLoader.loadImage(url: source, maxLongSide: nil)
        image = Straightener.apply(image, angle: rotation)
        let ext = image.extent
        // Normalized top-left rect -> Core Image bottom-left pixel rect.
        let rect = CGRect(x: crop.minX * ext.width, y: (1 - crop.maxY) * ext.height,
                          width: crop.width * ext.width, height: crop.height * ext.height).integral
            .intersection(ext)
        image = image.cropped(to: rect).transformed(by: .init(translationX: -rect.minX, y: -rect.minY))

        let colorSpace = format == .jpeg ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpace(name: CGColorSpace.displayP3)!
        guard let cg = ImageLoader.context.createCGImage(image, from: image.extent,
                                                         format: format == .tiff ? .RGBA16 : .RGBA8,
                                                         colorSpace: colorSpace) else {
            throw ImageLoaderError.unreadable(source)
        }

        let metadata = ImageLoader.metadata(for: source)
        var props = metadata.properties
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = cg.width
        props[kCGImagePropertyPixelHeight] = cg.height
        props.removeValue(forKey: kCGImagePropertyDepth)
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = cg.width
            exif[kCGImagePropertyExifPixelYDimension] = cg.height
            props[kCGImagePropertyExifDictionary] = exif
        }
        // Drop RAW-specific dictionaries that don't belong in a rendered file.
        for key in [kCGImagePropertyMakerNikonDictionary, kCGImagePropertyDNGDictionary, kCGImagePropertyRawDictionary] {
            props.removeValue(forKey: key)
        }
        if format != .tiff { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }

        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
