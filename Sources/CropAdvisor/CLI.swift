import Foundation

/// `CropAdvisor --analyze <photo> [--export <out.jpg>] [--dop]` prints the advice without the UI;
/// `--dop` writes the camera-ratio crop into the photo's PhotoLab sidecar.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--analyze"), i + 1 < args.count else {
            print("usage: CropAdvisor --analyze <photo> [--export <out.jpg>] [--dop] [--level auto|on|off]")
            return 2
        }
        let url = URL(fileURLWithPath: args[i + 1])
        do {
            Pipeline.logTimings = true
            let start = Date()
            var level = LevelMode.auto
            if let k = args.firstIndex(of: "--level"), k + 1 < args.count {
                level = LevelMode.allCases.first { $0.rawValue.lowercased() == args[k + 1].lowercased() } ?? .auto
            }
            let result = try Pipeline.analyze(url: url, level: level)
            let s = result.scene
            print("Analysed \(url.lastPathComponent) in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
            print("  working size \(Int(s.pixelSize.width))x\(Int(s.pixelSize.height)), full \(result.metadata.fullPixelSize)")
            print("  camera: \(result.metadata.camera ?? "?")  lens: \(result.metadata.lens ?? "?")  \(result.metadata.exposure ?? "")")
            print("  horizon angle: \(s.detectedHorizonAngle.map { String(format: "%.2f°", $0 * 180 / .pi) } ?? "none"), applied \(String(format: "%.2f°", s.appliedRotation * 180 / .pi)), horizon line y: \(s.horizonY.map { String(format: "%.2f", $0) } ?? "none")")
            print("  faces: \(s.faces.count)  subjects: \(s.subjects.map { "\($0.kind.rawValue)@\(fmt($0.rect))" })  joints: \(s.joints.count)")
            print("  primary: \(fmt(s.primarySubject))  focal: (\(String(format: "%.2f, %.2f", s.focalPoint.x, s.focalPoint.y)))")
            let baseline = result.suggestions.first(where: \.isUncropped)!.score
            for sug in result.suggestions {
                print(String(format: "\n%@  total %.0f  heuristic %.0f  aesthetic %@  rect %@", sug.aspectLabel,
                             sug.score.total * 100, sug.score.heuristic * 100,
                             sug.score.aesthetic.map { String(format: "%.0f", $0 * 100) } ?? "-", fmt(sug.rect)))
                print("   " + Criterion.allCases.compactMap { c in sug.score.criteria[c].map { "\(c.rawValue)=\(Int($0 * 100))" } }.joined(separator: ", "))
                let advice = result.engine.reasons(for: sug, baseline: baseline)
                advice.reasons.forEach { print("   + \($0)") }
                advice.warnings.forEach { print("   ! \($0)") }
            }
            if let j = args.firstIndex(of: "--export"), j + 1 < args.count, let best = result.suggestions.first {
                let out = URL(fileURLWithPath: args[j + 1])
                try Exporter.export(source: url, crop: best.rect, rotation: s.appliedRotation, to: out, format: .jpeg)
                print("\nExported best crop to \(out.path)")
            }
            if args.contains("--dop") {
                // Same default as the app: the camera-ratio suggestion.
                guard let dop = DxOSidecar.url(for: url) else { print("\nNo PhotoLab sidecar"); return 1 }
                let pick = result.suggestions.first { $0.aspect == .original && !$0.isUncropped } ?? result.suggestions[0]
                try DxOSidecar.update(dop, crop: pick.rect, result: result)
                print("\nWrote \(pick.aspectLabel) crop \(fmt(pick.rect)) to \(dop.path)")
            }
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func fmt(_ r: CGRect) -> String {
        String(format: "[%.2f %.2f %.2f×%.2f]", r.minX, r.minY, r.width, r.height)
    }
}
