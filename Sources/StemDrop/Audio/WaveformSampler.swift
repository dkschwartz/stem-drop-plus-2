import Foundation
import AVFoundation

enum WaveformSampler {
    static func samples(for url: URL, count: Int = 80) -> [Float] {
        guard count > 0,
              let file = try? AVAudioFile(forReading: url),
              file.length > 0
        else {
            return Array(repeating: 0, count: max(count, 0))
        }

        let format = file.processingFormat
        let chunkSize: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            return Array(repeating: 0, count: count)
        }

        var peaks = Array(repeating: Float(0), count: count)
        var frameOffset: AVAudioFramePosition = 0

        while frameOffset < file.length {
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: chunkSize)
            } catch {
                break
            }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }

            for frame in 0..<Int(buffer.frameLength) {
                let absoluteFrame = frameOffset + AVAudioFramePosition(frame)
                let bucket = min(count - 1, Int((absoluteFrame * AVAudioFramePosition(count)) / file.length))
                for channel in 0..<Int(format.channelCount) {
                    peaks[bucket] = max(peaks[bucket], abs(channels[channel][frame]))
                }
            }
            frameOffset += AVAudioFramePosition(buffer.frameLength)
        }

        guard let overallPeak = peaks.max(), overallPeak >= 0.001 else {
            return Array(repeating: 0, count: count)
        }
        return peaks.map { $0 / overallPeak }
    }
}

@MainActor
final class WaveformCache: ObservableObject {
    @Published private(set) var samplesByURL: [URL: [Float]] = [:]
    private var loading: Set<URL> = []

    func load(_ url: URL) {
        guard samplesByURL[url] == nil, !loading.contains(url) else { return }
        loading.insert(url)

        Task {
            let samples = await Task.detached(priority: .utility) {
                WaveformSampler.samples(for: url)
            }.value
            samplesByURL[url] = samples
            loading.remove(url)
        }
    }
}
