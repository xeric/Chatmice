import AVFoundation
import Foundation

enum AudioAttachmentConverter {
    static func normalizeForUpload(_ sourceURL: URL) throws -> URL {
        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "m4a" || ext == "aac" else { return sourceURL }

        let input = try AVAudioFile(forReading: sourceURL)
        let processingFormat = input.processingFormat
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Chatmice-Audio-\(UUID().uuidString).wav")
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: processingFormat.sampleRate,
            AVNumberOfChannelsKey: processingFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: 32_768
        ) else {
            throw NSError(domain: "AudioAttachmentConverter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not allocate an audio conversion buffer."
            ])
        }

        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: min(buffer.frameCapacity, AVAudioFrameCount(input.length - input.framePosition)))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
        return outputURL
    }
}
