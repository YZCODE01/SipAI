// NotificationCoordinator.swift
// UNUserNotificationCenter delegate. Handles user taps on MCP
// approval notifications — activates the app and signals the app to
// navigate to the originating session.
//
// Wired in SipAIApp on first launch. The actual navigation
// (AppState mutation) is performed by the closure SipAIApp sets on
// `onApprovalClicked`, which has access to AppState + AgentManager.

import Foundation
import AppKit
import UserNotifications

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    /// Invoked on the main thread when the user clicks an MCP
    /// approval notification. Arguments are the raw session_id and
    /// task_uuid strings from `userInfo`; the receiver decides which
    /// one to route off (session_id if it's non-empty, else
    /// task_uuid). The closure is responsible for flipping AppState
    /// routing fields as appropriate.
    var onApprovalClicked: ((_ sessionId: String, _ taskUuid: String) -> Void)?

    /// Show banners while the app IS active too — by default macOS
    /// silently delivers notifications to an active app, but for
    /// permission prompts the user may be looking at the dock or
    /// a different window; the badge + banner is still useful.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = (info["kind"] as? String) ?? ""
        if kind == "mcp-approval" {
            let sessionId = (info["sessionId"] as? String) ?? ""
            let taskUuid = (info["taskUuid"] as? String) ?? ""
            // Bring the app forward before mutating AppState so the
            // routing change is visible immediately.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak self] in
                self?.onApprovalClicked?(sessionId, taskUuid)
            }
        }
        completionHandler()
    }
}
