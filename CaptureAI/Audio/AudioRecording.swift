import Foundation

/// Metadados de uma gravação temporária.
struct AudioRecording: Equatable {
    let fileURL: URL
    let startedAt: Date
}
