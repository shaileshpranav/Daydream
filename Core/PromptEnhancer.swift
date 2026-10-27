import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Rewrites a short idea into a detailed diffusion prompt using Apple's on-device
/// Foundation Models (Apple Intelligence). Runs locally; nothing leaves the Mac.
enum PromptEnhancer {
    struct Result: Equatable {
        var prompt: String
        var negativePrompt: String
    }

    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable("Turn on Apple Intelligence in System Settings to use the prompt enhancer.")
            case .unavailable(.modelNotReady):
                return .unavailable("Apple Intelligence is still downloading its model. Try again later.")
            case .unavailable(.deviceNotEligible):
                return .unavailable("This Mac doesn't support Apple Intelligence.")
            case .unavailable:
                return .unavailable("Apple Intelligence isn't available right now.")
            }
        }
        #endif
        return .unavailable("The prompt enhancer needs macOS 26 or later.")
    }

    static func enhance(prompt: String, negativePrompt: String, for model: InstalledModel?) async throws -> Result {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            var result = try await OnDeviceEnhancer.enhance(prompt: prompt, negativePrompt: negativePrompt,
                                                            kind: model?.kind ?? .sd, loras: model?.loras ?? [])
            result.prompt = preservingKeyPhrases(of: prompt, in: result.prompt)
            return result
        }
        #endif
        throw EnhancerError.unavailable
    }

    /// LoRA trigger words and names must reach the model verbatim, and the language model
    /// sometimes drops or rephrases them. Quoted text and runs of capitalized words from the
    /// user's idea (e.g. `Monet Style`, `Tokyo`) that are missing get put back at the front.
    static func preservingKeyPhrases(of idea: String, in enhanced: String) -> String {
        var phrases: [String] = []
        // "quoted text"
        let quoted = idea.split(separator: "\"", omittingEmptySubsequences: false)
        for (i, part) in quoted.enumerated() where i % 2 == 1 && !part.isEmpty {
            phrases.append(String(part))
        }
        // Runs of Capitalized Words in each comma-separated segment. A lone capitalized first
        // word ("Portrait of a knight") is just sentence case, so it doesn't count, unless the
        // segment is that single word (a tag like "Cyberpunk").
        for segment in idea.split(separator: ",") {
            let words = segment.split(separator: " ")
            var start: Int?
            for i in 0...words.count {
                let isCap = i < words.count && words[i].first?.isUppercase == true
                if isCap, start == nil { start = i }
                if !isCap, let s = start {
                    let isSentenceCase = s == 0 && i == 1 && words.count > 1
                    if !isSentenceCase { phrases.append(words[s..<i].joined(separator: " ")) }
                    start = nil
                }
            }
        }
        let missing = phrases
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
            .filter { !$0.isEmpty && enhanced.range(of: $0) == nil }
        guard !missing.isEmpty else { return enhanced }
        return (missing + [enhanced]).joined(separator: ", ")
    }

    static func instructions(for kind: ModelKind, loras: [FusedLoRA]) -> String {
        let style: String
        switch kind {
        case .sdxl:
            style = """
            The target model is Stable Diffusion XL. Write one or two vivid natural-language sentences \
            followed by a few comma-separated style and lighting terms.
            """
        case .mlx:
            style = """
            The target model is a modern diffusion transformer with a large language-model text encoder \
            (Z-Image, FLUX.2 or Qwen-Image). It understands full sentences well: write two or three \
            descriptive natural-language sentences covering subject, setting, lighting, composition and \
            style. Avoid tag lists and quality keywords like "masterpiece". If the image should contain \
            text, put the exact text in double quotes.
            """
        case .sd:
            style = """
            The target model is Stable Diffusion 1.x/2.x. Its text encoder only reads about 75 tokens, \
            so write 8 to 14 short descriptive phrases separated by commas, most important first: \
            subject with key details, setting, lighting, mood and colors, composition or camera, \
            art style, quality terms.
            Example idea: a lighthouse at night
            Example prompt: a lone lighthouse on a rocky cliff at night, bright beam cutting through fog, \
            crashing waves below, starry sky, cold blue and amber tones, wide angle, long exposure photograph, \
            highly detailed, sharp focus
            Example negative prompt: blurry, low quality, oversaturated, watermark, text
            """
        }
        var text = """
        You turn a user's short image idea into a detailed prompt for an image diffusion model.
        \(style)
        Rules:
        - Keep the user's subject, intent and every specific detail they gave. Do not add new main subjects.
        - Keep any words in quotes and any unusual words (they may be trigger words) exactly as written.
        - Add concrete visual detail: materials, colors, lighting, mood, framing, medium or camera.
        - Keep the prompt under 60 words. No explanations, no line breaks.
        - The negative prompt is a short comma-separated list of things to avoid, such as blurry, \
        low quality, deformed hands, extra fingers, watermark, text, plus anything that would clash \
        with this particular image. Keep any terms already in the user's negative prompt.
        """
        if !loras.isEmpty {
            text += "\nThis model has these styles fused in: \(loras.map(\.name).joined(separator: ", ")). Keep the user's style words."
        }
        return text
    }
}

