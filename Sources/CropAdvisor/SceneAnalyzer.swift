import CoreGraphics
import CoreVideo
import Vision

/// All geometry is normalized to the (straightened) analysis image, top-left origin.
struct FaceInfo {
    var rect: CGRect
    var eyes: CGPoint
    /// -1 = looking left in the frame, +1 = looking right, 0 = towards camera / unknown.
    var lookDirection: CGFloat
}

struct SubjectBox {
    enum Kind: String { case face, person, animal, object }
    var rect: CGRect
    var kind: Kind
    var weight: Double
}

struct SceneAnalysis {
    var pixelSize: CGSize
    var saliency: Grid
    var luminance: Grid
    /// Local contrast (gradient magnitude) — busy, high-contrast areas.
    var detail: Grid
    var faces: [FaceInfo]
    var subjects: [SubjectBox]
    var joints: [CGPoint]
    /// Normalized y of a strong horizontal boundary (sky/land, sea), if any.
    var horizonY: CGFloat?
    /// Horizon tilt reported by Vision, radians.
    var detectedHorizonAngle: CGFloat?
    /// Rotation applied to produce the analysis image, radians CCW.
    var appliedRotation: CGFloat

    /// Regions that must stay fully inside any suggested crop.
    var mustContain: [CGRect]
    /// Region describing the main subject.
    var primarySubject: CGRect
    /// Where the eye lands: eyes of the main face, or the saliency peak of the main subject.
    var focalPoint: CGPoint
    var focalIsFace: Bool
}

enum SceneAnalyzer {
    /// Horizon tilt in radians (CCW positive), or nil if Vision finds no horizon.
    static func detectHorizonAngle(_ image: CGImage) -> CGFloat? {
        let request = VNDetectHorizonRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first.map { CGFloat($0.angle) }
    }

    static func analyze(_ image: CGImage, detectedHorizonAngle: CGFloat?, appliedRotation: CGFloat) -> SceneAnalysis {
        let handler = VNImageRequestHandler(cgImage: image)

        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        let faces = VNDetectFaceLandmarksRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let pose = VNDetectHumanBodyPoseRequest()
        let animals = VNRecognizeAnimalsRequest()
        // Perform individually so one unsupported request doesn't sink the rest.
        for request in [attention, objectness, faces, humans, pose, animals] as [VNRequest] {
            try? handler.perform([request])
        }

        let saliency = attention.results?.first.flatMap { grid(from: $0.pixelBuffer) }
            ?? Grid(width: 1, height: 1, values: [1])
        let luminance = luminanceGrid(image, longSide: 128)

        // Faces
        var faceInfos: [FaceInfo] = []
        for obs in faces.results ?? [] {
            let r = flip(obs.boundingBox)
            var eyes = CGPoint(x: r.midX, y: r.minY + r.height * 0.4)
            var look: CGFloat = 0
            if let lm = obs.landmarks {
                let eyePts = (lm.leftEye?.normalizedPoints ?? []) + (lm.rightEye?.normalizedPoints ?? [])
                if !eyePts.isEmpty {
                    let m = mean(eyePts)
                    eyes = CGPoint(x: obs.boundingBox.minX + m.x * obs.boundingBox.width,
                                   y: 1 - (obs.boundingBox.minY + m.y * obs.boundingBox.height))
                }
                if let nose = lm.nose?.normalizedPoints, !nose.isEmpty {
                    // Nose offset from the face centre indicates which way the head is turned.
                    look = max(-1, min(1, (mean(nose).x - 0.5) / 0.12))
                }
            }
            faceInfos.append(FaceInfo(rect: r, eyes: eyes, lookDirection: look))
        }
        faceInfos.sort { $0.rect.area > $1.rect.area }

        // Subjects
        var subjects: [SubjectBox] = faceInfos.map { SubjectBox(rect: $0.rect, kind: .face, weight: 1) }
        for obs in humans.results ?? [] where obs.confidence > 0.4 {
            subjects.append(SubjectBox(rect: flip(obs.boundingBox), kind: .person, weight: 0.4))
        }
        for obs in animals.results ?? [] where obs.confidence > 0.5 {
            subjects.append(SubjectBox(rect: flip(obs.boundingBox), kind: .animal, weight: 0.9))
        }
        for obs in objectness.results?.first?.salientObjects ?? [] where obs.confidence > 0.2 {
            subjects.append(SubjectBox(rect: flip(obs.boundingBox), kind: .object, weight: 0.8 * Double(obs.confidence)))
        }

        // Joints that look awkward when a frame edge cuts through them.
        let jointNames: [VNHumanBodyPoseObservation.JointName] = [
            .neck, .leftElbow, .rightElbow, .leftWrist, .rightWrist,
            .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
        ]
        var joints: [CGPoint] = []
        for obs in pose.results ?? [] {
            guard let points = try? obs.recognizedPoints(.all) else { continue }
            for name in jointNames {
                if let p = points[name], p.confidence > 0.3 {
                    joints.append(CGPoint(x: p.location.x, y: 1 - p.location.y))
                }
            }
        }

        // Main subject, focal point and hard constraints.
        var mustContain: [CGRect] = []
        var primary: CGRect
        var focal: CGPoint
        var focalIsFace = false
        let largestFace = faceInfos.first?.rect.area ?? 0
        let importantFaces = faceInfos.filter { $0.rect.area >= largestFace * 0.25 && $0.rect.area > 0.0015 }
        let animalBoxes = subjects.filter { $0.kind == .animal }.map(\.rect)
        // The main object is the one that holds the eye most densely, not simply the biggest.
        func pull(_ s: SubjectBox) -> Double { s.weight * saliency.mean(in: s.rect) }
        let objectBoxes = subjects.filter { $0.kind == .object && $0.rect.area > 0.005 }.sorted { pull($0) > pull($1) }

        if !importantFaces.isEmpty {
            primary = importantFaces.map(\.rect).reduce(importantFaces[0].rect) { $0.union($1) }
            for f in importantFaces {
                // Keep hair and chin: pad more above than below.
                let r = f.rect
                mustContain.append(CGRect(x: r.minX - r.width * 0.25, y: r.minY - r.height * 0.4,
                                          width: r.width * 1.5, height: r.height * 1.55).clampedToUnit)
            }
            let eyesY = importantFaces.map(\.eyes.y).reduce(0, +) / CGFloat(importantFaces.count)
            focal = CGPoint(x: primary.midX, y: eyesY)
            if importantFaces.count == 1 { focal = importantFaces[0].eyes }
            focalIsFace = true
        } else if !animalBoxes.isEmpty {
            primary = animalBoxes.reduce(animalBoxes[0]) { $0.union($1) }
            mustContain = animalBoxes.map { $0.insetBy(dx: -$0.width * 0.05, dy: -$0.height * 0.05).clampedToUnit }
            focal = saliency.centroid(in: primary, power: 3) ?? CGPoint(x: primary.midX, y: primary.minY + primary.height * 0.35)
        } else if let top = objectBoxes.first {
            primary = top.rect
            focal = saliency.centroid(in: primary, power: 3) ?? CGPoint(x: primary.midX, y: primary.midY)
        } else {
            primary = saliency.boundingBox(threshold: 0.5) ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            focal = saliency.centroid(in: primary, power: 3) ?? CGPoint(x: 0.5, y: 0.5)
        }

        return SceneAnalysis(
            pixelSize: CGSize(width: image.width, height: image.height),
            saliency: saliency, luminance: luminance, detail: detailGrid(luminance),
            faces: faceInfos, subjects: subjects, joints: joints,
            horizonY: findHorizonLine(luminance),
            detectedHorizonAngle: detectedHorizonAngle, appliedRotation: appliedRotation,
            mustContain: mustContain, primarySubject: primary,
            focalPoint: focal, focalIsFace: focalIsFace)
    }

