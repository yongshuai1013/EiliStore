import Foundation

final class RustDeviceTransport {
    enum Service { case afc }
    func connect(_ service: Service, host: String, pairingFileURL: URL) throws -> OpaquePointer {
        return OpaquePointer(bitPattern: 0x100)!
    }
    func disconnect() {}
}

final class RustFFILock {
    static let shared = RustFFILock()
    private let lock = NSRecursiveLock()
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    static func isTransportError(_ error: Error) -> Bool { false }
}