enum EnhancerError: LocalizedError {
    case unavailable
    case declined
    case tooShort

    var errorDescription: String? {
        switch self {
        case .unavailable: "The prompt enhancer isn't available on this Mac."
        case .declined: "Apple's on-device model declined to rewrite this prompt."
        case .tooShort: "The enhancer didn't produce a usable prompt. Try again or add a little more detail."
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct GeneratedPrompt {
    @Guide(description: "The enhanced image prompt: 25 to 60 words on one line, much more detailed than the idea")
    var prompt: String

    @Guide(description: "Comma-separated negative prompt: things to avoid in the image")
    var negativePrompt: String
}

@available(macOS 26.0, *)
private enum OnDeviceEnhancer {
    static func enhance(prompt: String, negativePrompt: String, kind: ModelKind, loras: [FusedLoRA]) async throws -> PromptEnhancer.Result {
        // A fresh session per request: earlier rewrites shouldn't steer the next one.
        let session = LanguageModelSession(instructions: PromptEnhancer.instructions(for: kind, loras: loras))
        var request = "Image idea: \(prompt)"
        if !negativePrompt.isEmpty {
            request += "\nCurrent negative prompt: \(negativePrompt)"
        }
        do {
            var result = try await generate(session: session, request: request)
            // The small on-device model occasionally returns a fragment; one retry usually fixes it.
            if !isUseful(result, comparedTo: prompt) {
                let retry = LanguageModelSession(instructions: PromptEnhancer.instructions(for: kind, loras: loras))
                result = try await generate(session: retry, request: request)
            }
            guard isUseful(result, comparedTo: prompt) else { throw EnhancerError.tooShort }
            return result
        } catch {
            throw isRefusal(error) ? EnhancerError.declined : error
        }
    }

    private static func generate(session: LanguageModelSession, request: String) async throws -> PromptEnhancer.Result {
        let response = try await session.respond(to: request, generating: GeneratedPrompt.self,
                                                 options: GenerationOptions(temperature: 0.7))
        return PromptEnhancer.Result(prompt: clean(response.content.prompt),
                                     negativePrompt: clean(response.content.negativePrompt))
    }

    private static func isUseful(_ result: PromptEnhancer.Result, comparedTo idea: String) -> Bool {
        func words(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " || $0 == "," }).count }
        return words(result.prompt) >= max(words(idea) + 4, 10) && words(result.negativePrompt) >= 2
    }

    /// macOS 26 throws GenerationError; macOS 27 moved these cases to LanguageModelError.
    private static func isRefusal(_ error: Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return true
            default: break
            }
        }
        if #available(macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return true
            default: break
            }
        }
        return false
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
    }
}
#endif
