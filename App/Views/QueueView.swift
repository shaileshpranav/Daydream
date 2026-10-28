import SwiftUI

/// The generation queue under the image: what's running, what's waiting, what finished.
struct QueueView: View {
    @Environment(GenerationQueue.self) private var queue
    @Environment(Generator.self) private var generator
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Up Next").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if queue.hasFinished {
                    Button("Clear Finished") { queue.clearFinished() }
                        .buttonStyle(.borderless)
                }
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(queue.jobs) { job in
                        row(job)
                    }
                }
            }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }

    private var summary: String {
        let done = queue.jobs.count { if case .done = $0.state { true } else { false } }
        return "\(done) finished · \(queue.pendingCount) waiting · click a finished one to see it"
    }

    private func row(_ job: QueuedJob) -> some View {
        HStack(spacing: 8) {
            icon(job.state).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.request.prompt).lineLimit(1).truncationMode(.tail)
                Text(detail(job)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch job.state {
            case .pending:
                Button { queue.move(job.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .help("Move up")
                Button { queue.move(job.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .help("Move down")
                Button { queue.remove(job.id) } label: { Image(systemName: "xmark") }
                    .help("Remove from queue")
            case .running:
                Button { queue.cancelCurrent() } label: { Image(systemName: "stop.fill") }
                    .help("Stop this picture")
            case .done(let record):
                Button { app.restore(record) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Reuse these settings")
                Button {
                    app.useAsStartImage(ImageSaver.folder.appending(path: record.fileName), for: job.model)
                } label: { Image(systemName: "photo.badge.arrow.down") }
                    .help("Edit this picture")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([ImageSaver.folder.appending(path: record.fileName)])
                } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
            default:
                Button { queue.remove(job.id) } label: { Image(systemName: "xmark") }
                    .help("Remove")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(background(for: job), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            // Click a finished image to look at it in Create.
            if case .done(let record) = job.state {
                app.viewedRecord = record
                app.section = .generate
            }
        }
    }

    private func background(for job: QueuedJob) -> Color {
        if job.state == .running { return Color.accentColor.opacity(0.12) }
        if case .done(let record) = job.state, app.viewedRecord == record { return Color.secondary.opacity(0.15) }
        return .clear
    }

    private func detail(_ job: QueuedJob) -> String {
        var parts = [job.model.name]
        if let loras = job.request.loras, !loras.isEmpty { parts.append("\(loras.count) LoRA") }
        if job.request.isImageToImage {
            parts.append("editing a picture")
        }
        switch job.state {
        case .running:
            switch generator.phase {
            case .loading: parts.append("getting the model ready…")
            case .generating(let step, let total): parts.append("\(Int(Double(step) / Double(max(total, 1)) * 100))%")
            case .idle: break
            }
        case .done(let record): parts.append(String(format: "done in %.0f s", record.seconds))
        case .failed(let message): parts.append(message)
        case .cancelled: parts.append("stopped")
        case .pending: parts.append("waiting")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func icon(_ state: QueuedJob.State) -> some View {
        switch state {
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