    // MARK: - Helpers

    private static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    private static func mean(_ pts: [CGPoint]) -> CGPoint {
        let s = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: s.x / CGFloat(pts.count), y: s.y / CGFloat(pts.count))
    }

    private static func grid(from buffer: CVPixelBuffer) -> Grid? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<w { values[y * w + x] = row[x] }
        }
        let maxV = values.max() ?? 0
        if maxV > 0 {
            // Normalize and drop the low-level haze so mass reflects real attention.
            values = values.map { max(0, $0 / maxV - 0.05) / 0.95 }
        }
        return Grid(width: w, height: h, values: values)
    }

    static func luminanceGrid(_ image: CGImage, longSide: Int) -> Grid {
        let scale = CGFloat(longSide) / CGFloat(max(image.width, image.height))
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // CGContext memory is top row first, matching the grid's top-left origin.
        return Grid(width: w, height: h, values: bytes.map { Float($0) / 255 })
    }

    static func detailGrid(_ lum: Grid) -> Grid {
        let w = lum.width, h = lum.height
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let gx = lum[min(x + 1, w - 1), y] - lum[max(x - 1, 0), y]
                let gy = lum[x, min(y + 1, h - 1)] - lum[x, max(y - 1, 0)]
                values[y * w + x] = (gx * gx + gy * gy).squareRoot()
            }
        }
        return Grid(width: w, height: h, values: values)
    }

    /// Finds a strong, frame-wide light/dark boundary such as a horizon or shoreline.
    static func findHorizonLine(_ lum: Grid) -> CGFloat? {
        let w = lum.width, h = lum.height
        let k = max(2, h / 20)
        guard h > 2 * k + 2 else { return nil }
        var best: (y: Int, score: Double, diff: Double, consistency: Double)?
        for y in k..<(h - k) {
            var above = [Double](repeating: 0, count: w), below = above
            for x in 0..<w {
                for dy in 0..<k {
                    above[x] += Double(lum[x, y - 1 - dy])
                    below[x] += Double(lum[x, y + dy])
                }
                above[x] /= Double(k); below[x] /= Double(k)
            }
            let diff = (above.reduce(0, +) - below.reduce(0, +)) / Double(w)
            var agree = 0
            for x in 0..<w {
                let d = above[x] - below[x]
                if abs(d) > 0.02 && (d > 0) == (diff > 0) { agree += 1 }
            }
            let consistency = Double(agree) / Double(w)
            let score = abs(diff) * consistency
            if score > (best?.score ?? 0) { best = (y, score, abs(diff), consistency) }
        }
        guard let b = best, b.diff > 0.08, b.consistency > 0.7 else { return nil }
        let y = CGFloat(b.y) / CGFloat(h)
        return (0.08...0.92).contains(y) ? y : nil
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
    var clampedToUnit: CGRect { intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
    func contains(_ other: CGRect, tolerance: CGFloat) -> Bool {
        insetBy(dx: -tolerance, dy: -tolerance).contains(other)
    }
}
