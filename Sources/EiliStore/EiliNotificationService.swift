import Foundation
import UserNotifications

/// 本地通知服務：刷新結果通知＋到期前提醒。
///
/// 學 SideStore 的作法——全部走 UNUserNotificationCenter 本地通知，
/// 不經任何伺服器，也不需要 APNs 或付費開發者帳號：
/// - 刷新結果：對照 SideStore `BackgroundRefreshAppsOperation` 的完成
///   通知（成功給摘要、失敗給原因）。原版對 noConnection／noVPN 這類
///   環境錯誤不發通知，這裡比照辦理：「連接設備失敗／找不到配對檔」
///   由呼叫端直接不呼叫本服務，避免每次啟動自動刷新都吵一次。
/// - 到期前提醒：對照 `ScheduleExpirationWarningNotificationOperation`，
///   在到期前 24 小時、6 小時與到期時各排一則，刷新後依最新效期重排。
final class EiliNotificationService: NSObject {
    static let shared = EiliNotificationService()

    /// 帶效期資訊的 App（到期提醒排程用）。
    typealias ExpiringApp = (name: String, bundleId: String, expirationDate: Date)

    /// 到期提醒的通知 ID 前綴，後接 bundleId 與里程碑（24h／6h／0h）。
    static let expirationWarningIdentifierPrefix = "eilistore-expiration-warning"
    /// 刷新結果通知的固定 ID（新結果直接覆蓋舊的未讀通知）。
    static let refreshResultIdentifier = "eilistore-refresh-result"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - 授權

    /// 尚未決定授權時才向使用者請求；已允許或已拒絕都回傳現況、不再打擾。
    private func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    // MARK: - 刷新結果通知

    /// 批次刷新在逐個處理前就整批失敗（如登入 Session 失效、沒有 Team）時
    /// 發一則失敗通知。環境類失敗（連接設備／配對檔）請勿呼叫本方法。
    func notifyRefreshFailed(reason: String) {
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = "刷新失敗"
            content.body = reason
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: Self.refreshResultIdentifier,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// 刷新跑完後發結果摘要：全部成功列出 App 名稱；部分或全部失敗講數量。
    func notifyRefreshFinished(refreshedNames: [String], failCount: Int) {
        guard !refreshedNames.isEmpty || failCount > 0 else { return }
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            if failCount == 0 {
                content.title = "刷新完成"
                content.body = "已刷新 \(refreshedNames.count) 個 App：\(refreshedNames.joined(separator: "、"))"
            } else if refreshedNames.isEmpty {
                content.title = "刷新失敗"
                content.body = "\(failCount) 個 App 刷新失敗，打開 EiliStore 查看日誌。"
            } else {
                content.title = "刷新完成（部分失敗）"
                content.body = "成功 \(refreshedNames.count) 個、失敗 \(failCount) 個。打開 EiliStore 查看日誌。"
            }
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: Self.refreshResultIdentifier,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - 到期前提醒

    /// 為清單裡每個 App 依其效期重排到期提醒。
    func scheduleExpirationWarningsForAll(apps: [ExpiringApp]) {
        for app in apps {
            scheduleExpirationWarnings(
                name: app.name,
                bundleId: app.bundleId,
                expirationDate: app.expirationDate
            )
        }
    }

    /// 依最新效期為單一 App 重排到期提醒：先清掉舊的排程，
    /// 再排下還沒過的里程碑（到期前 24 小時、6 小時、到期時）。
    func scheduleExpirationWarnings(name: String, bundleId: String, expirationDate: Date) {
        // 比照 SideStore：模擬器（UI 測試環境）不排程、也不跳授權請求。
        #if !targetEnvironment(simulator)
        Task {
            guard await ensureAuthorized() else { return }
            let center = UNUserNotificationCenter.current()
            let milestones: [(id: String, secondsBefore: TimeInterval, title: String, body: String)] = [
                ("24h", 24 * 60 * 60, "\(name) 即將到期", "\(name) 的簽名將在 24 小時後到期，打開 EiliStore 刷新可避免到期。"),
                ("6h", 6 * 60 * 60, "\(name) 即將到期", "\(name) 的簽名將在 6 小時後到期，請盡快打開 EiliStore 刷新。"),
                ("0h", 0, "\(name) 已到期", "\(name) 的簽名已到期，請打開 EiliStore 刷新或重新安裝。")
            ]
            let identifiers = milestones.map {
                "\(Self.expirationWarningIdentifierPrefix).\($0.id).\(bundleId)"
            }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)

            let now = Date()
            for (index, milestone) in milestones.enumerated() {
                let targetDate = expirationDate.addingTimeInterval(-milestone.secondsBefore)
                let interval = targetDate.timeIntervalSince(now)
                // 已過的里程碑不排（例如只剩 3 小時才刷新，就只排 0h 那則）。
                guard interval > 0 else { continue }

                let content = UNMutableNotificationContent()
                content.title = milestone.title
                content.body = milestone.body
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                let request = UNNotificationRequest(
                    identifier: identifiers[index],
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }
        #endif
    }
}

extension EiliNotificationService: UNUserNotificationCenterDelegate {
    /// App 在前景時也顯示通知橫幅，讓使用者手動刷新完能立刻看到結果。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
