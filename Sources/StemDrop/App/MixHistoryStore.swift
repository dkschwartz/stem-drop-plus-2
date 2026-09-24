import Foundation

@MainActor
final class MixHistoryStore: ObservableObject {
    @Published private(set) var exports: [MixExportRecord]

    private let storageURL: URL
    private let fileManager: FileManager
    private let maximumCount: Int

    init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumCount: Int = 8
    ) {
        self.fileManager = fileManager
        self.maximumCount = maximumCount
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)
        self.exports = Self.load(from: self.storageURL)
    }

    func record(sourceURL: URL, stemURLs: [StemType: URL], date: Date = Date()) {
        let stemFiles = StemType.allCases.compactMap { stem in
            stemURLs[stem].map { MixStemFile(stem: stem, url: $0) }
        }
        guard !stemFiles.isEmpty else { return }

        let record = MixExportRecord(
            id: UUID(),
            sourceURL: sourceURL,
            createdAt: date,
            stems: stemFiles
        )
        exports.insert(record, at: 0)
        if exports.count > maximumCount {
            exports.removeLast(exports.count - maximumCount)
        }
        save()
    }

    private func save() {
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(exports)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Log.engine("could not save mix history: \(error)")
        }
    }

    private static func load(from url: URL) -> [MixExportRecord] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([MixExportRecord].self, from: data)
        else {
            return []
        }
        return Array(decoded.prefix(8))
    }

    private static func defaultStorageURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("StemDrop", isDirectory: true)
            .appendingPathComponent("mix-history.json")
    }
}
