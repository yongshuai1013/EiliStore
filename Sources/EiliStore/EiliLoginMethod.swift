import Foundation

/// 登入方式：SideSign（現行）或 Rust (isideload)（備用）。
/// 在「設定 → 用戶自定義」的 LOGIN 區切換，下次登入生效。
enum EiliLoginMethod: String, CaseIterable {
    case sideSign
    case rust

    static let preferenceKey = "eilistore.login.method"

    static var selected: EiliLoginMethod {
        let raw = UserDefaults.standard.string(forKey: preferenceKey)
        return EiliLoginMethod(rawValue: raw ?? "") ?? .sideSign
    }

    /// 保存 session 時一併記錄它是哪種登入方式領出來的（與 anisette
    /// 模式的 sessionKey 同一模式）。後續 Portal 操作按來源分流：
    /// Rust 領的 token 只在 isideload 自己的請求形狀下使用（B 路線），
    /// 塞進 SideSign 的形狀會被 Apple 回 1100。
    static let sessionOriginKey = "eilistore.auth.loginMethod"

    static var savedSessionOrigin: EiliLoginMethod {
        let raw = UserDefaults.standard.string(forKey: sessionOriginKey)
        return EiliLoginMethod(rawValue: raw ?? "") ?? .sideSign
    }
}

/// Rust 登入的 anisette 來源：App 現行那套（ODA Unicorn／遠端，經回調餵入，
/// 免 JIT）或 Apparition 原生引擎（RustLogin crate 內已含 ELF 載入器，
/// 在進程內直接執行 Android 庫，需 TrollStore 開 JIT；即 ODATest #20
/// 實證成功的那一條）。
enum EiliRustAnisetteSource: String, CaseIterable {
    case appProvided
    case nativeEngine

    static let preferenceKey = "eilistore.rustLogin.anisetteSource"

    static var selected: EiliRustAnisetteSource {
        let raw = UserDefaults.standard.string(forKey: preferenceKey)
        return EiliRustAnisetteSource(rawValue: raw ?? "") ?? .appProvided
    }
}

/// Rust 登入的用戶設定。
///
/// isideload 的登入自稱由 anisette provider 的 `get_client_info()` 決定，
/// 函式庫沒有現成的用戶設定；我們的 provider 把它做成 FFI 參數，所以這裡
/// 存的值會在登入時傳給 Rust。token 段的 Mac 自稱由 Rust 內部切換，不在此列。
enum EiliRustLoginSettings {
    static let androidClientInfoKey = "eilistore.rustLogin.androidClientInfo"

    /// 與 ODATest 實證成功的 Rust 登入相同的預設安卓標籤。
    static let defaultAndroidClientInfo = "<Pixel 8> <Android; 14; UQ1A.240205.004> <com.apple.AuthKit/1 (com.apple.android.music/4.9.6)>"

    static var androidClientInfo: String {
        let stored = UserDefaults.standard.string(forKey: androidClientInfoKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty {
            return stored
        }
        return defaultAndroidClientInfo
    }
}
