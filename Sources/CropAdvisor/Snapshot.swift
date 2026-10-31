import AppKit
import SwiftUI

/// `CropAdvisor --snapshot <photo> <out.png> [--stacked] [--detections] [--heatmap] [--no-breakdown]`
/// renders the main window offscreen, for checking the UI without screen recording rights.
@MainActor
enum Snapshot {
    static func run(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count else {
            print("usage: CropAdvisor --snapshot <photo> <out.png>")
            exit(2)
        }
        let app = NSApplication.shared
        // A key window is needed for accent colours and tints to render as they do in use.
        app.setActivationPolicy(.regular)

        let model = AppModel()
        model.stacked = args.contains("--stacked")
        model.showDetections = args.contains("--detections")
        model.showHeatmap = args.contains("--heatmap")
        model.showBreakdown = !args.contains("--no-breakdown")
        let host = NSHostingView(rootView: NavigationStack { ContentView() }.environment(model))
        let started = Date()
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: CGFloat(Int(ProcessInfo.processInfo.environment["SNAP_WIDTH"] ?? "") ?? 1400), height: CGFloat(Int(ProcessInfo.processInfo.environment["SNAP_HEIGHT"] ?? "") ?? 820)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        model.open(URL(fileURLWithPath: args[i + 1]))

        let out = URL(fileURLWithPath: args[i + 2])
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            MainActor.assumeIsolated {
                // Give activation a moment so controls draw in their active state.
                if !app.isActive && Date().timeIntervalSince(started) < 3 { return }
                switch model.phase {
                case .analyzing: return
                case .failed(let message): print("failed: \(message)"); exit(1)
                default: break
                }
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    host.layoutSubtreeIfNeeded()
                    let rep: NSBitmapImageRep
                    if let image = captureWindow(window.windowNumber) {
                        rep = NSBitmapImageRep(cgImage: image)
                    } else {
                        // Fallback: loses some colours and symbol styling.
                        guard let cached = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                        host.cacheDisplay(in: host.bounds, to: cached)
                        rep = cached
                    }
                    try? rep.representation(using: .png, properties: [:])?.write(to: out)
                    print("wrote \(out.path)")
                    exit(0)
                }
            }
        }
        app.run()
        exit(0)
    }

    /// Captures one of our own windows. CGWindowListCreateImage is hidden from Swift in
    /// recent SDKs, so it is looked up at runtime.
    private static func captureWindow(_ number: Int) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let options = CGWindowListOption.optionIncludingWindow.rawValue
        let imageOptions = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        return fn(.null, options, UInt32(number), imageOptions)?.takeRetainedValue()
    }
}

/// Always reports itself as key and main so the capture shows active-window styling even when
/// another app has focus.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
