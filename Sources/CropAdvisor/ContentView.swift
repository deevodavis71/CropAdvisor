import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.result != nil {
                previews
            } else {
                switch model.phase {
                case .analyzing(let message):
                    ProgressView(message).controlSize(.large)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn’t analyse this photo", systemImage: "exclamationmark.triangle")
                    } description: { Text(message) } actions: {
                        Button("Open Another…") { model.presentOpenPanel() }
                    }
                default:
                    emptyState
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 900, minHeight: 560)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = model.exportMessage {
                Text(message)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { model.dropTargeted = $0 }
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.presentOpenPanel() } label: { Label("Open", systemImage: "folder") }
                    .help("Open a NEF photo (⌘O)")
            }
            ToolbarItemGroup {
                Picker("Layout", selection: $model.stacked) {
                    Label("Side by Side", systemImage: "rectangle.split.2x1").tag(false)
                    Label("Stacked", systemImage: "rectangle.split.1x2").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Preview layout")

                Toggle(isOn: $model.showThirds) { Label("Thirds Grid", systemImage: "squareshape.split.3x3") }
                    .help("Show rule-of-thirds grid")
                Toggle(isOn: $model.showDetections) { Label("Detections", systemImage: "person.crop.rectangle") }
                    .help("Show detected faces, subjects, joints and horizon")
                Toggle(isOn: $model.showHeatmap) { Label("Saliency", systemImage: "flame") }
                    .help("Show where the eye is drawn (saliency heat map)")

                Menu {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Button(format.rawValue) { model.export(format) }
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(model.result == nil)
                .help("Export the cropped photo at full resolution")
            }
            ToolbarItem {
                Button { model.showInspector.toggle() } label: { Label("Advice", systemImage: "sidebar.right") }
            }
        }
        .navigationTitle(model.result?.url.lastPathComponent ?? "Crop Advisor")
    }

    private var previews: some View {
        let layout = model.stacked ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            PreviewPane(title: "Before", subtitle: beforeSubtitle) { BeforeView() }
            PreviewPane(title: "After", subtitle: afterSubtitle) { AfterView() }
        }
        .padding(12)
        .overlay {
            if case .analyzing(let message) = model.phase {
                ProgressView(message)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var beforeSubtitle: String {
        guard let r = model.result else { return "" }
        let size = r.metadata.fullPixelSize
        return "As shot · \(Int(size.width)) × \(Int(size.height))"
    }

    private var afterSubtitle: String {
        guard let px = model.cropPixelRect else { return "" }
        let w = Int(px.width), h = Int(px.height)
        let ratio = CropEngine.ratioName(CGFloat(w) / CGFloat(max(h, 1)))
        return "\(ratio) · \(w) × \(h) · \(String(format: "%.1f", Double(w * h) / 1e6)) MP"
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "crop")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a NEF photo here").font(.title2)
            Text("Crop Advisor analyses the composition and suggests crops that strengthen it —\nrule of thirds, cleaner edges, room to look into, level horizons.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Photo…") { model.presentOpenPanel() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}

struct PreviewPane<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
