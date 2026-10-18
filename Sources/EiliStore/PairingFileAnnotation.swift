import Foundation

/// User-authored local labels only. Never populated from plist values or legacy filenames.
struct PairingFileAnnotation: Codable, Equatable, Sendable {
    static let empty = PairingFileAnnotation(displayName: "", note: "")
    static let maximumNameLength = 60
    static let maximumNoteLength = 300

    var displayName: String
    var note: String

    func validated() throws -> PairingFileAnnotation {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t"))
        guard name.count <= Self.maximumNameLength, note.count <= Self.maximumNoteLength,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !note.unicodeScalars.contains(where: { forbidden.contains($0) }) else {
            throw PairingStoreError.invalidAnnotation
        }
        return PairingFileAnnotation(displayName: name, note: note)
    }
}
