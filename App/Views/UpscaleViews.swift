import SwiftUI

/// Upscale 2× or 4×, for one picture or several. Sizes past `Upscaler.maxOutputSide` are
/// left out (and said so).
struct UpscaleMenu<Label: View>: View {
    @Environment(Upscaler.self) private var upscaler
    let records: [GenerationRecord]
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            ForEach([2, 4], id: \.self) { scale in
                let fitting = records.filter { Upscaler.canUpscale(ImageSaver.pixelSize(of: $0), by: scale) }
                Button(title(scale: scale, fitting: fitting)) { upscaler.upscale(fitting, scale: scale) }
                    .disabled(fitting.isEmpty)
            }
            if upscaler.status != .installed {
                Divider()
                Text("Downloads \(Upscaler.modelName) (\(Upscaler.approxMB) MB) the first time")
            }
        } label: {
            label
        }
    }

    private func title(scale: Int, fitting: [GenerationRecord]) -> String {
        if records.count == 1 {
            guard let record = fitting.first, let size = ImageSaver.pixelSize(of: record) else {
                return "Upscale \(scale)× (too large)"
            }
            return "Upscale \(scale)× (\(Int(size.width) * scale) × \(Int(size.height) * scale))"
        }
        let skipped = records.count - fitting.count
        return "Upscale \(fitting.count) Pictures \(scale)×" + (skipped > 0 ? " (\(skipped) too large)" : "")
    }
}

/// The upscaler's progress, or its last error, for a header or toolbar.
struct UpscaleStatus: View {
    @Environment(Upscaler.self) private var upscaler

    var body: some View {
        Group {
            if case .downloading(let fraction) = upscaler.status {
                HStack(spacing: 6) {
                    ProgressView(value: fraction).frame(width: 70)
                    Text("Getting the upscaler…")
                }
            } else if let job = upscaler.running {
                HStack(spacing: 6) {
                    ProgressView(value: upscaler.progress).frame(width: 70)
                    Text("Upscaling \(job.scale)×" + (upscaler.jobs.isEmpty ? "" : ", \(upscaler.jobs.count) more"))
                    Button("Stop Upscaling", systemImage: "xmark.circle.fill") { upscaler.cancelAll() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Stop upscaling")
                }
            } else if let error = upscaler.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(1).help(error)
                    Button("Dismiss", systemImage: "xmark.circle.fill") { upscaler.lastError = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 320)
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}
