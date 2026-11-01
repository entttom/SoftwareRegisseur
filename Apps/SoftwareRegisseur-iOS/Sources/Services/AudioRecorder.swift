import AVFoundation
import Foundation
import Observation

/// AAC/m4a recording for both dictation methods (spec H2: start, pause, stop, listen, delete).
/// Format per apple-platform.md: mono, 16 kHz, 32 kbit/s ≈ 14 MB per hour.
@MainActor
@Observable
final class AudioRecorder: NSObject, AVAudioPlayerDelegate {
    enum State: Equatable {
        case idle
        case recording
        case paused
        case finished
    }

    private(set) var state: State = .idle
    private(set) var fileURL: URL?
    private(set) var duration: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var isPlaying = false
    private(set) var recordedAt: Date?
    private(set) var lastError: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTask: Task<Void, Never>?
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        lastError = nil
        discardFile()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let url = directory.appendingPathComponent("Diktat-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                lastError = String(localized: "Die Aufnahme konnte nicht gestartet werden.")
                return
            }
            self.recorder = recorder
            fileURL = url
            recordedAt = .now
            state = .recording
            startMetering()
        } catch {
            lastError = String(localized: "Die Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)")
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused, recorder?.record() == true else { return }
        state = .recording
    }

    func stop() {
        guard state == .recording || state == .paused, let recorder else { return }
        duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        meterTask?.cancel()
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let fileURL, let asset = try? AVAudioPlayer(contentsOf: fileURL) {
            duration = asset.duration
        }
        state = .finished
    }

    func togglePlayback() {
        if isPlaying {
            player?.stop()
            isPlaying = false
            return
        }
        guard state == .finished, let fileURL else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.play()
            self.player = player
            isPlaying = true
        } catch {
            lastError = String(localized: "Die Aufnahme kann nicht abgespielt werden: \(error.localizedDescription)")
        }
    }

    /// Deletes the recording file (spec H2 „löschen“, retention policy).
    func discardFile() {
        player?.stop()
        isPlaying = false
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        duration = 0
        recordedAt = nil
        state = .idle
    }

    /// Forgets the file without deleting it (kept by the retention policy).
    func detachFile() {
        fileURL = nil
        duration = 0
        recordedAt = nil
        state = .idle
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                self.level = max(0, min(1, (power + 60) / 60))
                self.duration = recorder.currentTime
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}
