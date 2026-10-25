import SwiftUI

/// The photo as shot, with the suggested crop drawn on top. When the horizon is levelled the
/// crop is drawn rotated, exactly where it will be cut from the original. Drag inside to move
/// the crop, drag a corner or edge handle to resize it, or pinch.
struct BeforeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            if let result = model.result {
                let layout = Layout(result: result, size: geo.size)
                Canvas { ctx, _ in draw(in: &ctx, result: result, layout: layout) }
                    .gesture(dragGesture(layout))
                    .simultaneousGesture(magnifyGesture)
                    .onContinuousHover { phase in
                        guard model.dragStart == nil else { return }
                        if case .active(let location) = phase {
                            cursor(for: layout.handle(at: location, crop: model.crop)).set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
            }
        }
    }

    /// Geometry linking view points, the original image and the straightened base image.
    struct Layout {
        let fit: CGRect
        let baseSize: CGSize   // straightened image, in view points
        let theta: CGFloat

        init(result: AnalysisResult, size: CGSize) {
            let o = CGSize(width: result.original.width, height: result.original.height)
            let k = min(size.width / o.width, size.height / o.height)
            fit = CGRect(x: (size.width - o.width * k) / 2, y: (size.height - o.height * k) / 2,
                         width: o.width * k, height: o.height * k)
            baseSize = CGSize(width: CGFloat(result.base.width) * k, height: CGFloat(result.base.height) * k)
            theta = result.scene.appliedRotation
        }

        /// Normalized base rect in the rotated drawing frame (origin at image centre).
        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - 0.5) * baseSize.width, y: (r.minY - 0.5) * baseSize.height,
                   width: r.width * baseSize.width, height: r.height * baseSize.height)
        }

        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - 0.5) * baseSize.width, y: (p.y - 0.5) * baseSize.height)
        }

        /// View point -> the rotated drawing frame used by `rect(_:)`.
        func framePoint(_ p: CGPoint) -> CGPoint {
            let x = p.x - fit.midX, y = p.y - fit.midY
            let c = cos(theta), s = sin(theta)
            return CGPoint(x: x * c + y * s, y: -x * s + y * c)
        }

        /// Which part of the crop is under a view point.
        func handle(at p: CGPoint, crop: CGRect) -> CropHandle {
            let q = framePoint(p), r = rect(crop)
            let tol: CGFloat = 10
            let nearL = abs(q.x - r.minX) < tol, nearR = abs(q.x - r.maxX) < tol
            let nearT = abs(q.y - r.minY) < tol, nearB = abs(q.y - r.maxY) < tol
            let inX = q.x > r.minX - tol && q.x < r.maxX + tol
            let inY = q.y > r.minY - tol && q.y < r.maxY + tol
            switch (nearL, nearR, nearT, nearB) {
            case (true, _, true, _): return .topLeft
            case (_, true, true, _): return .topRight
            case (true, _, _, true): return .bottomLeft
            case (_, true, _, true): return .bottomRight
            default: break
            }
            if nearL && inY { return .left }
            if nearR && inY { return .right }
            if nearT && inX { return .top }
            if nearB && inX { return .bottom }
            return .move
        }

        /// View-space drag translation -> normalized base-space translation.
        func baseDelta(_ t: CGSize) -> CGSize {
            let c = cos(theta), s = sin(theta)
            return CGSize(width: (t.width * c + t.height * s) / baseSize.width,
                          height: (-t.width * s + t.height * c) / baseSize.height)
        }
    }

    private func draw(in ctx: inout GraphicsContext, result: AnalysisResult, layout: Layout) {
        ctx.draw(Image(decorative: result.original, scale: 1), in: layout.fit)
        ctx.clip(to: Path(layout.fit))
        ctx.translateBy(x: layout.fit.midX, y: layout.fit.midY)
        // Base -> original is a clockwise rotation by theta on screen.
        ctx.rotate(by: .radians(layout.theta))

        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        if model.showHeatmap, let heat = result.heatmap {
            var heatCtx = ctx
            heatCtx.opacity = 0.6
            heatCtx.draw(Image(decorative: heat, scale: 1), in: layout.rect(unit))
        }

        let crop = layout.rect(model.crop)
        var mask = Path(CGRect(x: -5000, y: -5000, width: 10000, height: 10000))
        mask.addRect(crop)
        ctx.fill(mask, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

        if abs(layout.theta) > 0.0005 {
            ctx.stroke(Path(layout.rect(unit)), with: .color(.white.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }

        if model.showThirds { drawThirds(in: ctx, rect: crop) }

        if model.showDetections { drawDetections(in: ctx, scene: result.scene, layout: layout) }

        ctx.stroke(Path(crop), with: .color(.white), lineWidth: 2)
        // Corner and edge-midpoint resize handles.
        for corner in [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
                       CGPoint(x: crop.minX, y: crop.maxY), CGPoint(x: crop.maxX, y: crop.maxY)] {
            ctx.fill(Path(CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)), with: .color(.white))
        }
        for (mid, horizontal) in [(CGPoint(x: crop.midX, y: crop.minY), true), (CGPoint(x: crop.midX, y: crop.maxY), true),
                                  (CGPoint(x: crop.minX, y: crop.midY), false), (CGPoint(x: crop.maxX, y: crop.midY), false)] {
            let bar = horizontal ? CGRect(x: mid.x - 12, y: mid.y - 3, width: 24, height: 6)
                                 : CGRect(x: mid.x - 3, y: mid.y - 12, width: 6, height: 24)
            ctx.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(.white))
        }

        let f = layout.point(result.scene.focalPoint)
        ctx.stroke(Path(ellipseIn: CGRect(x: f.x - 7, y: f.y - 7, width: 14, height: 14)),
                   with: .color(.yellow), lineWidth: 2)
    }

    private func drawDetections(in ctx: GraphicsContext, scene: SceneAnalysis, layout: Layout) {
        for s in scene.subjects {
            let color: Color = switch s.kind {
            case .face: .green
            case .person: .blue
            case .animal: .orange
            case .object: .yellow
            }
            ctx.stroke(Path(layout.rect(s.rect)), with: .color(color.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.5, dash: s.kind == .object ? [5, 3] : []))
        }
        for face in scene.faces where abs(face.lookDirection) > 0.3 {
            let c = layout.point(CGPoint(x: face.rect.midX, y: face.rect.midY))
            var arrow = Path()
            let dx = face.lookDirection * layout.rect(face.rect).width * 0.8
            arrow.move(to: c)
            arrow.addLine(to: CGPoint(x: c.x + dx, y: c.y))
            ctx.stroke(arrow, with: .color(.green), lineWidth: 2)
        }
        for j in scene.joints {
            let p = layout.point(j)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.cyan))
        }
        if let hy = scene.horizonY {
            var line = Path()
            line.move(to: layout.point(CGPoint(x: 0, y: hy)))
            line.addLine(to: layout.point(CGPoint(x: 1, y: hy)))
            ctx.stroke(line, with: .color(.cyan), style: StrokeStyle(lineWidth: 1.5, dash: [8, 4]))
        }
    }

    private func dragGesture(_ layout: Layout) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if model.dragStart == nil {
                    model.dragStart = model.crop
                    model.dragHandle = layout.handle(at: value.startLocation, crop: model.crop)
                    if model.dragHandle == .move { NSCursor.closedHand.set() }
                }
                apply(value, layout: layout, final: false)
            }
            .onEnded { value in
                apply(value, layout: layout, final: true)
                model.dragStart = nil
                cursor(for: layout.handle(at: value.location, crop: model.crop)).set()
            }
    }

    private func apply(_ value: DragGesture.Value, layout: Layout, final: Bool) {
        guard let start = model.dragStart else { return }
        // Shift temporarily inverts the aspect-ratio lock.
        let locked = model.lockAspect != NSEvent.modifierFlags.contains(.shift)
        model.resizeCrop(from: start, handle: model.dragHandle, delta: layout.baseDelta(value.translation),
                         lockAspect: locked, final: final)
    }

    private func cursor(for handle: CropHandle) -> NSCursor {
        switch handle {
        case .move: .openHand
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        case .topLeft: .frameResize(position: .topLeft, directions: .all)
        case .topRight: .frameResize(position: .topRight, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if model.scaleStart == nil { model.scaleStart = model.cropScale }
                model.setCropScale(min(1, max(0.3, (model.scaleStart ?? 1) / value.magnification)))
            }
            .onEnded { _ in
                model.scaleStart = nil
                model.refreshAesthetic()
            }
    }
}

/// The cropped (and levelled) result.
struct AfterView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let image = model.croppedImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .overlay {
                    if model.showThirds {
                        Canvas { ctx, size in drawThirds(in: ctx, rect: CGRect(origin: .zero, size: size)) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

func drawThirds(in ctx: GraphicsContext, rect: CGRect) {
    var p = Path()
    for i in 1...2 {
        let x = rect.minX + rect.width * CGFloat(i) / 3
        let y = rect.minY + rect.height * CGFloat(i) / 3
        p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
    }
    ctx.stroke(p, with: .color(.white.opacity(0.45)), lineWidth: 0.75)
}

extension Grid {
    /// Saliency as a transparent-to-red overlay image.
    func heatmapImage() -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = min(1, max(0, values[i]))
            // Premultiplied RGBA: yellow at low attention, red at the peak.
            let a = v
            pixels[i * 4 + 0] = UInt8(255 * a)
            pixels[i * 4 + 1] = UInt8(255 * (1 - v) * 0.8 * a)
            pixels[i * 4 + 2] = 0
            pixels[i * 4 + 3] = UInt8(255 * a)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
