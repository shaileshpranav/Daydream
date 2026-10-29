import Foundation

/// A local Ollama server (https://ollama.com) as a prompt enhancer engine. Uses whatever
/// models the user has pulled; the app only talks to its HTTP API.
enum Ollama {
    static let urlKey = "ollamaURL"
    static let modelKey = "ollamaModel"
    static let defaultURL = "http://localhost:11434"

    static var baseURL: URL {
        let text = UserDefaults.standard.string(forKey: urlKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(string: text.isEmpty ? defaultURL : text) ?? URL(string: defaultURL)!
    }

    static var model: String {
        UserDefaults.standard.string(forKey: modelKey) ?? ""
    }

    struct ModelInfo: Decodable, Hashable, Identifiable {
        let name: String
        let size: Int64
        var id: String { name }
    }

    /// The pulled models, smallest first (small models rewrite prompts fastest).
    static func models() async throws -> [ModelInfo] {
        struct Tags: Decodable { let models: [ModelInfo] }
        let (data, response) = try await send(URLRequest(url: baseURL.appending(path: "api/tags"), timeoutInterval: 5))
        try check(response, data)
        return try JSONDecoder().decode(Tags.self, from: data).models.sorted { $0.size < $1.size }
    }

    /// One chat turn. `schema` (a JSON schema) makes Ollama constrain the reply to match it.
    static func chat(model: String, system: String, user: String, temperature: Double,
                     schema: [String: Any]) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": false,
            "format": schema,
            // Reasoning only slows a rewrite down; models without it accept false too.
            "think": false,
            // A rewrite needs little context, and a small one keeps the model's memory down
            // (a server-wide 64K default can crash a 16 GB Mac loading an 8B model).
            "options": ["temperature": temperature, "num_ctx": 2048],
            // Free the model after the same idle time as an MLX one (Settings → Speed & Memory).
            "keep_alive": "\(Int(MLXPromptRewriter.idleSeconds))s",
        ]
        var (data, response) = try await post("api/chat", body)
        // Ollama builds the schema's grammar on the chat template's assistant marker. For a
        // model whose template doesn't match its tokenizer (e.g. a Mistral fine-tune with a
        // ChatML template) that fails with "Failed to initialize samplers". The instructions
        // ask for JSON anyway, so go again unconstrained.
        if (response as? HTTPURLResponse)?.statusCode != 200,
           String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("initialize samplers") {
            body["format"] = nil
            (data, response) = try await post("api/chat", body)
        }
        try check(response, data)
        struct Reply: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        return try JSONDecoder().decode(Reply.self, from: data).message.content
    }

    /// Asks Ollama to free `model`'s memory now instead of after its keep-alive time.
    static func unload(model: String) async throws {
        let (data, response) = try await post("api/generate", ["model": model, "keep_alive": 0])
        try check(response, data)
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 300)  // includes loading the model
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
            throw RuntimeError("Can't reach Ollama at \(baseURL.absoluteString). Open the Ollama app, or check the address in Settings.")
        }
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw RuntimeError("Ollama: \(message ?? "HTTP \(http.statusCode)")")
    }
}
