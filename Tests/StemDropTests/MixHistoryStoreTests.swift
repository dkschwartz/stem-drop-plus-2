import XCTest
@testable import StemDrop

final class MixHistoryStoreTests: XCTestCase {
    private var testDirectory: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemDropMixHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        storageURL = testDirectory.appendingPathComponent("mix-history.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    @MainActor
    func testKeepsNewestEightAndRestoresThem() {
        let store = MixHistoryStore(storageURL: storageURL)

        for index in 0..<10 {
            store.record(
                sourceURL: testDirectory.appendingPathComponent("Song \(index).wav"),
                stemURLs: [
                    .drums: testDirectory.appendingPathComponent("Song \(index) - Drums.wav")
                ],
                date: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(store.exports.count, 8)
        XCTAssertEqual(store.exports.first?.displayName, "Song 9")
        XCTAssertEqual(store.exports.last?.displayName, "Song 2")

        let restored = MixHistoryStore(storageURL: storageURL)
        XCTAssertEqual(restored.exports, store.exports)
    }

    @MainActor
    func testStoresStemTypesWithTheirFiles() {
        let store = MixHistoryStore(storageURL: storageURL)
        let source = testDirectory.appendingPathComponent("Song.wav")
        let drums = testDirectory.appendingPathComponent("Song - Drums.wav")
        let bass = testDirectory.appendingPathComponent("Song - Bass.wav")

        store.record(sourceURL: source, stemURLs: [.drums: drums, .bass: bass])

        XCTAssertEqual(store.exports.first?.url(for: .drums), drums)
        XCTAssertEqual(store.exports.first?.url(for: .bass), bass)
        XCTAssertNil(store.exports.first?.url(for: .vocals))
    }
}
