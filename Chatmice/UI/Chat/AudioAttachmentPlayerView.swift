import AVFoundation
import CoreData
import SwiftUI

@MainActor
final class AudioAttachmentPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let id: UUID
    private let filename: String
    private let localURL: URL?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(id: UUID, filename: String, localURL: URL? = nil) {
        self.id = id
        self.filename = filename
        self.localURL = localURL
    }

    func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            stopTimer()
        } else if let player {
            player.play()
            isPlaying = true
            startTimer()
        } else {
            loadAndPlay()
        }
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        stopTimer()
    }

    func seek(to value: TimeInterval) {
        player?.currentTime = value
        currentTime = value
    }

    private func loadAndPlay() {
        isLoading = true
        errorMessage = nil
        if let localURL, FileManager.default.fileExists(atPath: localURL.path) {
            prepareAndPlay(url: localURL)
            return
        }

        PersistenceController.shared.container.performBackgroundTask { [weak self] context in
            guard let self else { return }
            let request: NSFetchRequest<DocumentEntity> = DocumentEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", self.id as CVarArg)
            request.fetchLimit = 1
            guard let entity = try? context.fetch(request).first,
                  let data = entity.fileData else {
                Task { @MainActor in
                    self.isLoading = false
                    self.errorMessage = "Audio data is unavailable."
                }
                return
            }
            let pathExtension = URL(fileURLWithPath: self.filename).pathExtension
            let ext = pathExtension.isEmpty ? "wav" : pathExtension
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Chatmice-AudioPreview-\(self.id.uuidString).\(ext)")
            do {
                try data.write(to: url, options: .atomic)
                Task { @MainActor in self.prepareAndPlay(url: url) }
            } catch {
                Task { @MainActor in
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func prepareAndPlay(url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            isLoading = false
            player.play()
            isPlaying = true
            startTimer()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

struct AudioAttachmentPlayerView: View {
    let filename: String
    let width: CGFloat
    @StateObject private var player: AudioAttachmentPlayer

    init(id: UUID, filename: String, localURL: URL? = nil, width: CGFloat = 240) {
        self.filename = filename
        self.width = width
        _player = StateObject(wrappedValue: AudioAttachmentPlayer(id: id, filename: filename, localURL: localURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Color.accentColor)
                Text(filename.isEmpty ? "Voice Audio" : filename)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }

            HStack(spacing: 8) {
                Button(action: player.togglePlayback) {
                    if player.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .buttonStyle(.plain)
                .disabled(player.isLoading)

                Button(action: player.stop) { Image(systemName: "stop.fill") }
                    .buttonStyle(.plain)
                    .disabled(player.currentTime == 0 && !player.isPlaying)

                Slider(
                    value: Binding(get: { player.currentTime }, set: player.seek),
                    in: 0...max(player.duration, 0.01)
                )
                .controlSize(.mini)
            }

            HStack {
                Text(format(player.currentTime))
                Spacer()
                Text(format(player.duration))
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)

            if let error = player.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(10)
        .frame(width: width)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }

    private func format(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
    }
}
