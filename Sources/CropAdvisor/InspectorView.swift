import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let result = model.result {
            Form {
                Section("Photo") {
                    LabeledContent("File", value: result.url.lastPathComponent)
                    if let camera = result.metadata.camera { LabeledContent("Camera", value: camera) }
                    if let lens = result.metadata.lens { LabeledContent("Lens", value: lens) }
                    if let exposure = result.metadata.exposure { LabeledContent("Exposure", value: exposure) }
                }

                Section("Horizon") {
                    horizonRow(result.scene)
                    Picker("Level the horizon", selection: $model.level) {
                        ForEach(LevelMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!canStraighten(result.scene))
                }

                Section("Suggested crops") {
                    ForEach(result.suggestions) { suggestion in
                        SuggestionRow(suggestion: suggestion,
                                      isBest: suggestion.id == result.suggestions.first?.id,
                                      isSelected: suggestion.id == model.selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(suggestion) }
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
                    }

                    if let px = model.cropPixelRect {
                        Section("Crop box (pixels)") {
                            CropBoxRows(rect: px, rotation: result.scene.appliedRotation)
                        }
                    }

                    Section("Score breakdown") {
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

                Section("Adjust") {
                    LabeledContent("Crop size") {
                        Slider(value: Binding(get: { model.cropScale }, set: { model.setCropScale($0) }),
                               in: 0.3...1) { editing in
                            if !editing { model.refreshAesthetic() }
                        }
                    }
                    Toggle("Lock aspect ratio", isOn: $model.lockAspect)
                    Text("In the Before view, drag inside the crop to move it, or drag a corner or edge to resize it (hold ⇧ to toggle the aspect lock). Scores update live.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.isAdjusted {
                        Button("Reset to Suggestion") { model.resetToSuggestion() }
                    }
                }

                Section {
                    Menu("Export Cropped Photo") {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Button(format.rawValue) { model.export(format) }
                        }
                    }
                    Text("Re-develops the RAW at full resolution and keeps the camera metadata. The NEF itself is never modified.")
                        .font(.caption).foregroundStyle(.secondary)
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

    @ViewBuilder
    private func horizonRow(_ scene: SceneAnalysis) -> some View {
        if let a = scene.detectedHorizonAngle {
            let degrees = Double(a) * 180 / .pi
            if abs(degrees) < Pipeline.straightenRange.lowerBound {
                LabeledContent("Tilt", value: "Level")
            } else if abs(degrees) > Pipeline.straightenRange.upperBound {
                LabeledContent("Tilt", value: String(format: "%.1f° (looks intentional)", degrees))
            } else {
                LabeledContent("Tilt", value: String(format: scene.appliedRotation != 0 ? "%.1f° · levelled" : "%.1f° · not levelled", degrees))
            }
        } else {
            LabeledContent("Tilt", value: "No horizon found")
        }
    }

    private func scoreHeader(_ score: CropScore) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(Int((score.total * 100).rounded()))")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
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

private struct SuggestionRow: View {
    let suggestion: CropSuggestion
    let isBest: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            AspectGlyph(rect: suggestion.rect)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(suggestion.aspectLabel).fontWeight(isSelected ? .semibold : .regular)
                    if isBest {
                        Text(suggestion.isUncropped ? "ALREADY STRONG" : "BEST")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
                Text(String(format: "%.0f%% of frame", suggestion.rect.area * 100))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int((suggestion.score.total * 100).rounded()))")
                .font(.body.monospacedDigit().weight(.medium))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
        .frame(width: 30, height: 20)
    }
}

private struct CriterionBar: View {
    let name: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.callout)
                Spacer()
                Text("\(Int((value * 100).rounded()))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: value)
                .tint(value > 0.7 ? .green : (value > 0.4 ? .yellow : .orange))
        }
    }
}

/// The selected crop as a pixel bounding box in the full-resolution image.
private struct CropBoxRows: View {
    let rect: CGRect
    let rotation: CGFloat

    var body: some View {
        Group {
            LabeledContent("Top-left", value: "\(Int(rect.minX)), \(Int(rect.minY))")
            LabeledContent("Bottom-right", value: "\(Int(rect.maxX)), \(Int(rect.maxY))")
            LabeledContent("Size", value: "\(Int(rect.width)) × \(Int(rect.height))")
        }
        .monospacedDigit()
        .textSelection(.enabled)

        HStack {
            if rotation != 0 {
                Text(String(format: "In the levelled image (rotated %.1f°)", rotation * 180 / .pi))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "x=\(Int(rect.minX)) y=\(Int(rect.minY)) width=\(Int(rect.width)) height=\(Int(rect.height))",
                    forType: .string)
            }
            .help("Copy x, y, width and height")
        }
    }
}
