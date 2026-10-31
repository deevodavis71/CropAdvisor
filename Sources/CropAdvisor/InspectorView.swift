import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let result = model.result {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.url.lastPathComponent).font(.headline)
                        let details = [result.metadata.camera, result.metadata.lens, result.metadata.exposure].compactMap { $0 }
                        if !details.isEmpty {
                            Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Suggested crops") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(result.suggestions) { suggestion in
                            SuggestionTile(suggestion: suggestion,
                                           isBest: suggestion.id == result.suggestions.first?.id,
                                           isSelected: suggestion.id == model.selectedID)
                                .onTapGesture { model.select(suggestion) }
                        }
                    }
                }

                if let score = model.cropScore {
                    Section(model.isAdjusted ? "Your adjusted crop" : "Why this crop") {
                        scoreHeader(score)
                        ForEach(model.advice.reasons, id: \.self) { reason in
                            Label { Text(reason) } icon: {
                                Text(Image(systemName: "checkmark.circle.fill")).foregroundStyle(.green)
                            }
                        }
                        ForEach(model.advice.warnings, id: \.self) { warning in
                            Label { Text(warning) } icon: {
                                Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundStyle(.orange)
                            }
                        }
                        DisclosureGroup("Score breakdown", isExpanded: $model.showBreakdown) {
                            ForEach(Criterion.allCases) { criterion in
                                if let value = score.criteria[criterion] {
                                    CriterionBar(name: criterion.rawValue, value: value)
                                }
                            }
                            if let a = score.aesthetic {
                                CriterionBar(name: "Apple aesthetics model", value: a)
                            }
                        }
                    }
                }

                Section("Adjust") {
                    HStack {
                        Text("Size")
                        Slider(value: Binding(get: { model.cropScale }, set: { model.setCropScale($0) }),
                               in: 0.3...1) { editing in
                            if !editing { model.refreshAesthetic() }
                        }
                        Toggle("Lock ratio", isOn: $model.lockAspect).toggleStyle(.checkbox)
                    }
                    .help("In the Before view, drag inside the crop to move it, or drag a corner or edge to resize it (hold ⇧ to toggle the aspect lock). Scores update live.")
                    LabeledContent {
                        Picker("Level the horizon", selection: $model.level) {
                            ForEach(LevelMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!canStraighten(result.scene))
                    } label: {
                        Text("Horizon")
                        Text(horizonStatus(result.scene))
                    }
                    .help("Level the horizon: Auto levels scenes that look like landscapes")
                    if let px = model.cropPixelRect {
                        CropBoxRow(rect: px, rotation: result.scene.appliedRotation)
                    }
                    if model.isAdjusted {
                        Button("Reset to Suggestion") { model.resetToSuggestion() }
                    }
                }

                Section {
                    HStack {
                        Menu("Export") {
                            ForEach(ExportFormat.allCases, id: \.self) { format in
                                Button(format.rawValue) { model.export(format) }
                            }
                        }
                        .fixedSize()
                        .help("Re-develops the RAW at full resolution and keeps the camera metadata. The NEF itself is never modified.")
                        Spacer()
                        if let sidecar = model.sidecar {
                            PhotoLabNotes(sidecar: sidecar, result: result)
                            Button("Update PhotoLab Crop") { model.updateSidecar() }
                                .help("Writes this crop\(result.scene.appliedRotation != 0 ? " and the horizon levelling" : "") into \(sidecar.url.lastPathComponent), replacing PhotoLab’s crop and horizon settings. The original sidecar is kept as a .bak file.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Photo", systemImage: "photo",
                                   description: Text("Open a NEF to see crop advice."))
        }
    }

    private func canStraighten(_ scene: SceneAnalysis) -> Bool {
        guard let a = scene.detectedHorizonAngle else { return false }
        return Pipeline.straightenRange.contains(abs(Double(a)) * 180 / .pi)
    }

    private func horizonStatus(_ scene: SceneAnalysis) -> String {
        guard let a = scene.detectedHorizonAngle else { return "No horizon found" }
        let degrees = Double(a) * 180 / .pi
        if abs(degrees) < Pipeline.straightenRange.lowerBound { return "Level" }
        if abs(degrees) > Pipeline.straightenRange.upperBound { return String(format: "%.1f° tilt, looks intentional", degrees) }
        return String(format: scene.appliedRotation != 0 ? "%.1f° tilt, levelled" : "%.1f° tilt, not levelled", degrees)
    }

    private func scoreHeader(_ score: CropScore) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(Int((score.total * 100).rounded()))")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("/ 100").foregroundStyle(.secondary)
            Spacer()
            if let baseline = model.baseline {
                let delta = Int(((score.total - baseline.total) * 100).rounded())
                Text(delta == 0 ? "same as uncropped" : "\(delta > 0 ? "+" : "")\(delta) vs uncropped")
                    .foregroundStyle(delta > 0 ? .green : (delta < 0 ? .orange : .secondary))
            }
        }
    }
}

