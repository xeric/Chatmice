//
//  OpenAIHandlerBase.swift
//  Chatmice
//
//  Created by Renat on 19.10.2025.
//

import AppKit
import CoreData
import Foundation

enum OpenAIEndpointURL {
    static func chatCompletions(from configuredURL: URL) -> URL {
        var base = configuredURL
        if base.lastPathComponent == "responses" {
            base.deleteLastPathComponent()
        }
        if base.path.hasSuffix("/chat/completions") {
            return base
        }
        return base.appendingPathComponent("chat/completions")
    }

    static func responses(from configuredURL: URL) -> URL {
        var base = configuredURL
        if base.lastPathComponent == "responses" { return base }
        if base.path.hasSuffix("/chat/completions") {
            base.deleteLastPathComponent()
            base.deleteLastPathComponent()
        }
        return base.appendingPathComponent("responses")
    }
    static func imagesGenerations(from configuredURL: URL) -> URL {
        var components = URLComponents(url: configuredURL, resolvingAgainstBaseURL: false)
        let path = configuredURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = path.isEmpty ? "" : "/" + path
        var base = components?.url ?? configuredURL
        if base.path.hasSuffix("/images/generations") { return base }
        if base.path.hasSuffix("/chat/completions") {
            base.deleteLastPathComponent()
            base.deleteLastPathComponent()
        } else if base.lastPathComponent == "responses" {
            base.deleteLastPathComponent()
        } else if base.lastPathComponent == "images" {
            return base.appendingPathComponent("generations")
        }
        if base.path.isEmpty || base.path == "/" { base.appendPathComponent("v1") }
        return base.appendingPathComponent("images/generations")
    }

    static func imagesModels(from configuredURL: URL) -> URL {
        imagesGenerations(from: configuredURL)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
    }
}

class OpenAIHandlerBase {
    let name: String
    let baseURL: URL
    let apiKey: String
    let model: String
    let serviceType: String
    let providerID: UUID?
    let requestHeaders: [String: String]
    let imageGenerationSupported: Bool
    let session: URLSession
    let tokenUsageTracker = ModelTokenUsageTracker()

    init(config: APIServiceConfiguration, session: URLSession, imageGenerationSupported: Bool = false) {
        self.name = config.name
        self.baseURL = config.apiUrl
        self.apiKey = config.apiKey
        self.model = config.model
        self.providerID = config.providerID
        self.requestHeaders = config.requestHeaders
        if let config = config as? APIServiceConfig {
            self.serviceType = config.type
        } else if let config = config as? APIServiceEntity {
            self.serviceType = config.type ?? "chatgpt"
        } else {
            self.serviceType = "chatgpt"
        }
        self.imageGenerationSupported = imageGenerationSupported
        self.session = session
    }

    func handleAPIResponse(_ response: URLResponse?, data: Data?, error: Error?) -> Result<Data?, APIError> {
        if let error = error {
            return .failure(.requestFailed(error))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(.invalidResponse)
        }

        if !(200...299).contains(httpResponse.statusCode) {
            switch httpResponse.statusCode {
            case 401:
                return .failure(.unauthorized)
            case 429:
                return .failure(.rateLimited)
            default:
                let body = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = body.flatMap { $0.isEmpty ? nil : String($0.prefix(2_048)) }
                    ?? "Empty or unreadable response body."
                return .failure(.serverError("HTTP \(httpResponse.statusCode): \(detail)"))
            }
        }

        return .success(data)
    }

    func loadImageFromCoreData(uuid: UUID) -> Data? {
        let viewContext = PersistenceController.shared.container.viewContext
        var imageData: Data?

        viewContext.performAndWait {
            let fetchRequest: NSFetchRequest<ImageEntity> = ImageEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            fetchRequest.fetchLimit = 1

            do {
                let results = try viewContext.fetch(fetchRequest)
                if let imageEntity = results.first {
                    imageData = imageEntity.image
                }
            }
            catch {
                print("Error fetching image from CoreData: \(error)")
            }
        }

        return imageData
    }

    struct FileAttachmentPayload {
        let data: Data
        let filename: String?
        let mimeType: String?
    }

    func loadFileFromCoreData(uuid: UUID) -> FileAttachmentPayload? {
        let viewContext = PersistenceController.shared.container.viewContext
        var payload: FileAttachmentPayload?

        viewContext.performAndWait {
            let fetchRequest: NSFetchRequest<DocumentEntity> = DocumentEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            fetchRequest.fetchLimit = 1

            do {
                let results = try viewContext.fetch(fetchRequest)
                if let documentEntity = results.first, let fileData = documentEntity.fileData {
                    payload = FileAttachmentPayload(
                        data: fileData,
                        filename: documentEntity.filename,
                        mimeType: documentEntity.mimeType
                    )
                }
            }
            catch {
                print("Error fetching file from CoreData: \(error)")
            }
        }

        return payload
    }

    func isNotSSEComment(_ string: String) -> Bool {
        return !string.starts(with: ":")
    }

    func saveGeneratedImages(_ payloads: [Data], format: String, context suppliedContext: NSManagedObjectContext? = nil) throws -> [UUID] {
        let images = try payloads.map { data -> NSImage in
            guard !data.isEmpty, let image = NSImage(data: data), image.isValid else {
                throw APIError.decodingFailed("The image response contains invalid image bytes.")
            }
            return image
        }
        let context = suppliedContext ?? PersistenceController.shared.container.viewContext
        return try context.performAndWait {
            var inserted: [ImageEntity] = []
            do {
                for (data, image) in zip(payloads, images) {
                    let entity = ImageEntity(context: context)
                    entity.id = UUID()
                    entity.image = data
                    entity.imageFormat = format
                    entity.thumbnail = createThumbnailData(from: image)
                    inserted.append(entity)
                }
                try context.save()
                return inserted.compactMap(\.id)
            } catch {
                // Do not roll back unrelated pending chat edits in the supplied context.
                inserted.forEach(context.delete)
                throw APIError.unknown("Failed to save generated images: \(error.localizedDescription)")
            }
        }
    }

    private func createThumbnailData(from image: NSImage) -> Data? {
        let thumbnailSize = CGFloat(AppConstants.thumbnailSize)
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }
        let aspectRatio = originalSize.width / originalSize.height
        var targetSize = CGSize(width: thumbnailSize, height: thumbnailSize)
        if aspectRatio > 1 { targetSize.height = thumbnailSize / aspectRatio }
        else { targetSize.width = thumbnailSize * aspectRatio }
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: CGRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        thumbnail.unlockFocus()
        guard let tiffData = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    func recordTokenUsage(from data: Data) {
        tokenUsageTracker.record(data: data)
    }

    func consumeLatestTokenUsage() -> ModelTokenUsage? {
        tokenUsageTracker.consume()
    }
}
