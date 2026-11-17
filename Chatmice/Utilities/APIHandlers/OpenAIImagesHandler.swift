import CoreData
import Foundation

/// The GPT Image generations wire API, not a chat or Responses API.
final class OpenAIImagesHandler: OpenAIHandlerBase, APIService {
    private let imageContext: NSManagedObjectContext?
    private var activeTask: Task<Void, Never>?

    init(config: APIServiceConfiguration, session: URLSession, imageContext: NSManagedObjectContext? = nil) {
        self.imageContext = imageContext
        super.init(config: config, session: session, imageGenerationSupported: true)
    }

    func sendMessage(_ requestMessages: [[String: String]], temperature: Float, completion: @escaping (Result<String, APIError>) -> Void) {
        activeTask?.cancel()
        activeTask = Task { @MainActor in
            do {
                completion(.success(try await generate(requestMessages)))
            } catch let error as APIError {
                completion(.failure(error))
            } catch {
                completion(.failure(.requestFailed(error)))
            }
        }
    }

    func sendMessageStream(_ requestMessages: [[String: String]], temperature: Float) async throws -> AsyncThrowingStream<String, Error> {
        activeTask?.cancel()
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    continuation.yield(try await generate(requestMessages))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            activeTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelCurrentRequest() { activeTask?.cancel() }

    func compactContext(_ source: String) async throws -> ContextCompactionResult {
        throw APIError.noApiService("Image Generations does not support conversation compaction.")
    }

    /// Authenticated catalog lookup only: never spends a generation to test connectivity.
    func testConnection(modelID: String) async throws {
        let models = try await fetchModels()
        guard models.contains(where: { $0.id == modelID }) else {
            throw APIError.noApiService("The configured model ‘\(modelID)’ was not returned by this provider's model catalog. No image was generated.")
        }
    }

    func fetchModels() async throws -> [AIModel] {
        var request = URLRequest(url: OpenAIEndpointURL.imagesModels(from: baseURL))
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        let payload = try handleAPIResponse(response, data: data, error: nil).get()
        guard let payload,
              let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: payload) else {
            throw APIError.decodingFailed("Failed to decode the image provider's model catalog.")
        }
        return decoded.data.map { AIModel(id: $0.id) }
    }

    @MainActor
    private func generate(_ messages: [[String: String]]) async throws -> String {
        try Task.checkCancellation()
        guard let user = messages.last(where: { $0["role"] == "user" }) else {
            throw APIError.noApiService("Image Generations requires a current user prompt.")
        }
        let prompt = user["content"] ?? ""
        guard !prompt.contains("<image-uuid>"), !prompt.contains("<image-base64>"), user["message_parts"] == nil else {
            throw APIError.attachmentNotReady("Image Generations accepts text prompts only. Input images and image edits are not supported by this protocol.")
        }
        guard !prompt.contains("<file-uuid>"), !prompt.contains("<audio-uuid>") else {
            throw APIError.attachmentNotReady("Image Generations accepts text prompts only; file and audio attachments are not supported.")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.noApiService("Describe the image to generate in the current user message.")
        }
        var request = URLRequest(url: OpenAIEndpointURL.imagesGenerations(from: baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "n": 1, "output_format": "png",
        ])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        let payload = try handleAPIResponse(response, data: data, error: nil).get()
        guard let payload,
              let decoded = try? JSONDecoder().decode(ImagesResponse.self, from: payload),
              !decoded.data.isEmpty else {
            throw APIError.decodingFailed("The Images API returned no base64 images.")
        }
        // Decode every result before inserting anything: a malformed batch must not leave orphan images.
        let images = try decoded.data.map { item -> Data in
            guard let bytes = Data(base64Encoded: item.b64_json), !bytes.isEmpty else {
                throw APIError.decodingFailed("The Images API returned malformed base64 image data.")
            }
            return bytes
        }
        try Task.checkCancellation()
        let ids = try saveGeneratedImages(images, format: "png", context: imageContext)
        recordTokenUsage(from: payload)
        return ids.map { "<image-uuid>\($0.uuidString)</image-uuid>" }.joined(separator: "\n\n")
    }

    private func applyHeaders(to request: inout URLRequest) {
        let effectiveKey = apiKey.isEmpty ? (ProcessInfo.processInfo.environment["LOCAL_SAP_AI_CORE_PROXY_KEY"] ?? "") : apiKey
        if !effectiveKey.isEmpty { request.setValue("Bearer \(effectiveKey)", forHTTPHeaderField: "Authorization") }
        ProviderHeaderStore.apply(requestHeaders, to: &request)
    }

    private struct ImagesResponse: Decodable {
        let data: [ImageResult]
    }
    private struct ImageResult: Decodable {
        let b64_json: String
    }
    private struct ModelsResponse: Decodable {
        let data: [Model]
    }
    private struct Model: Decodable {
        let id: String
    }
}
