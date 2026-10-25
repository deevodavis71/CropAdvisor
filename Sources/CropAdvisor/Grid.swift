import CoreGraphics

/// A scalar field over the unit square (top-left origin) backed by a summed-area table,
/// so the sum or mean over any normalized rectangle is O(1).
struct Grid {
    let width: Int
    let height: Int
    let values: [Float]
    private let sat: [Double]

    init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values

        var sat = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            for x in 0..<width {
                rowSum += Double(values[y * width + x])
                sat[(y + 1) * (width + 1) + (x + 1)] = sat[y * (width + 1) + (x + 1)] + rowSum
            }
        }
        self.sat = sat
    }

    subscript(x: Int, y: Int) -> Float { values[y * width + x] }

    var total: Double { sat[sat.count - 1] }

    /// Bilinearly interpolated cumulative sum over [0,u] x [0,v].
    private func cumulative(_ u: CGFloat, _ v: CGFloat) -> Double {
        let fx = Double(min(max(u, 0), 1)) * Double(width)
        let fy = Double(min(max(v, 0), 1)) * Double(height)
        let x0 = min(Int(fx), width), y0 = min(Int(fy), height)
        let x1 = min(x0 + 1, width), y1 = min(y0 + 1, height)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let stride = width + 1
        let a = sat[y0 * stride + x0], b = sat[y0 * stride + x1]
        let c = sat[y1 * stride + x0], d = sat[y1 * stride + x1]
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }

    /// Sum of cell values inside a normalized rectangle (in cell units).
    func sum(in r: CGRect) -> Double {
        cumulative(r.maxX, r.maxY) - cumulative(r.minX, r.maxY)
            - cumulative(r.maxX, r.minY) + cumulative(r.minX, r.minY)
    }

    /// Fraction of the whole field's mass inside a normalized rectangle.
    func fraction(in r: CGRect) -> Double {
        total > 0 ? sum(in: r) / total : 0
    }

    /// Mean cell value inside a normalized rectangle.
    func mean(in r: CGRect) -> Double {
        let cells = Double(r.width * r.height) * Double(width * height)
        return cells > 0 ? sum(in: r) / cells : 0
    }

    /// Weighted centroid of `value^power` inside a normalized rectangle.
    func centroid(in r: CGRect, power: Float = 2) -> CGPoint? {
        let x0 = max(0, Int(r.minX * CGFloat(width))), x1 = min(width, Int(ceil(r.maxX * CGFloat(width))))
        let y0 = max(0, Int(r.minY * CGFloat(height))), y1 = min(height, Int(ceil(r.maxY * CGFloat(height))))
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                let w = Double(powf(self[x, y], power))
                sx += w * (Double(x) + 0.5)
                sy += w * (Double(y) + 0.5)
                sw += w
            }
        }
        guard sw > 0 else { return nil }
        return CGPoint(x: sx / sw / Double(width), y: sy / sw / Double(height))
    }

    /// Bounding box of cells whose value is at least `threshold`.
    func boundingBox(threshold: Float) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where self[x, y] >= threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
                      width: CGFloat(maxX - minX + 1) / CGFloat(width),
                      height: CGFloat(maxY - minY + 1) / CGFloat(height))
    }
}
