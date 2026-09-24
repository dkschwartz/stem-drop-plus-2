import XCTest
import AVFoundation
@testable import StemDrop

final class AudioMixerTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemDropAudioMixerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    func testMixAppliesStemLevelsAndReportsPeak() throws {
        let drums = testDirectory.appendingPathComponent("drums.wav")
        let bass = testDirectory.appendingPathComponent("bass.wav")
        let mixed = testDirectory.appendingPathComponent("mixed.wav")
        try writeConstantWAV(value: 0.4, to: drums)
        try writeConstantWAV(value: 0.4, to: bass)

        let peak = try AudioMixer.render(
            inputs: [
                MixInput(stem: .drums, url: drums, gainDecibels: 0),
                MixInput(stem: .bass, url: bass, gainDecibels: -6)
            ],
            to: mixed
        )

        XCTAssertEqual(peak, 0.4 + (0.4 * Float(pow(10.0, -6.0 / 20.0))), accuracy: 0.02)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixed.path))
    }

    func testMixDetectsWhenPeakProtectionIsRequired() throws {
        let drums = testDirectory.appendingPathComponent("drums.wav")
        let bass = testDirectory.appendingPathComponent("bass.wav")
        let mixed = testDirectory.appendingPathComponent("mixed.wav")
        try writeConstantWAV(value: 0.75, to: drums)
        try writeConstantWAV(value: 0.75, to: bass)

        let peak = try AudioMixer.render(
            inputs: [
                MixInput(stem: .drums, url: drums, gainDecibels: 0),
                MixInput(stem: .bass, url: bass, gainDecibels: 0)
            ],
            to: mixed
        )

        XCTAssertGreaterThan(peak, 1)
        XCTAssertTrue(MixExporter.needsPeakProtection(peak: peak))
        XCTAssertFalse(MixExporter.needsPeakProtection(peak: 0.5))
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
