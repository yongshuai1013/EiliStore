import Foundation
import SideSign

/// Offline-test stand-in for the Rust (isideload) login service: the real
/// EiliRustAuthService calls the RustLogin static library, which the offline
/// harnesses do not link. The flows under test never select the Rust method
/// (fresh test HOME → empty UserDefaults → SideSign default), so this only
/// needs to satisfy the compiler with the same interface.
final class EiliRustAuthService {
    static let shared = EiliRustAuthService()
    private init() {}

    enum RustLoginError: LocalizedError {
        case failed(String)
        case badResult(String)

        var errorDescription: String? { "Rust 登入在離線測試中不可用" }
    }

    func login(
        appleID: String,
        password: String,
        xcodeVersion: String,
        codeProvider: TwoFACodeProvider,
        fetchAnisette: @escaping (Bool) async -> SideSign.AnisetteData?
    ) async throws -> SideSign.AuthSession {
        throw RustLoginError.failed("offline test stub")
    }
}
