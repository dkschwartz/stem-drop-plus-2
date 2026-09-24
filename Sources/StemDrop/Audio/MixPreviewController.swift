import Foundation
import AVFoundation
import Darwin

@MainActor
final class MixPreviewController: ObservableObject {
    enum State: Equatable {
        case stopped
        case playing
        case paused
    }

    @Published private(set) var state: State = .stopped

    private var engine: AVAudioEngine?
    private var players: [StemType: AVAudioPlayerNode] = [:]
    private var files: [AVAudioFile] = []
    private var completedPlayers = 0
    private var playbackGeneration = UUID()

    func play(files stemFiles: [StemType: URL], levels: [StemType: Double]) throws {
        if state == .paused {
            resume()
            return
        }

        stop()
        guard !stemFiles.isEmpty else { return }

        let engine = AVAudioEngine()
        let generation = UUID()
        playbackGeneration = generation
        completedPlayers = 0

        for stem in StemType.allCases {
            guard let url = stemFiles[stem] else { continue }
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                stop()
                throw StemDropError.unreadableAudio
            }

            let player = AVAudioPlayerNode()
            player.volume = linearGain(for: levels[stem] ?? 0)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor in
                    self?.playerFinished(generation: generation)
                }
            }
            players[stem] = player
            files.append(file)
        }

        do {
            try engine.start()
        } catch {
            stop()
            throw StemDropError.unreadableAudio
        }

        self.engine = engine
        let startTime = AVAudioTime(
            hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08)
        )
        players.values.forEach { $0.play(at: startTime) }
        state = .playing
    }

    func pause() {
        guard state == .playing else { return }
        players.values.forEach { $0.pause() }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        let startTime = AVAudioTime(
            hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
        )
        players.values.forEach { $0.play(at: startTime) }
        state = .playing
    }

    func stop() {
        playbackGeneration = UUID()
        players.values.forEach { $0.stop() }
        engine?.stop()
        if let engine {
            players.values.forEach { engine.detach($0) }
        }
        players.removeAll()
        files.removeAll()
        engine = nil
        completedPlayers = 0
        state = .stopped
    }

    func setLevel(_ decibels: Double, for stem: StemType) {
        players[stem]?.volume = linearGain(for: decibels)
    }

    private func playerFinished(generation: UUID) {
        guard generation == playbackGeneration else { return }
        completedPlayers += 1
        if completedPlayers >= players.count {
            stop()
        }
    }

    private func linearGain(for decibels: Double) -> Float {
        Float(pow(10.0, decibels / 20.0))
    }
}
