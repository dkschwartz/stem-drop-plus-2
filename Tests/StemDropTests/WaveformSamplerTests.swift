import XCTest
import AVFoundation
@testable import StemDrop

final class WaveformSamplerTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemDropWaveformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    func testSilentAudioProducesFlatWaveform() throws {
        let audio = testDirectory.appendingPathComponent("silent.wav")
        try writeConstantWAV(value: 0, to: audio)

        let samples = WaveformSampler.samples(for: audio, count: 24)

        XCTAssertEqual(samples.count, 24)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
    }

    func testAudibleAudioProducesNormalizedWaveform() throws {
        let audio = testDirectory.appendingPathComponent("signal.wav")
        try writeConstantWAV(value: 0.25, to: audio)

        let samples = WaveformSampler.samples(for: audio, count: 24)

        XCTAssertEqual(samples.count, 24)
        XCTAssertTrue(samples.contains { $0 > 0 })
        XCTAssertEqual(samples.max() ?? 0, 1, accuracy: 0.001)
    }

    private func writeConstantWAV(value: Float, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)
        else {
            XCTFail("Could not create test audio format")
            return
        }

        buffer.frameLength = 4_410
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData?[channel][frame] = value
            }
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}
