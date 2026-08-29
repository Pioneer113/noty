import Foundation

/// Deck state tracing, off unless NOTY_DEBUG_DECK=1 is set in the environment.
enum DeckLog {
    static let enabled = ProcessInfo.processInfo.environment["NOTY_DEBUG_DECK"] == "1"

    static func line(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[deck] \(message())\n".utf8))
    }
}