/// One suggested crop in the grid: its shape, score and name, with a star on the best.
private struct SuggestionTile: View {
    let suggestion: CropSuggestion
    let isBest: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                AspectGlyph(rect: suggestion.rect)
                Text("\(Int((suggestion.score.total * 100).rounded()))")
                    .font(.body.monospacedDigit().weight(.medium))
                if isBest {
                    Text(Image(systemName: "star.fill")).font(.caption2).foregroundStyle(.yellow)
                }
            }
            Text(suggestion.aspectLabel)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isSelected { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5) }
        }
        .contentShape(Rectangle())
        .help(help)
    }

    private var help: String {
        var text = String(format: "%@ · %.0f%% of frame", suggestion.aspectLabel, suggestion.rect.area * 100)
        if isBest { text += suggestion.isUncropped ? " · Already strong uncropped" : " · Best" }
        return text
    }
}

/// Tiny diagram of where the crop sits in the frame.
private struct AspectGlyph: View {
    let rect: CGRect

    var body: some View {
        Canvas { ctx, size in
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            ctx.stroke(Path(frame), with: .color(.secondary), lineWidth: 1)
            let r = CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height,
                           width: rect.width * frame.width, height: rect.height * frame.height)
            ctx.fill(Path(r), with: .color(.accentColor.opacity(0.6)))
        }
        .frame(width: 24, height: 16)
    }
}

private struct CriterionBar: View {
    let name: String
    let value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.callout)
            Spacer()
            ProgressView(value: value)
                .frame(width: 70)
                .tint(value > 0.7 ? .green : (value > 0.4 ? .yellow : .orange))
            Text("\(Int((value * 100).rounded()))")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

/// Caveats about writing the crop into the photo's DxO PhotoLab sidecar, as a warning icon
/// whose tooltip lists them.
private struct PhotoLabNotes: View {
    let sidecar: DxOSidecar
    let result: AnalysisResult

    var body: some View {
        if !notes.isEmpty {
            Text(Image(systemName: "exclamationmark.triangle.fill"))
                .foregroundStyle(.orange)
                .help(notes.joined(separator: "\n"))
        }
    }

    private var notes: [String] {
        var notes: [String] = []
        if sidecar.versionCount > 1 {
            let copies = sidecar.versionCount - 1
            notes.append("Only the master is updated; its \(copies) virtual cop\(copies == 1 ? "y is" : "ies are") left as they are.")
        }
        if sidecar.hasPerspectiveCorrection {
            notes.append("Perspective correction is on in PhotoLab, so the crop may land slightly differently there.")
        }
        let exif = result.metadata.properties[kCGImagePropertyOrientation] as? Int ?? 1
        if let o = sidecar.orientation, o != exif {
            notes.append("PhotoLab shows this photo rotated differently, so the composition may look different there.")
        }
        return notes
    }
}

/// The selected crop as a pixel bounding box in the full-resolution image.
private struct CropBoxRow: View {
    let rect: CGRect
    let rotation: CGFloat

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(verbatim: "\(Int(rect.minX)), \(Int(rect.minY))  \(Int(rect.width)) × \(Int(rect.height))")
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .textSelection(.enabled)
                    .help("Top-left corner, then width × height. Bottom-right is \(Int(rect.maxX)), \(Int(rect.maxY)).")
                copyButton
            }
        } label: {
            Text("Pixels")
            if rotation != 0 {
                Text(String(format: "Levelled %.1f°", rotation * 180 / .pi))
            }
        }
        .help(rotation != 0 ? "Coordinates in the levelled image" : "")
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                "x=\(Int(rect.minX)) y=\(Int(rect.minY)) width=\(Int(rect.width)) height=\(Int(rect.height))",
                forType: .string)
        } label: {
            Text(Image(systemName: "doc.on.doc"))
        }
        .buttonStyle(.borderless)
        .help("Copy x, y, width and height")
    }
}
