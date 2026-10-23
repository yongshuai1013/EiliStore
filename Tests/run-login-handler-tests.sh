#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -x /workspace/tooling/swift603/usr/bin/swiftc ]]; then export PATH="/workspace/tooling/swift603/usr/bin:$PATH"; fi
command -v swiftc >/dev/null || { echo 'swiftc not found' >&2; exit 2; }
build=$(mktemp -d); home=$(mktemp -d)
trap 'rm -rf "$build" "$home"' EXIT
python3 - "$build/LoginHandlerHarness.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/EiliStore/LoginView.swift').read_text()
start = source.index('    private func doLogin()')
end = source.index('\n}\n\n// MARK: - 已登入', start)
methods = source[start:end].replace('private func ', 'func ')
# Compile the actual method bodies, not a separately maintained copy of the handler.
prefix = '''import Foundation
import SideSign
@propertyWrapper struct HandlerState<Value> {
    final class Storage {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    private let storage: Storage
    init(wrappedValue: Value) { storage = Storage(wrappedValue) }
    var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }
}
@MainActor struct LoginHandlerHarness {
    var appleID = ""
    var isLoggedIn = false
    var password = ""
    var verificationCode = ""
    var errorMessage: String?
    var codeMessage = ""
    var isLoading = false
    var needs2FA = false
    var loginTask: Task<Void, Never>?
    var codeProvider: TwoFACodeProvider?
    var activeDiagnosticAttempt: UUID?
    var showMethodPicker = false
    var availablePhones: [TrustedPhoneNumber] = []
    var preferredMethod: TwoFactorDeliveryMode = .sms
    var debugLog = ""
    func log(_ message: String) { debugLog += message + "\\n" }
'''
head, body = prefix.split('@MainActor struct LoginHandlerHarness {', 1)
prefix = head + '@MainActor struct LoginHandlerHarness {' + body.replace('    var ', '    @HandlerState var ')
Path(sys.argv[1]).write_text(prefix + methods + '\n}\n')
# Explicit-ID diagnostics must not regain an implicit task-local dependency.
for name in ['EiliLoginDiagnostics.swift', 'PaxAuthService.swift', 'EiliAnisetteService.swift']:
    text = Path('Sources/EiliStore', name).read_text()
    assert '@TaskLocal' not in text and '$attempt.withValue' not in text, name
PY
swiftc -swift-version 5 -parse-as-library -emit-module -emit-object -module-name SideSign \
  -emit-module-path "$build/SideSign.swiftmodule" Tests/Fixtures/PaxAuthSideSignStub.swift -o "$build/SideSign.o"
swiftc -swift-version 5 -parse-as-library -D LOGIN_HANDLER_TESTS -I "$build" \
  Sources/EiliStore/EiliLoginDiagnostics.swift Sources/EiliStore/TwoFACodeProvider.swift \
  Sources/EiliStore/PaxAuthService.swift Tests/PaxAuthServiceFlowTests.swift \
  "$build/LoginHandlerHarness.swift" Tests/LoginHandlerTests.swift "$build/SideSign.o" -o "$build/login-handler-tests"
HOME="$home" "$build/login-handler-tests"
