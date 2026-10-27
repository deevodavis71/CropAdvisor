import CoreGraphics
import Foundation
import ImageIO

/// A DxO PhotoLab `.dop` sidecar (Lua-style text) next to a photo, e.g. `DSC_1234.NEF.dop`.
///
/// Conventions, worked out from PhotoLab 9 sidecars:
/// - `CropRect = {x, y, w, h}` is normalized to the raw sensor frame, before EXIF or PhotoLab
///   rotation, with a top-left origin.
/// - When the horizon is levelled, the rect is normalized to the bounding box of the rotated image.
/// - `KeystoningHorizon` is in degrees, positive counter-clockwise.
/// - `CropRatio` is 0 for the original ratio, -1 for free, otherwise width / height.
/// - Edits live in an item's `Settings.Overrides`. The first item is the master photo; any
///   further items are virtual copies.
struct DxOSidecar {
    let url: URL
    private(set) var text: String
    private let lineEnding: String

    static func url(for photo: URL) -> URL? {
        let url = photo.appendingPathExtension("dop")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    init(url: URL) throws {
        self.url = url
        let raw = try String(contentsOf: url, encoding: .utf8)
        lineEnding = raw.contains("\r\n") ? "\r\n" : "\n"
        text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard overridesRange != nil else { throw DxOSidecarError.unrecognized(url) }
    }

    /// Number of versions of the photo: the master plus its virtual copies.
    var versionCount: Int { max(1, text.components(separatedBy: "\n\t\t\tName = ").count - 1) }

    /// PhotoLab's own orientation for the master, which can differ from the EXIF one.
    var orientation: Int? { masterValue("\t\t\tOrientation").flatMap(Int.init) }

    /// True when the master has perspective correction, which shifts the crop slightly.
    var hasPerspectiveCorrection: Bool {
        guard let block = overridesRange.map({ text[$0] }) else { return false }
        return block.contains("\t\t\t\t\tKeystoningActive = true") && block.contains("\t\t\t\t\tKeystoningPoints = {")
    }

    /// Sets the master's crop, replacing any crop and horizon levelling it had.
    mutating func setCrop(sensorRect r: CGRect, horizonDegrees: Double, ratio: Double) {
        var values: [(String, String)] = [
            ("CropActive", "true"),
            ("CropAuto", "false"),
            ("CropRatio", Self.number(ratio)),
            ("CropRect", "{\n" + [r.minX, r.minY, r.width, r.height].map { "\t\t\t\t\t\t\(Self.number(Double($0))),\n" }.joined() + "\t\t\t\t\t}"),
            ("KeystoningHorizonActive", horizonDegrees != 0 ? "true" : "false"),
            ("KeystoningHorizonAuto", "false"),
        ]
        if horizonDegrees != 0 { values.append(("KeystoningHorizon", Self.number(horizonDegrees))) }
        for (key, value) in values { setOverride(key, value) }
    }

    /// Writes the sidecar, keeping the first original as `<name>.dop.bak`.
    func write() throws {
        let backup = url.appendingPathExtension("bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
        try text.replacingOccurrences(of: "\n", with: lineEnding).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes `crop`, and the levelling it was made with, into the sidecar at `url`.
    @discardableResult
    static func update(_ url: URL, crop: CGRect, result: AnalysisResult) throws -> DxOSidecar {
        var dop = try DxOSidecar(url: url)  // re-read, as PhotoLab may have changed it
        let size = result.metadata.fullPixelSize
        let rotation = result.scene.appliedRotation
        let orientation = result.metadata.properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard let rect = sensorRect(crop: crop, displaySize: size, rotation: rotation, exifOrientation: orientation) else {
            throw DxOSidecarError.unsupportedOrientation
        }
        // Keep PhotoLab's ratio lock on when the crop has the camera's shape.
        let inner = Straightener.inscribedSize(size, angle: rotation)
        let aspect = crop.width * inner.width / (crop.height * inner.height)
        let keepsOriginal = abs(aspect / (size.width / size.height) - 1) < 0.005
        dop.setCrop(sensorRect: rect, horizonDegrees: Double(rotation) * 180 / .pi, ratio: keepsOriginal ? 0 : -1)
        try dop.write()
        return dop
    }

    // MARK: - Geometry

    /// Converts a crop from Crop Advisor's frame (normalized, top-left origin, in the levelled image
    /// as displayed) to PhotoLab's `CropRect`. `displaySize` is the full-resolution size after EXIF
    /// orientation; `rotation` is the levelling angle in radians, counter-clockwise. Returns nil
    /// for mirrored orientations.
    static func sensorRect(crop: CGRect, displaySize size: CGSize, rotation: CGFloat, exifOrientation: Int) -> CGRect? {
        // Into the rotated image's bounding box, which shares its centre with the levelled image.
        let inner = Straightener.inscribedSize(size, angle: rotation)
        let s = abs(sin(rotation)), c = abs(cos(rotation))
        let box = CGSize(width: size.width * c + size.height * s, height: size.height * c + size.width * s)
        let d = CGRect(x: ((box.width - inner.width) / 2 + crop.minX * inner.width) / box.width,
                       y: ((box.height - inner.height) / 2 + crop.minY * inner.height) / box.height,
                       width: crop.width * inner.width / box.width,
                       height: crop.height * inner.height / box.height)
        // Undo the EXIF orientation.
        switch exifOrientation {
        case 1: return d
        case 3: return CGRect(x: 1 - d.maxX, y: 1 - d.maxY, width: d.width, height: d.height)
        case 6: return CGRect(x: d.minY, y: 1 - d.maxX, width: d.height, height: d.width)  // shown rotated clockwise
        case 8: return CGRect(x: 1 - d.maxY, y: d.minX, width: d.height, height: d.width)  // shown rotated anticlockwise
        default: return nil
        }
    }

    // MARK: - Text editing

    /// Body of the master's `Overrides = { … }` block, between its braces.
    private var overridesRange: Range<String.Index>? {
        guard let items = text.range(of: "\tItems = {\n"),
              let open = text.range(of: "\n\t\t\t\tOverrides = {\n", range: items.upperBound..<text.endIndex),
              // Start one character back so an empty block's closing line is found too.
              let close = text.range(of: "\n\t\t\t\t},", range: text.index(before: open.upperBound)..<text.endIndex) else { return nil }
        return open.upperBound..<max(open.upperBound, text.index(after: close.lowerBound))
    }

    private func masterValue(_ prefix: String) -> String? {
        guard let items = text.range(of: "\tItems = {\n"),
              let start = text.range(of: "\n\(prefix) = ", range: items.upperBound..<text.endIndex),
              let end = text.range(of: ",\n", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// Replaces or inserts one top-level key in the master's overrides, keeping keys sorted as
    /// PhotoLab writes them.
    private mutating func setOverride(_ key: String, _ value: String) {
        guard let range = overridesRange else { return }
        let indent = "\t\t\t\t\t"
        // Split the block into entries; each starts at a line with exactly five tabs.
        var entries: [(key: String, lines: [String])] = []
        for line in text[range].split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix(indent), !line.hasPrefix(indent + "\t"), let eq = line.range(of: " = ") {
                entries.append((String(line[line.index(line.startIndex, offsetBy: indent.count)..<eq.lowerBound]), [line]))
            } else if !entries.isEmpty {
                entries[entries.count - 1].lines.append(line)
            }
        }
        let entry = (key: key, lines: ["\(indent)\(key) = \(value),"])
        if let i = entries.firstIndex(where: { $0.key == key }) {
            entries[i] = entry
        } else {
            entries.insert(entry, at: entries.firstIndex { $0.key > key } ?? entries.endIndex)
        }
        text.replaceSubrange(range, with: entries.flatMap(\.lines).map { $0 + "\n" }.joined())
    }

    private static func number(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x)
    }
}

enum DxOSidecarError: LocalizedError {
    case unrecognized(URL)
    case unsupportedOrientation

    var errorDescription: String? {
        switch self {
        case .unrecognized(let url): return "“\(url.lastPathComponent)” isn't a PhotoLab sidecar this app understands."
        case .unsupportedOrientation: return "Mirrored photos aren't supported."
        }
    }
}
