import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the bare executable is launched outside an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { model.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct CropAdvisorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Crop Advisor", id: "main") {
            ContentView()
                .environment(delegate.model)
        }
        .defaultSize(width: 1400, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Photo…") { delegate.model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button("Export Crop as \(format.rawValue)…") { delegate.model.export(format) }
                        .keyboardShortcut(format == .jpeg ? KeyboardShortcut("e") : nil)
                        .disabled(delegate.model.result == nil)
                }
            }
        }
    }
}
