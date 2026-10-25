import CoreGraphics
import Foundation

struct AspectRatio: Hashable {
    let name: String
    /// Width / height in pixels; nil means "same as the photo".
    let value: CGFloat?

    static let original = AspectRatio(name: "Original", value: nil)
    static let standard: [AspectRatio] = [
        .original,
        AspectRatio(name: "3:2", value: 3.0 / 2), AspectRatio(name: "2:3", value: 2.0 / 3),
        AspectRatio(name: "4:3", value: 4.0 / 3), AspectRatio(name: "3:4", value: 3.0 / 4),
        AspectRatio(name: "5:4", value: 5.0 / 4), AspectRatio(name: "4:5", value: 4.0 / 5),
        AspectRatio(name: "1:1", value: 1), AspectRatio(name: "16:9", value: 16.0 / 9),
    ]
}

/// The cropping guidelines we score against, each in 0…1.
enum Criterion: String, CaseIterable, Identifiable {
    case composition = "Subject placement"
    case retention = "Subject kept"
    case emphasis = "Subject emphasis"
    case edges = "Clean edges"
    case slicing = "Nothing awkwardly cut"
    case leadRoom = "Room to look into"
    case joints = "Avoids cutting at joints"
    case horizon = "Horizon placement"
    case resolution = "Resolution kept"

    var id: String { rawValue }

    var weight: Double {
        switch self {
        case .composition: 0.22
        case .retention: 0.16
        case .emphasis: 0.14
        case .edges: 0.12
        case .slicing: 0.08
        case .leadRoom: 0.10
        case .joints: 0.06
        case .horizon: 0.07
        case .resolution: 0.10
        }
    }
}

enum Edge: String, CaseIterable { case top, bottom, left, right }

struct CropScore {
    var criteria: [Criterion: Double] = [:]
    /// Apple's learned aesthetics score for the cropped image, mapped to 0…1.
    var aesthetic: Double?
    var worstEdge: (edge: Edge, distraction: Double, bright: Bool)?

    var heuristic: Double {
        let present = criteria.keys
        let wsum = present.reduce(0) { $0 + $1.weight }
        guard wsum > 0 else { return 0 }
        return present.reduce(0) { $0 + $1.weight * criteria[$1]! } / wsum
    }

    var total: Double {
        guard let aesthetic else { return heuristic }
        return 0.8 * heuristic + 0.2 * aesthetic
    }
}

struct CropSuggestion: Identifiable {
    let id = UUID()
    var aspect: AspectRatio
    var aspectLabel: String
    /// Normalized to the analysis image, top-left origin.
    var rect: CGRect
    var score: CropScore
    var isUncropped: Bool { rect.width > 0.999 && rect.height > 0.999 }
}

struct CropEngine {
    let scene: SceneAnalysis
    /// Shape of the analysis image (after any levelling), for crop geometry.
    private let imageAspect: CGFloat
    /// Shape of the photo as shot, which "Original" means even after levelling.
    private let cameraAspect: CGFloat
    private let minArea: CGFloat = 0.2

    init(scene: SceneAnalysis, cameraAspect: CGFloat? = nil) {
        self.scene = scene
        imageAspect = scene.pixelSize.width / scene.pixelSize.height
        self.cameraAspect = cameraAspect ?? imageAspect
    }

    // MARK: - Search

    func suggestions() -> [CropSuggestion] {
        var results: [CropSuggestion] = []
        let uncropped = CGRect(x: 0, y: 0, width: 1, height: 1)
        results.append(CropSuggestion(aspect: .original, aspectLabel: "Uncropped", rect: uncropped,
                                      score: evaluate(uncropped)))

        for aspect in AspectRatio.standard {
            let ratio = aspect.value ?? cameraAspect
            // Skip ratios equal to the photo's own; "Original" covers them.
            if aspect.value != nil && abs(ratio - cameraAspect) / cameraAspect < 0.015 { continue }
            guard let best = bestCrop(ratio: ratio) else { continue }
            let label = aspect.value == nil ? "Original (\(Self.ratioName(cameraAspect)))" : aspect.name
            results.append(CropSuggestion(aspect: aspect, aspectLabel: label, rect: best.rect, score: best.score))
        }
        return results.sorted { $0.score.total > $1.score.total }
    }

    /// Largest normalized rect of the given pixel aspect ratio that fits the image.
    func maxSize(ratio: CGFloat) -> CGSize {
        ratio > imageAspect ? CGSize(width: 1, height: imageAspect / ratio)
                            : CGSize(width: ratio / imageAspect, height: 1)
    }

