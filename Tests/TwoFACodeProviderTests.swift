import Foundation
import SideSign

// 由 run-twofa-tests.sh 以獨立程序執行；所有碼與電話 ID 都是合成測試資料。
@main
@MainActor
struct TwoFACodeProviderTests {
    static func expectCancellation<T>(_ operation: () async throws -> T) async {
        do {
            _ = try await operation()
            fatalError("預期取消，但等待正常返回")
        } catch is CancellationError {
        } catch {
            fatalError("非預期錯誤類型")
        }
    }

    static func main() async throws {
        assert(TwoFACodeProvider.isValidCode(" 123456\n"))
        assert(!TwoFACodeProvider.isValidCode("12345"))
        assert(!TwoFACodeProvider.isValidCode("１２３４５６"))
        assert(!TwoFACodeProvider.isValidCode("12 456"))

        // 先安裝 continuation 才呼叫 UI；同步提交不會遺失喚醒。
        let codeProvider = TwoFACodeProvider()
        codeProvider.onCodeRequired = { mode, rejected in
            assert(mode == .sms && !rejected)
            codeProvider.submitCode("invalid")
            codeProvider.submitCode(" 123456 ")
            codeProvider.submitCode("654321") // 重複輸入不得污染下一輪。
        }
        let first = try await codeProvider.awaitCode(mode: .sms, rejected: false)
        assert(first == "123456")
        codeProvider.onCodeRequired = { mode, rejected in
            assert(mode == .voice && rejected)
            codeProvider.submitCode("234567")
        }
        let second = try await codeProvider.awaitCode(mode: .voice, rejected: true)
        assert(second == "234567")
        codeProvider.cancel()

        let methodProvider = TwoFACodeProvider()
        methodProvider.onMethodRequired = { phones, preferred in
            assert(phones.first?.id == "test-phone" && preferred == .voice)
            methodProvider.submitMethod(.voice(phoneID: "test-phone"))
        }
        let method = try await methodProvider.awaitMethod(
            phoneNumbers: [TrustedPhoneNumber(id: "test-phone", number: "")], preferred: .voice
        )
        guard case .voice(let phoneID) = method, phoneID == "test-phone" else {
            fatalError("選擇方式未被正確傳遞")
        }
        methodProvider.cancel()

        let alreadyCancelled = TwoFACodeProvider()
        alreadyCancelled.cancel()
        alreadyCancelled.cancel()
        await expectCancellation { try await alreadyCancelled.awaitCode(mode: .sms, rejected: false) }
        await expectCancellation { try await alreadyCancelled.awaitMethod(phoneNumbers: [], preferred: .sms) }

        // 等待註冊後取消；cancel 可重入，不重複 resume。
        let cancelCode = TwoFACodeProvider()
        cancelCode.onCodeRequired = { _, _ in
            cancelCode.cancel()
            cancelCode.cancel()
            cancelCode.submitCode("123456")
        }
        await expectCancellation { try await cancelCode.awaitCode(mode: .trustedDevice, rejected: false) }
        assert(cancelCode.onCodeRequired == nil)

        let cancelMethod = TwoFACodeProvider()
        cancelMethod.onMethodRequired = { _, _ in cancelMethod.cancel() }
        await expectCancellation { try await cancelMethod.awaitMethod(phoneNumbers: [], preferred: .sms) }

        // 缺少 UI handler 時立即終止，不留下永遠等不到的 continuation。
        let noUI = TwoFACodeProvider()
        await expectCancellation { try await noUI.awaitCode(mode: .sms, rejected: false) }
        await expectCancellation { try await noUI.awaitMethod(phoneNumbers: [], preferred: .sms) }
        noUI.cancel()

        // 真正 Task.cancel()，而非僅呼叫 provider.cancel()。
        let taskProvider = TwoFACodeProvider()
        let ready = AsyncStream<Bool> { continuation in
            taskProvider.onCodeRequired = { _, _ in
                continuation.yield(true)
                continuation.finish()
            }
        }
        let task = Task { try await taskProvider.awaitCode(mode: .sms, rejected: false) }
        var readyIterator = ready.makeAsyncIterator()
        _ = await readyIterator.next()
        task.cancel()
        await expectCancellation { try await task.value }
        assert(taskProvider.isCancelled)

        // 高頻 submit/cancel 競態：只允許提交或取消其中一種完成結果。
        for _ in 0..<200 {
            let provider = TwoFACodeProvider()
            provider.onCodeRequired = { _, _ in
                Task.detached { provider.submitCode("123456") }
                Task.detached { provider.cancel() }
            }
            do {
                let code = try await provider.awaitCode(mode: .sms, rejected: false)
                assert(code == "123456")
            } catch is CancellationError {
            }
            provider.cancel()
        }
        print("PASS: 格式、提交、重複輸入隔離、模式／電話 ID、取消前後競態、Task 取消與 200 次並行競態")
    }
}
