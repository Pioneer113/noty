import Foundation
import SwiftUI
import CryptoKit

// MARK: - Paths

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noty", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static var db: URL { support.appendingPathComponent("notes.db") }
    static var key: URL { support.appendingPathComponent("note.key") }
}

// MARK: - Crypto (AES-GCM for note bodies)

enum Crypto {
    private static let key: SymmetricKey = {
        if let d = try? Data(contentsOf: Paths.key), d.count == 32 {
            return SymmetricKey(data: d)
        }
        let k = SymmetricKey(size: .bits256)
        let d = k.withUnsafeBytes { Data($0) }
        try? d.write(to: Paths.key, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Paths.key.path)
        return k
    }()

    static func seal(_ text: String) -> Data {
        guard let box = try? AES.GCM.seal(Data(text.utf8), using: key),
              let combined = box.combined else { return Data() }
        return combined
    }

    static func open(_ data: Data) -> String {
        guard !data.isEmpty,
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return "" }
        return String(decoding: plain, as: UTF8.self)
    }
}

// MARK: - Palette

struct NoteColor {
    let name: String
    let paper: Color      // note body background
    let dash: Color       // saturated edge dash / colour bar
    let ink: Color        // text colour on paper

    static let all: [NoteColor] = [
        NoteColor(name: "Lemon",  paper: hex(0xFFF3B0), dash: hex(0xF2C316), ink: hex(0x3D3312)),
        NoteColor(name: "Peach",  paper: hex(0xFFDCC2), dash: hex(0xF08A3C), ink: hex(0x43291A)),
        NoteColor(name: "Rose",   paper: hex(0xFFD3DC), dash: hex(0xE8577A), ink: hex(0x421C26)),
        NoteColor(name: "Lilac",  paper: hex(0xE3D5FF), dash: hex(0x8B5CF6), ink: hex(0x2E2145)),
        NoteColor(name: "Sky",    paper: hex(0xCFE8FF), dash: hex(0x2F8FE0), ink: hex(0x18303F)),
        NoteColor(name: "Mint",   paper: hex(0xC9F0DF), dash: hex(0x18A97B), ink: hex(0x143329)),
        NoteColor(name: "Sand",   paper: hex(0xEADFC8), dash: hex(0xB08A4A), ink: hex(0x3A2F1D)),
        NoteColor(name: "Slate",  paper: hex(0xD9E0E8), dash: hex(0x5C7183), ink: hex(0x1F2A33)),
    ]

    static func at(_ i: Int) -> NoteColor { all[((i % all.count) + all.count) % all.count] }

    private static func hex(_ v: UInt32) -> Color {
        Color(.sRGB,
              red:   Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue:  Double(v & 0xFF) / 255,
              opacity: 1)
    }
}

// MARK: - Model

struct Note: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var color: Int = 0
    var created: Date = Date()
    var modified: Date = Date()
    var archived: Bool = false
    var order: Double = 0

    var palette: NoteColor { NoteColor.at(color) }

    /// Title shown in the fan / lists, derived from the first non-empty line.
    static func derivedTitle(from body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var clean = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        clean = Tasks.stripped(clean)
        if clean.isEmpty { return "" }
        return clean.count > 60 ? String(clean.prefix(60)) + "…" : clean
    }

    var displayTitle: String { title.isEmpty ? "New note" : title }

    /// Completed / total, or nil when the note holds no tasks.
    var taskProgress: (done: Int, total: Int)? {
        var done = 0, total = 0
        for line in body.split(whereSeparator: \.isNewline) {
            switch Tasks.marker(of: line) {
            case Tasks.done: done += 1; total += 1
            case Tasks.open: total += 1
            default: break
            }
        }
        return total > 0 ? (done, total) : nil
    }

    /// Second line onwards, collapsed — used as list subtitle.
    var preview: String {
        let lines = body.split(whereSeparator: \.isNewline).map(String.init)
        let rest = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return rest.count > 120 ? String(rest.prefix(120)) + "…" : rest
    }
}

// MARK: - Tasks

/// Checkbox tasks are stored inline in the note body as ☐ / ☑ line prefixes, so a
/// note is still plain text and exports cleanly to Markdown task syntax.
enum Tasks {
    static let open: Character = "\u{2610}"    // ☐
    static let done: Character = "\u{2611}"    // ☑
    static let openPrefix = "\u{2610} "
    static let donePrefix = "\u{2611} "

    static func marker(of line: some StringProtocol) -> Character? {
        guard let f = line.first, f == open || f == done else { return nil }
        return f
    }

    static func isTask(_ line: some StringProtocol) -> Bool { marker(of: line) != nil }

    /// Strip the marker for display in lists and titles.
    static func stripped(_ line: some StringProtocol) -> String {
        guard isTask(line) else { return String(line) }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Markdown task syntax in, ☐/☑ out.
    static func fromMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "^(\\s*)[-*]\\s+\\[[ ]\\]\\s+",
                                  with: "$1" + openPrefix,
                                  options: [.regularExpression])
            .replacingOccurrences(of: "^(\\s*)[-*]\\s+\\[[xX]\\]\\s+",
                                  with: "$1" + donePrefix,
                                  options: [.regularExpression])
    }

    /// ☐/☑ out, Markdown task syntax in.
    static func toMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: openPrefix, with: "- [ ] ")
            .replacingOccurrences(of: donePrefix, with: "- [x] ")
    }
}

// MARK: - Formatting

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    static func ago(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 60 { return "just now" }
        return relative.localizedString(for: d, relativeTo: Date())
    }
}
