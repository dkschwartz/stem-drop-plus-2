import Foundation

/// The two gender stems produced by the "Male / Female" voice split.
enum SpeakerStem: String, CaseIterable, Codable {
    case male
    case female

    var displayName: String {
        switch self {
        case .male: return "Male Voice"
        case .female: return "Female Voice"
        }
    }
}
