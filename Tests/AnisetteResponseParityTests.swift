import Foundation

// Compiles the real vendored response model. No provider/VM/Apple connection.
@main struct AnisetteResponseParityTests {
    static func main() throws {
        let otpKey = AnisetteConstants.Headers.oneTimePassword
        let machineKey = AnisetteConstants.Headers.machineID
        let empty = try AnisetteDataResponse(from: [otpKey: "", machineKey: ""])
        precondition(empty.oneTimePassword.isEmpty && empty.machineID.isEmpty)
        let ordinary = try AnisetteDataResponse(from: [otpKey: "synthetic-otp", machineKey: "synthetic-machine"])
        precondition(ordinary.oneTimePassword == "synthetic-otp" && ordinary.machineID == "synthetic-machine")
        for dictionary in [[:], [otpKey: ""], [machineKey: ""]] {
            do {
                _ = try AnisetteDataResponse(from: dictionary)
                fatalError("missing OTP/machineID key accepted")
            } catch AnisetteError.invalidResponse {}
        }
        print("PASS: real SideStore response model accepts present empty OTP/machineID and rejects absent keys (not login verification)")
    }
}
