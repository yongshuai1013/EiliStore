import Foundation

/// Transient on-screen state only. Never persist, copy to a pasteboard, or log its contents.
struct PairingFieldDisclosure: CustomStringConvertible, CustomDebugStringConvertible {
    private(set) var field: String?
    private var text: String?

    var description: String { "PairingFieldDisclosure(content hidden)" }
    var debugDescription: String { description }

    func value(for field: String, isActive: Bool) -> String? {
        guard isActive, self.field == field else { return nil }
        return text
    }

    mutating func toggle(_ field: String, isActive: Bool, load: () throws -> String) throws {
        let wasVisible = self.field == field
        // Clear the previous value before reading another field, including on failure.
        hide()
        guard isActive, !wasVisible else { return }
        let value = try load()
        self.field = field
        text = value
    }

    mutating func hide() {
        field = nil
        text = nil
    }
}
