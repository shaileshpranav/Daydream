import Foundation

enum SchedulerChoice: String, Codable, CaseIterable, Identifiable {
    case dpmSolver = "DPM-Solver++"
    case pndm = "PNDM"

    var id: String { rawValue }
}

/// Everything needed to reproduce an image with a given model.
struct GenerationRequest: Codable, Equatable {
    var prompt: String = ""
    var negativePrompt: String = ""
    var steps: Int = 25
    var guidance: Double = 7.5
    var seed: UInt32 = 42
    var scheduler: SchedulerChoice = .dpmSolver

    mutating func randomizeSeed() {
        seed = UInt32.random(in: 0...UInt32.max)
    }
}

/// Written next to every saved PNG so the gallery can restore settings.
struct GenerationRecord: Codable, Identifiable, Hashable {
    var id: String { fileName }
    let fileName: String
    let request: GenerationRequest
    let modelID: String
    let modelName: String
    let date: Date
    let seconds: Double

    static func == (a: GenerationRecord, b: GenerationRecord) -> Bool { a.fileName == b.fileName }
    func hash(into hasher: inout Hasher) { hasher.combine(fileName) }
}
