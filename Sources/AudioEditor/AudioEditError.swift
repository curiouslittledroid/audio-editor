import Foundation

enum AudioEditError: LocalizedError {
    case unreadable(String)
    case emptyAudio
    case unsupportedType(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "“\(name)” could not be read as an audio file."
        case .emptyAudio:
            return "This audio file contains no samples."
        case .unsupportedType(let ext):
            return "Files of type “.\(ext)” are not supported yet. Please choose a .wav file."
        case .exportFailed(let reason):
            return "The trimmed audio could not be saved. \(reason)"
        }
    }
}
