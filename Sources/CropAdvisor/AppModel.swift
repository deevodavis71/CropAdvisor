import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case empty
        case analyzing(String)
        case ready
        case failed(String)
    }

    var phase: Phase = .empty
    var result: AnalysisResult?
    /// The photo's DxO PhotoLab sidecar, if it has one.
    var sidecar: DxOSidecar?
    var selectedID: UUID?
    /// The crop currently shown; differs from the selected suggestion after a manual adjustment.
    var crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var cropScore: CropScore?
    var isAdjusted = false
    var exportMessage: String?

    var level: LevelMode = .auto {
        didSet { if oldValue != level, let url = result?.url { open(url) } }
    }
    var showThirds = true
    var showDetections = false
    var showHeatmap = false
    var stacked = false
    var lockAspect = true

    // Transient view state, kept here because the Command Line Tools SDK lacks
    // the compiler plugin for SwiftUI's @State macro.
    var showInspector = true
    var dropTargeted = false
    var dragStart: CGRect?
    var dragHandle: CropHandle = .move
    var scaleStart: CGFloat?

    private var analysisTask: Task<Void, Never>?
    private var aestheticTask: Task<Void, Never>?

    var selected: CropSuggestion? { result?.suggestions.first { $0.id == selectedID } }
    var baseline: CropScore? { result?.suggestions.first(where: \.isUncropped)?.score }

    /// The crop in full-resolution pixels (top-left origin), matching what Export writes.
    /// When the horizon has been levelled these are coordinates in the levelled image.
    var cropPixelRect: CGRect? {
        guard let r = result else { return nil }
        var full = r.metadata.fullPixelSize
        if r.scene.appliedRotation != 0 {
            let s = Straightener.inscribedSize(full, angle: r.scene.appliedRotation)
            full = CGSize(width: floor(s.width), height: floor(s.height))
        }
        return CGRect(x: crop.minX * full.width, y: crop.minY * full.height,
                      width: crop.width * full.width, height: crop.height * full.height).integral
            .intersection(CGRect(origin: .zero, size: full))
    }

    var croppedImage: CGImage? {
        guard let base = result?.base else { return nil }
        return Pipeline.crop(base, to: crop)
    }

    var advice: (reasons: [String], warnings: [String]) {
        guard let result, let baseline, let cropScore, let selected else { return ([], []) }
        var s = selected
        s.rect = crop
        s.score = cropScore
        return result.engine.reasons(for: s, baseline: baseline)
    }

    // MARK: - Loading

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageLoader.supportedTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a NEF (or other) photo to analyse"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        analysisTask?.cancel()
        aestheticTask?.cancel()
        phase = .analyzing("Developing \(url.lastPathComponent)…")
        let level = level
        analysisTask = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try Pipeline.analyze(url: url, level: level) }
            }.value
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let r):
                result = r
                sidecar = DxOSidecar.url(for: url).flatMap { try? DxOSidecar(url: $0) }
                phase = .ready
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                // Prefer the camera's own aspect ratio, even when another shape scores higher.
                select(r.suggestions.first { $0.aspect == .original && !$0.isUncropped } ?? r.suggestions.first)
            case .failure(let error):
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func select(_ suggestion: CropSuggestion?) {
        guard let suggestion else { return }
        selectedID = suggestion.id
        crop = suggestion.rect
        cropScore = suggestion.score
        isAdjusted = false
    }

    // MARK: - Manual adjustment

    /// Moves/scales the crop (normalized base coordinates), keeping it inside the image.
    func adjustCrop(_ rect: CGRect, final: Bool) {
        guard let result else { return }
        var r = rect
        let maxScale = min(1 / r.width, 1 / r.height, 1)
        if maxScale < 1 {
            r = CGRect(x: r.midX - r.width * maxScale / 2, y: r.midY - r.height * maxScale / 2,
                       width: r.width * maxScale, height: r.height * maxScale)
        }
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        crop = r
        isAdjusted = true
        cropScore = result.engine.evaluate(r)
        if final { refreshAesthetic() }
    }

    /// Resizes `start` by dragging one of its handles by `delta` (normalized base units).
    /// With `lockAspect`, the shape is kept and the opposite corner/edge stays put.
    func resizeCrop(from start: CGRect, handle: CropHandle, delta d: CGSize, lockAspect: Bool, final: Bool) {
        guard handle != .move else {
            adjustCrop(start.offsetBy(dx: d.width, dy: d.height), final: final)
            return
        }
        let minSide: CGFloat = 0.05
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.movesLeft { minX = min(max(0, start.minX + d.width), maxX - minSide) }
        if handle.movesRight { maxX = max(min(1, start.maxX + d.width), minX + minSide) }
        if handle.movesTop { minY = min(max(0, start.minY + d.height), maxY - minSide) }
        if handle.movesBottom { maxY = max(min(1, start.maxY + d.height), minY + minSide) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        if lockAspect {
            let aspect = start.width / start.height
            var w: CGFloat, h: CGFloat
            if handle.isCorner {
                // Follow whichever direction the pointer has moved further.
                let scale = max(r.width / start.width, r.height / start.height)
                w = start.width * scale; h = w / aspect
                let availW = handle.movesLeft ? start.maxX : 1 - start.minX
                let availH = handle.movesTop ? start.maxY : 1 - start.minY
                if w > availW { w = availW; h = w / aspect }
                if h > availH { h = availH; w = h * aspect }
                r = CGRect(x: handle.movesLeft ? start.maxX - w : start.minX,
                           y: handle.movesTop ? start.maxY - h : start.minY, width: w, height: h)
            } else if handle.movesLeft || handle.movesRight {
                // Side edge: grow symmetrically in height about the centre line.
                w = r.width; h = w / aspect
                let availH = 2 * min(start.midY, 1 - start.midY)
                if h > availH { h = availH; w = h * aspect }
                r = CGRect(x: handle.movesLeft ? start.maxX - w : start.minX, y: start.midY - h / 2, width: w, height: h)
            } else {
                h = r.height; w = h * aspect
                let availW = 2 * min(start.midX, 1 - start.midX)
                if w > availW { w = availW; h = w / aspect }
                r = CGRect(x: start.midX - w / 2, y: handle.movesTop ? start.maxY - h : start.minY, width: w, height: h)
            }
            if r.width < minSide || r.height < minSide { return }
        }
        adjustCrop(r, final: final)
    }

    /// Scales the current crop about its centre; `scale` is relative to the largest crop of this shape.
    func setCropScale(_ scale: CGFloat) {
        guard let result else { return }
        let ratio = crop.width / crop.height
        let full = result.engine.maxSize(ratio: ratio * result.scene.pixelSize.width / result.scene.pixelSize.height)
        let w = full.width * scale, h = full.height * scale
        adjustCrop(CGRect(x: crop.midX - w / 2, y: crop.midY - h / 2, width: w, height: h), final: false)
    }

    var cropScale: CGFloat {
        guard let result else { return 1 }
        let ratio = crop.width / crop.height
        let full = result.engine.maxSize(ratio: ratio * result.scene.pixelSize.width / result.scene.pixelSize.height)
        return crop.width / full.width
    }

    func resetToSuggestion() { select(selected) }

    func refreshAesthetic() {
        aestheticTask?.cancel()
        guard let image = croppedImage else { return }
        let target = crop
        aestheticTask = Task {
            let value = await Task.detached(priority: .utility) { Aesthetics.score(image) }.value
            guard !Task.isCancelled, target == crop else { return }
            cropScore?.aesthetic = value
        }
    }

    // MARK: - Export

    func export(_ format: ExportFormat) {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        let stem = result.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(stem)-cropped.\(format.type.preferredFilenameExtension ?? "jpg")"
        panel.directoryURL = result.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let crop = crop, rotation = result.scene.appliedRotation, source = result.url
        exportMessage = "Exporting full-resolution \(format.rawValue)…"
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try Exporter.export(source: source, crop: crop, rotation: rotation, to: dest, format: format) }
            }.value
            switch outcome {
            case .success: exportMessage = "Saved \(dest.lastPathComponent)"
            case .failure(let error): exportMessage = "Export failed: \(error.localizedDescription)"
            }
            try? await Task.sleep(for: .seconds(4))
            if exportMessage?.hasPrefix("Exporting") == false { exportMessage = nil }
        }
    }

    /// Writes the current crop and levelling into the photo's PhotoLab sidecar.
    func updateSidecar() {
        guard let result, let url = sidecar?.url else { return }
        let message: String
        do {
            sidecar = try DxOSidecar.update(url, crop: crop, result: result)
            message = "Updated the PhotoLab crop in \(url.lastPathComponent)"
        } catch {
            message = "Couldn’t update \(url.lastPathComponent): \(error.localizedDescription)"
        }
        exportMessage = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if exportMessage == message { exportMessage = nil }
        }
    }
}

/// The part of the crop rectangle being dragged.
enum CropHandle {
    case move, top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
}
