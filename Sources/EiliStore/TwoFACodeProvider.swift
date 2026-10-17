import Foundation
import SideSign

/// 2FA 方式選擇
public enum TwoFactorMethod: Sendable {
    case trustedDevice
    case sms(phoneID: String)
    case voice(phoneID: String)
}

/// 每次登入使用一個實例。所有可變狀態只在 stateLock 內存取；回呼與 resume 在鎖外執行。
public final class TwoFACodeProvider: @unchecked Sendable {
    private let stateLock = NSLock()
    private var cancelled = false
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var methodContinuation: CheckedContinuation<TwoFactorMethod, Error>?
    private var codeCallback: (@Sendable (TwoFactorDeliveryMode, Bool) -> Void)?
    private var methodCallback: (@Sendable ([TrustedPhoneNumber], TwoFactorDeliveryMode) -> Void)?
    private var logCallback: (@Sendable (String) -> Void)?

    public init() {}

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    public var isCancelled: Bool { withStateLock { cancelled } }

    public var onCodeRequired: (@Sendable (TwoFactorDeliveryMode, Bool) -> Void)? {
        get { withStateLock { codeCallback } }
        set { withStateLock { codeCallback = newValue } }
    }

    public var onMethodRequired: (@Sendable ([TrustedPhoneNumber], TwoFactorDeliveryMode) -> Void)? {
        get { withStateLock { methodCallback } }
        set { withStateLock { methodCallback = newValue } }
    }

    public var onLog: (@Sendable (String) -> Void)? {
        get { withStateLock { logCallback } }
        set { withStateLock { logCallback = newValue } }
    }

    public func log(_ message: String) {
        let callback = withStateLock { cancelled ? nil : logCallback }
        callback?(message)
    }

    public func awaitMethod(phoneNumbers: [TrustedPhoneNumber], preferred: TwoFactorDeliveryMode) async throws -> TwoFactorMethod {
        let result: TwoFactorMethod = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let callback = withStateLock { () -> (@Sendable ([TrustedPhoneNumber], TwoFactorDeliveryMode) -> Void)? in
                    guard !cancelled, methodContinuation == nil, codeContinuation == nil,
                          let callback = methodCallback else { return nil }
                    methodContinuation = continuation
                    return callback
                }
                guard let callback else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                callback(phoneNumbers, preferred)
            }
        }, onCancel: { self.cancel() })
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        return result
    }

    public func awaitCode(mode: TwoFactorDeliveryMode, rejected: Bool) async throws -> String {
        let result: String = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let callback = withStateLock { () -> (@Sendable (TwoFactorDeliveryMode, Bool) -> Void)? in
                    guard !cancelled, codeContinuation == nil, methodContinuation == nil,
                          let callback = codeCallback else { return nil }
                    codeContinuation = continuation
                    return callback
                }
                guard let callback else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                callback(mode, rejected)
            }
        }, onCancel: { self.cancel() })
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        return result
    }

    public func submitMethod(_ method: TwoFactorMethod) {
        let continuation = withStateLock { () -> CheckedContinuation<TwoFactorMethod, Error>? in
            guard !cancelled else { return nil }
            let current = methodContinuation
            methodContinuation = nil
            return current
        }
        continuation?.resume(returning: method)
    }

    public static func isValidCode(_ code: String) -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    public func submitCode(_ code: String) {
        guard Self.isValidCode(code) else { return }
        let continuation = withStateLock { () -> CheckedContinuation<String, Error>? in
            guard !cancelled else { return nil }
            let current = codeContinuation
            codeContinuation = nil
            return current
        }
        continuation?.resume(returning: code.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 冪等收尾：取消先於／晚於等待註冊都有效，不把舊碼帶到下一輪。
    public func cancel() {
        let continuations = withStateLock { () -> (CheckedContinuation<String, Error>?, CheckedContinuation<TwoFactorMethod, Error>?) in
            cancelled = true
            let current = (codeContinuation, methodContinuation)
            codeContinuation = nil
            methodContinuation = nil
            codeCallback = nil
            methodCallback = nil
            logCallback = nil
            return current
        }
        continuations.0?.resume(throwing: CancellationError())
        continuations.1?.resume(throwing: CancellationError())
    }
}
