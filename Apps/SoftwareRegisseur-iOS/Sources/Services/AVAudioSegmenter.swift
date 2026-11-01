import AVFoundation
import Foundation
import SoftwareRegisseurAI

/// Splits long recordings for API transcription (spec H2 „Lange Notizen sinnvoll behandeln“).
/// Inner cuts are moved up to `plan.pauseSearchWindow` seconds earlier to the quietest 50 ms frame, so
/// segments end in a speech pause instead of mid-word; each segment is exported as m4a.
struct AVAudioSegmenter: AudioSegmenter {
    let outputDirectory: URL

    func split(_ audio: URL, plan: TranscriptionChunkPlan) async throws -> [AudioPayload] {
        let asset = AVURLAsset(url: audio)
        var cuts: [TimeInterval] = []
        for segment in plan.segments.dropLast() {
            let quiet = try await Self.quietestPoint(in: asset, before: segment.end, window: plan.pauseSearchWindow)
            cuts.append(quiet ?? segment.end)
        }
        let total = plan.segments.last?.end ?? 0
        let bounds = [0] + cuts + [total]

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var payloads: [AudioPayload] = []
        for index in 0..<(bounds.count - 1) {
            let start = CMTime(seconds: bounds[index], preferredTimescale: 600)
            let end = CMTime(seconds: bounds[index + 1], preferredTimescale: 600)
            guard end > start else { continue }
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw AIProviderError.invalidRequest(String(localized: "Audio-Export nicht verfügbar"))
            }
            export.timeRange = CMTimeRange(start: start, end: end)
            let url = outputDirectory.appendingPathComponent("Segment-\(index)-\(UUID().uuidString).m4a")
            try await export.export(to: url, as: .m4a)
            payloads.append(try AudioPayload(fileURL: url))
        }
        return payloads
    }

    /// Time of the lowest-energy 50 ms frame in `[cut - window, cut]`, or nil if nothing could be read.
    static func quietestPoint(in asset: AVURLAsset, before cut: TimeInterval, window: TimeInterval) async throws -> TimeInterval? {
        guard window > 0, let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let start = max(0, cut - window)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: cut, preferredTimescale: 600))
        let sampleRate = 16_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { return nil }

        let frameLength = Int(sampleRate * 0.05)
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.size)
            chunk.withUnsafeMutableBytes { pointer in
                if let base = pointer.baseAddress {
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
                }
            }
            samples.append(contentsOf: chunk)
        }
        guard samples.count >= frameLength else { return nil }

        var bestFrame = 0
        var bestEnergy = Double.greatestFiniteMagnitude
        var frame = 0
        while (frame + 1) * frameLength <= samples.count {
            let slice = samples[(frame * frameLength)..<((frame + 1) * frameLength)]
            let energy = slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frameLength)
            if energy < bestEnergy {
                bestEnergy = energy
                bestFrame = frame
            }
            frame += 1
        }
        return start + (Double(bestFrame) + 0.5) * 0.05
    }
}