    private func bestCrop(ratio: CGFloat) -> (rect: CGRect, score: CropScore)? {
        let full = maxSize(ratio: ratio)
        var candidates: [(CGRect, Double)] = []

        // Coarse grid over scale and position.
        for scale in stride(from: 1.0, through: 0.44, by: -0.07) {
            let size = CGSize(width: full.width * scale, height: full.height * scale)
            guard size.width * size.height >= minArea else { continue }
            for y in positions(range: 1 - size.height, step: 0.02) {
                for x in positions(range: 1 - size.width, step: 0.02) {
                    let r = CGRect(origin: CGPoint(x: x, y: y), size: size)
                    if let s = evaluateIfValid(r) { candidates.append((r, s.total)) }
                }
            }
        }
        guard !candidates.isEmpty else { return nil }

        // Refine the strongest few with a finer local search.
        candidates.sort { $0.1 > $1.1 }
        var best: (CGRect, CropScore)?
        for (seed, _) in candidates.prefix(4) {
            var current = seed
            var currentScore = evaluate(current).total
            var step: CGFloat = 0.01
            while step >= 0.0025 {
                var improved = false
                for (dx, dy, ds) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] as [(CGFloat, CGFloat, CGFloat)] {
                    let s = 1 + ds * step * 2
                    var w = current.width * s, h = current.height * s
                    if w > full.width || h > full.height { w = full.width; h = full.height }
                    let cx = current.midX + dx * step, cy = current.midY + dy * step
                    let r = CGRect(x: min(max(cx - w / 2, 0), 1 - w), y: min(max(cy - h / 2, 0), 1 - h), width: w, height: h)
                    if let sc = evaluateIfValid(r), sc.total > currentScore + 1e-5 {
                        current = r; currentScore = sc.total; improved = true
                    }
                }
                if !improved { step /= 2 }
            }
            let score = evaluate(current)
            if score.total > (best?.1.total ?? -1) { best = (current, score) }
        }
        return best.map { (rect: $0.0, score: $0.1) }
    }

    private func positions(range: CGFloat, step: CGFloat) -> [CGFloat] {
        guard range > 0.0001 else { return [0] }
        var p = Array(stride(from: 0, to: range, by: step))
        p.append(range)
        return p
    }

    // MARK: - Scoring

    /// Hard constraints: keep important faces/animals whole, keep the focal point well inside,
    /// and don't throw away too much of the file.
    func violations(_ c: CGRect) -> [String] {
        var v: [String] = []
        if c.area < minArea - 1e-6 { v.append("Keeps less than 20% of the image") }
        if scene.mustContain.contains(where: { !c.contains($0, tolerance: 0.002) }) {
            v.append(scene.focalIsFace ? "Cuts into a face" : "Cuts into the main subject")
        }
        let f = scene.focalPoint
        if !c.insetBy(dx: c.width * 0.1, dy: c.height * 0.1).contains(f) {
            v.append("The main subject sits too close to the frame edge")
        }
        return v
    }

    private func evaluateIfValid(_ c: CGRect) -> CropScore? {
        violations(c).isEmpty ? evaluate(c) : nil
    }

    func evaluate(_ c: CGRect) -> CropScore {
        var s = CropScore()
        let sal = scene.saliency

        // Keep what draws the eye.
        let retained = sal.fraction(in: c)
        s.criteria[.retention] = smoothstep(0.55, 0.95, retained)

        // Rule of thirds (or deliberate centring) for the focal point.
        let f = CGPoint(x: (scene.focalPoint.x - c.minX) / c.width, y: (scene.focalPoint.y - c.minY) / c.height)
        let targets: [(CGPoint, Double)] = scene.focalIsFace
            // Eyes belong on the upper third line.
            ? [(CGPoint(x: 1 / 3, y: 1 / 3), 1), (CGPoint(x: 2 / 3, y: 1 / 3), 1), (CGPoint(x: 0.5, y: 1 / 3), 0.85)]
            : [(CGPoint(x: 1 / 3, y: 1 / 3), 1), (CGPoint(x: 2 / 3, y: 1 / 3), 1),
               (CGPoint(x: 1 / 3, y: 2 / 3), 1), (CGPoint(x: 2 / 3, y: 2 / 3), 1),
               (CGPoint(x: 0.5, y: 0.5), 0.6)]
        s.criteria[.composition] = targets.map { t, w in
            w * exp(-pow(hypot(f.x - t.x, f.y - t.y) / 0.09, 2))
        }.max() ?? 0

        // Fill the frame: subject should be prominent but not cramped.
        let subjectFill = scene.primarySubject.intersection(c).area / c.area
        let fillScore = exp(-pow(log(max(subjectFill, 0.001) / 0.28), 2) / (2 * 0.8 * 0.8))
        let density = c.area > 0 ? retained / c.area : 0
        s.criteria[.emphasis] = 0.5 * fillScore + 0.5 * smoothstep(1.0, 1.8, density)

        // Distractions along the borders: salient or bright areas that pull the eye out.
        let edge = edgeDistraction(c)
        s.worstEdge = edge
        s.criteria[.edges] = 1 - min(1, edge.distraction)

        // Objects sliced by the frame edge.
        var slice = 0.0, sliceWeight = 0.0
        // Bodies around a face are judged by the joints rule instead; portraits crop them routinely.
        let faceRects = scene.faces.map(\.rect)
        for subject in scene.subjects where subject.kind != .face
            && !faceRects.contains(where: { subject.rect.contains($0) }) {
            let inside = subject.rect.intersection(c).area / max(subject.rect.area, 1e-6)
            let w = subject.weight * Double(min(1, subject.rect.area * 8))
            sliceWeight += w
            if inside > 0.05 && inside < 0.97 {
                slice += w * (subject.kind == .person ? 0.5 : 1) * Double(min(inside, 1 - inside) * 2)
            }
        }
        if sliceWeight > 0 { s.criteria[.slicing] = 1 - min(1, slice / max(sliceWeight, 0.5)) }

        // Lead room in the direction the main subject is looking.
        if let face = scene.faces.first, abs(face.lookDirection) > 0.3, c.contains(face.rect, tolerance: 0) {
            let front = face.lookDirection > 0 ? c.maxX - face.rect.midX : face.rect.midX - c.minX
            let ratio = front / c.width
            s.criteria[.leadRoom] = smoothstep(0.35, 0.62, ratio)
        }

        // Frame edges passing through elbows, knees, wrists, ankles or the neck.
        if !scene.joints.isEmpty {
            var penalty = 0.0
            let tol: CGFloat = 0.025
            for p in scene.joints {
                let inX = p.x > c.minX - tol && p.x < c.maxX + tol
                let inY = p.y > c.minY - tol && p.y < c.maxY + tol
                for d in [inY ? abs(p.x - c.minX) / c.width : 1, inY ? abs(p.x - c.maxX) / c.width : 1,
                          inX ? abs(p.y - c.minY) / c.height : 1, inX ? abs(p.y - c.maxY) / c.height : 1] where d < tol {
                    penalty += Double(1 - d / tol)
                }
            }
            s.criteria[.joints] = max(0, 1 - penalty * 0.6)
        }

        // A horizon on a third line rather than through the middle.
        if let hy = scene.horizonY, hy > c.minY + c.height * 0.05, hy < c.maxY - c.height * 0.05 {
            let y = Double((hy - c.minY) / c.height)
            s.criteria[.horizon] = max(exp(-pow((y - 1.0 / 3) / 0.07, 2)), exp(-pow((y - 2.0 / 3) / 0.07, 2)))
        }

        // Don't discard so much that prints suffer.
        s.criteria[.resolution] = smoothstep(0.2, 0.6, Double(c.area))

        // Small nudge towards keeping the camera's native shape.
        let ratio = c.width * scene.pixelSize.width / (c.height * scene.pixelSize.height)
        if abs(ratio - cameraAspect) / cameraAspect < 0.015 {
            s.criteria[.resolution] = min(1, (s.criteria[.resolution] ?? 0) + 0.05)
        }
        return s
    }

    func edgeDistraction(_ c: CGRect) -> (edge: Edge, distraction: Double, bright: Bool) {
        let band = min(c.width, c.height) * 0.07
        let sal = scene.saliency, lum = scene.luminance, detail = scene.detail
        let interiorSal = max(sal.mean(in: c), 0.02)
        let interiorLum = lum.mean(in: c)
        let interiorDetail = max(detail.mean(in: c), 0.01)
        var worst: (Edge, Double, Bool) = (.top, 0, false)
        for edge in Edge.allCases {
            let r: CGRect
            switch edge {
            case .top: r = CGRect(x: c.minX, y: c.minY, width: c.width, height: band)
            case .bottom: r = CGRect(x: c.minX, y: c.maxY - band, width: c.width, height: band)
            case .left: r = CGRect(x: c.minX, y: c.minY, width: band, height: c.height)
            case .right: r = CGRect(x: c.maxX - band, y: c.minY, width: band, height: c.height)
            }
            let salient = max(0, sal.mean(in: r) / interiorSal - 0.6) / 1.2
            let bright = max(0, lum.mean(in: r) - interiorLum - 0.06) * 4
            // More edges/texture than the rest of the frame: clutter or an object poking in.
            let busy = min(1, max(0, detail.mean(in: r) / interiorDetail - 1) / 0.6)
            let d = 0.4 * salient + 0.25 * bright + 0.35 * busy
            if d > worst.1 { worst = (edge, d, bright > salient) }
        }
        return worst
    }

    // MARK: - Advice

    /// Human-readable explanation of why a crop works, compared to the uncropped frame.
    func reasons(for suggestion: CropSuggestion, baseline: CropScore) -> (reasons: [String], warnings: [String]) {
        var reasons: [String] = []
        var warnings = violations(suggestion.rect)
        let c = suggestion.rect, s = suggestion.score

        if abs(scene.appliedRotation) > 0.0005 {
            reasons.append(String(format: "Levels a tilted horizon (rotated %.1f°)", scene.appliedRotation * 180 / .pi))
        } else if let tilt = scene.detectedHorizonAngle,
                  Pipeline.straightenRange.contains(abs(Double(tilt)) * 180 / .pi) {
            warnings.append(String(format: "Possible %.1f° tilt — set Level the horizon to On if it should be level", tilt * 180 / .pi))
        }

        let f = CGPoint(x: (scene.focalPoint.x - c.minX) / c.width, y: (scene.focalPoint.y - c.minY) / c.height)
        let what = scene.focalIsFace ? "the subject's eyes" : "the main subject"
        if (s.criteria[.composition] ?? 0) > 0.6 {
            if abs(f.x - 0.5) < 0.08 && !scene.focalIsFace && abs(f.y - 0.5) < 0.08 {
                reasons.append("Centres \(what) for a calm, symmetrical composition")
            } else if scene.focalIsFace && abs(f.x - 0.5) < 0.08 {
                reasons.append("Places \(what) on the upper third line")
            } else {
                let v = f.y < 0.5 ? "upper" : "lower", h = f.x < 0.5 ? "left" : "right"
                reasons.append("Places \(what) on the \(v)-\(h) rule-of-thirds intersection")
            }
        } else if (s.criteria[.composition] ?? 0) < 0.3 {
            warnings.append("Subject isn't near a thirds point — placement may feel static")
        }

        let baseFill = scene.primarySubject.area
        let newFill = scene.primarySubject.intersection(c).area / c.area
        if !suggestion.isUncropped && newFill > baseFill * 1.25 {
            reasons.append(String(format: "Tighter framing: subject fills %.0f%% of the frame (was %.0f%%)",
                                  newFill * 100, baseFill * 100))
        }

        if let worst = baseline.worstEdge, worst.distraction > 0.25 {
            let trimmed: Bool
            switch worst.edge {
            case .top: trimmed = c.minY > 0.03
            case .bottom: trimmed = c.maxY < 0.97
            case .left: trimmed = c.minX > 0.03
            case .right: trimmed = c.maxX < 0.97
            }
            if trimmed && (s.criteria[.edges] ?? 0) > 1 - worst.distraction + 0.1 {
                let kind = worst.bright ? "bright" : "busy or eye-catching"
                reasons.append("Trims a \(kind) distraction along the \(worst.edge.rawValue) edge")
            }
        }
        if let e = s.worstEdge, e.distraction > 0.45 {
            warnings.append("Something \(e.bright ? "bright" : "busy or eye-catching") remains near the \(e.edge.rawValue) edge")
        }

        if let lead = s.criteria[.leadRoom] {
            if lead > 0.7 { reasons.append("Leaves space in the direction the subject is looking") }
            else if lead < 0.3 { warnings.append("Subject looks out of the frame — little room in front") }
        }
        if let j = s.criteria[.joints] {
            if j > 0.95 { reasons.append("Frame edges avoid limb joints") }
            else if j < 0.6 { warnings.append("An edge cuts close to a joint (knee, elbow, wrist…)") }
        }
        if let h = s.criteria[.horizon] {
            if h > 0.6 { reasons.append("Puts the horizon on a third line, not through the middle") }
            else if h < 0.2 { warnings.append("Horizon sits near the middle of the frame") }
        }
        if let sl = s.criteria[.slicing], sl < 0.6 {
            warnings.append("Partially cuts off a prominent object")
        }

        let kept = c.area
        if suggestion.isUncropped {
            reasons.append("Keeps the full frame")
        } else {
            reasons.append(String(format: "Keeps %.0f%% of the pixels", kept * 100))
            if kept < 0.4 { warnings.append("Heavy crop — large prints may lose detail") }
        }
        return (reasons, warnings)
    }

    static func ratioName(_ r: CGFloat) -> String {
        for a in AspectRatio.standard.dropFirst() {
            if let v = a.value, abs(v - r) / r < 0.015 { return a.name }
        }
        return String(format: "%.2f:1", r)
    }
}

private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}
