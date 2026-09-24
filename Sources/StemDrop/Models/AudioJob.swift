import Foundation

enum JobStatus: Equatable {
    case queued
    case converting
    case separating
    case exporting
    case done
    case failed(String)

    /// Queued or in progress (not finished either way).
    var isActive: Bool {
        switch self {
        case .queued, .converting, .separating, .exporting: return true
        case .done, .failed: return false
        }
    }
}

enum JobKind: Equatable, Sendable {
    case split
    case cleanup
    case speakers
}

struct AudioJob: Identifiable {
    let id: UUID
    let sourceURL: URL
    let stems: Set<StemType>
    var status: JobStatus
    var progress: Double
    var outputs: [URL]
    var kind: JobKind = .split
    var cleanup: CleanupSettings? = nil
    /// For a `.cleanup` job: also split the cleaned vocal into Male/Female.
    var splitSpeakers: Bool = false
}
