import Foundation
import AVFoundation

struct MixInput: Sendable {
    let stem: StemType
    let url: URL
    let gainDecibels: Double

    var linearGain: Float {
        Float(pow(10.0, gainDecibels / 20.0))
    }
}

enum AudioMixer {
    /// Renders selected stems into a float WAV and returns its unmodified peak.
    /// The caller can apply peak protection only when the sum would clip.
    static func render(inputs: [MixInput], to outputURL: URL) throws -> Float {
        guard !inputs.isEmpty else { throw StemDropError.unreadableAudio }

        let files = try inputs.map { input -> AVAudioFile in
            do {
                return try AVAudioFile(forReading: input.url)
            } catch {
                throw StemDropError.unreadableAudio
            }
        }

        let firstFormat = files[0].processingFormat
        let sampleRate = firstFormat.sampleRate
        let channelCount = firstFormat.channelCount
        guard sampleRate > 0, channelCount > 0,
              files.allSatisfy({
                  abs($0.processingFormat.sampleRate - sampleRate) < 0.5
                      && $0.processingFormat.channelCount == channelCount
              }),
              let renderFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: channelCount,
                  interleaved: false
              )
        else {
            throw StemDropError.unreadableAudio
        }

        let engine = AVAudioEngine()
        let players = inputs.enumerated().map { index, input -> AVAudioPlayerNode in
            let player = AVAudioPlayerNode()
            player.volume = input.linearGain
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: files[index].processingFormat)
            return player
        }

        let maximumFrameCount: AVAudioFrameCount = 4_096
        do {
            try engine.enableManualRenderingMode(
                .offline,
                format: renderFormat,
                maximumFrameCount: maximumFrameCount
            )
        } catch {
            throw StemDropError.outputNotWritable
        }

        for (player, file) in zip(players, files) {
            player.scheduleFile(file, at: nil)
        }

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: renderFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw StemDropError.outputNotWritable
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: maximumFrameCount
        ) else {
            throw StemDropError.outputNotWritable
        }

        let totalFrames = files.map(\.length).max() ?? 0
        var peak: Float = 0

        do {
            try engine.start()
            players.forEach { $0.play() }

            while engine.manualRenderingSampleTime < totalFrames {
                let remaining = totalFrames - engine.manualRenderingSampleTime
                let frames = AVAudioFrameCount(min(Int64(maximumFrameCount), remaining))
                let status = try engine.renderOffline(frames, to: buffer)

                switch status {
                case .success:
                    if let channelData = buffer.floatChannelData {
                        for channel in 0..<Int(buffer.format.channelCount) {
                            for frame in 0..<Int(buffer.frameLength) {
                                peak = max(peak, abs(channelData[channel][frame]))
                            }
                        }
                    }
                    try outputFile.write(from: buffer)
                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    continue
                case .error:
                    throw StemDropError.outputNotWritable
                @unknown default:
                    throw StemDropError.outputNotWritable
                }
            }
        } catch let error as StemDropError {
            throw error
        } catch {
            throw StemDropError.outputNotWritable
        }

        players.forEach { $0.stop() }
        engine.stop()
        return peak
    }
}

enum MixExporter {
    static let clippingThreshold = Float(pow(10.0, -0.1 / 20.0))

    static func needsPeakProtection(peak: Float) -> Bool {
        peak > clippingThreshold
    }

    @MainActor
    static func export(
        record: MixExportRecord,
        selectedStems: Set<StemType>,
        levels: [StemType: Double],
        prefs: AppPreferences
    ) async throws -> URL {
        let inputs = StemType.allCases.compactMap { stem -> MixInput? in
            guard selectedStems.contains(stem),
                  let url = record.url(for: stem),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                return nil
            }
            return MixInput(stem: stem, url: url, gainDecibels: levels[stem] ?? 0)
        }
        guard !inputs.isEmpty else { throw StemDropError.unreadableAudio }

        let format = prefs.outputFormat
        let bitDepth = prefs.wavBitDepth
        let style = prefs.namingStyle
        let conflict = prefs.conflictPolicy
        let albumTag = prefs.albumTag
        let configuredMixDirectory = URL(
            fileURLWithPath: prefs.mixOutputFolderPath,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: configuredMixDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw StemDropError.outputNotWritable
        }
        let sourceTags = await MetadataReader.read(record.sourceURL)
        let sourceTitle = sourceTags.title ?? record.displayName

        let destination = FileNaming.outputURL(
            source: record.sourceURL,
            label: "MIX",
            style: style,
            conflict: conflict,
            format: format,
            directory: configuredMixDirectory
        )

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stemdrop-mix-\(UUID().uuidString).wav")

        return try await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            let peak = try AudioMixer.render(inputs: inputs, to: temporaryURL)
            var settings = ExportSettings(format: format, bitDepth: bitDepth)
            settings.normalize = needsPeakProtection(peak: peak)
            settings.metadata = StemMetadata(
                artist: sourceTags.artist ?? sourceTags.albumArtist,
                album: albumTag,
                title: "\(sourceTitle) - MIX",
                year: sourceTags.year
            )
            try AudioExporter().write(stemWAV: temporaryURL, to: destination, settings: settings)
            return destination
        }.value
    }
}
