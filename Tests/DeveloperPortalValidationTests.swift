import Foundation

@main struct DeveloperPortalValidationTests {
    static func main() throws {
        try DeveloperPortalValidation.validateName("測試 名稱")
        expect(.emptyName) { try DeveloperPortalValidation.validateName(" \n") }
        expect(.invalidName) { try DeveloperPortalValidation.validateName("name\nsecret") }
        for id in ["com.example.app", "com.example.123-app"] {
            try DeveloperPortalValidation.validateBundleIdentifier(id)
        }
        for id in ["", "single", "com..app", "com.example.app\n", "com.例子.app", "com.app.*", " com.example.app"] {
            expect(.invalidBundleIdentifier) { try DeveloperPortalValidation.validateBundleIdentifier(id) }
        }
        try DeveloperPortalValidation.validateAppGroupIdentifier("group.com.example")
        for id in ["com.example.app", "group.", "group..example", "group.com.example\n"] {
            expect(.invalidAppGroupIdentifier) { try DeveloperPortalValidation.validateAppGroupIdentifier(id) }
        }
        for udid in [String(repeating: "a", count: 40), "01234567-0123456789abcdef", "01234567-89ab-cdef-0123-456789abcdef"] {
            try DeveloperPortalValidation.validateDeviceIdentifier(udid)
        }
        for udid in ["bad", String(repeating: "a", count: 25), String(repeating: "a", count: 40) + "\n", "01234567-0123456789abcdeg"] {
            expect(.invalidDeviceIdentifier) { try DeveloperPortalValidation.validateDeviceIdentifier(udid) }
        }
        for id in [nil, "", "  ", "ID with space", "ID\n"] as [String?] {
            expect(.missingIdentifier) { try DeveloperPortalValidation.requireIdentifier(id) }
        }
        try DeveloperPortalValidation.requireIdentifier("PORTAL-ID-123")
        print("DeveloperPortalValidationTests: OK")
    }
    static func expect(_ expected: DeveloperPortalValidationError, _ operation: () throws -> Void) {
        do { try operation(); fatalError("無效輸入被接受：\(expected)") }
        catch let error as DeveloperPortalValidationError { precondition(error == expected) }
        catch { fatalError("非預期的錯誤型別") }
    }
}
