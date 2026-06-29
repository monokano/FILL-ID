import Foundation
import CoreServices

/// InDesign へ Apple イベントを送る「オートメーション（自動化）」許可の状態を調べる。
/// 旧版は MBS の AccessibilityMBS を使っていたが、本アプリが必要とするのは自動化許可のみ。
enum AutomationPermission {

    enum State {
        case granted        // 許可済み
        case denied         // 拒否
        case notDetermined  // 未確定（まだ尋ねていない）
        case targetNotRunning // 対象アプリが起動していない
        case unknown
    }

    /// 指定 Bundle ID のアプリに対する自動化許可の状態。`prompt` が true なら必要に応じて同意ダイアログを出す。
    static func state(forBundleID bundleID: String, prompt: Bool = false) -> State {
        guard let data = bundleID.data(using: .utf8) else { return .unknown }

        var target = AEAddressDesc()
        let createStatus = data.withUnsafeBytes { raw in
            AECreateDesc(typeApplicationBundleID, raw.baseAddress, raw.count, &target)
        }
        guard createStatus == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, prompt)
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(-1744): // errAEEventWouldRequireUserConsent
            return .notDetermined
        case OSStatus(procNotFound):
            return .targetNotRunning
        default:
            return .unknown
        }
    }
}
