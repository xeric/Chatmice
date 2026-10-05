import AVFoundation
import Foundation

@MainActor
final class VoiceRecordingController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum RecordingError: LocalizedError {
        case permissionDenied
        case recorderUnavailable
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone access is required for voice input."
            case .recorderUnavailable: return "Chatmice could not start WAV recording."
            case .emptyRecording: return "The recording did not contain any audio."
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var outputURL: URL?
    private var completion: ((Result<URL, Error>) -> Void)?

    func toggle(completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isStarting else { return }
        if isRecording {
            stop()
        } else {
            isStarting = true
            errorMessage = nil
            start(completion: completion)
        }
    }

    func cancel() {
        recorder?.stop()
        finishTimer()
        isRecording = false
        isStarting = false
        completion = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }

    private func start(completion: @escaping (Result<URL, Error>) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.isStarting = false
                    self.errorMessage = RecordingError.permissionDenied.localizedDescription
                    completion(.failure(RecordingError.permissionDenied))
                    return
                }
                self.beginRecording(completion: completion)
            }
        }
    }

    private func beginRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Chatmice-Voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw RecordingError.recorderUnavailable
            }
            self.recorder = recorder
            outputURL = url
            self.completion = completion
            duration = 0
            errorMessage = nil
            isStarting = false
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.duration = self?.recorder?.currentTime ?? 0 }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            isStarting = false
            errorMessage = error.localizedDescription
            completion(.failure(error))
        }
    }

    private func stop() {
        recorder?.stop()
        finishTimer()
        isRecording = false
        guard let url = outputURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else {
            complete(.failure(RecordingError.emptyRecording))
            return
        }
        complete(.success(url))
    }


    private func complete(_ result: Result<URL, Error>) {
        let callback = completion
        completion = nil
        recorder = nil
        outputURL = nil
        callback?(result)
    }

    private func finishTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.finishTimer()
            self.isStarting = false
            self.isRecording = false
            let failure = error ?? RecordingError.recorderUnavailable
            self.errorMessage = failure.localizedDescription
            self.complete(.failure(failure))
        }
    }
}

enum AudioInputCapability {
    static func supportsAudio(serviceType: String?, modelID: String) -> Bool {
        let type = serviceType?.lowercased() ?? ""
        let model = modelID.lowercased()
        switch type {
        case "gemini":
            return model.contains("gemini") && !model.contains("embedding") && !model.contains("image")
        case "openai", "openai-responses", "chatgpt":
            return model.contains("gpt-4o-audio")
                || model.contains("gpt-audio")
                || model.contains("audio-preview")
        default:
            return false
        }
    }
}
