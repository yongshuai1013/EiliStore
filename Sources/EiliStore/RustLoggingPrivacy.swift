import IDevice

/// Process-wide mitigation for logging from the prebuilt Rust IDevice payload.
/// Debug/trace logs can contain the full Remote Pairing dictionary, so they stay
/// disabled in every build. Release builds retain console errors only.
enum RustLoggingPrivacy {
    enum ConfigurationError: Error {
        case unavailable
    }

    // The first caller performs the C initialization; success or failure is
    // cached permanently so later callers cannot repeat a potentially unsafe init.
    private static let configuration: Result<Void, ConfigurationError> = {
        #if DEBUG
        let consoleLevel = Disabled
        #else
        let consoleLevel = ErrorLevel
        #endif
        let result = idevice_init_logger(consoleLevel, Disabled, nil)
        guard result == Success else {
            return .failure(.unavailable)
        }
        return .success(())
    }()

    /// Configure the prebuilt Rust logger before any device FFI is used.
    /// Failure is intentionally generic and contains no device/path details.
    static func ensureConfigured() throws {
        switch configuration {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }
}
