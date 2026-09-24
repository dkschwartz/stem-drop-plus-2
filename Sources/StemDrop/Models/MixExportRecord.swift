import Foundation

struct MixStemFile: Codable, Equatable, Sendable {
    let stem: StemType
    let url: URL
}

struct MixExportRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sourceURL: URL
    let createdAt: Date
    let stems: [MixStemFile]

    var displayName: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    func url(for stem: StemType) -> URL? {
        stems.first(where: { $0.stem == stem })?.url
    }
}
