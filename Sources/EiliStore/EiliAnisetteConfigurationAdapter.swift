import Foundation
import SideSign

extension EiliAnisetteClientConfiguration {
    /// Only the editable metadata is eligible for overrides. Provisioning UUID,
    /// OTP, machine ID, client time and ADI blobs are deliberately not configurable.
    var requestHeaderOverrides: [String: String] {
        let pairs = [
            ("X-Mme-Client-Info", clientInfo), ("User-Agent", userAgent),
            ("X-Mme-Device-Id", customDeviceID), ("X-Apple-I-MD-LU", customLocalUserID),
            ("X-Apple-I-SRL-NO", customSerialNumber), ("X-Apple-I-MD-RINFO", customRoutingInfo),
            ("X-Apple-Locale", customLocale), ("X-Apple-I-TimeZone", customTimeZone)
        ]
        return Dictionary(uniqueKeysWithValues: pairs.filter { !$0.1.isEmpty })
    }

    func applying(to data: SideSign.AnisetteData) -> SideSign.AnisetteData {
        var result = data
        if !clientInfo.isEmpty { result.clientInfo = clientInfo }
        if !userAgent.isEmpty { result.userAgent = userAgent }
        if !customDeviceID.isEmpty { result.deviceID = customDeviceID }
        if !customLocalUserID.isEmpty { result.localUserID = customLocalUserID }
        if !customSerialNumber.isEmpty { result.serialNumber = customSerialNumber }
        if !customRoutingInfo.isEmpty { result.routingInfo = customRoutingInfo }
        if !customLocale.isEmpty { result.locale = customLocale }
        if !customTimeZone.isEmpty { result.timeZone = customTimeZone }
        return result
    }

    func resolvedXcodeVersion(fallback: String = "27.0 (27A242)") -> String {
        customXcodeVersion.isEmpty ? fallback : customXcodeVersion
    }
}
