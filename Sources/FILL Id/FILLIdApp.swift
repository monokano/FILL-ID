import SwiftUI
import AppKit

/// 表示モード（メニューバー / Dock / 両方）
enum DisplayMode: String, CaseIterable, Identifiable {
    case menuBar    // メニューバーのみ
    case dock       // Dockのみ
    case both       // 両方表示

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .menuBar: return "Menu Bar Only"
        case .dock:    return "Dock Only"
        case .both:    return "Menu Bar and Dock"
        }
    }
}

enum DisplayModeStore {
    static let key = "FILLId.displayMode"
    static let defaultValue: DisplayMode = .both

    static func load() -> DisplayMode {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let mode = DisplayMode(rawValue: raw) else {
            return defaultValue
        }
        return mode
    }
}

extension Notification.Name {
    static let displayModeChanged = Notification.Name("FILLId.displayModeChanged")
    static let openSettingsRequested = Notification.Name("FILLId.openSettingsRequested")
    /// indd表示設定ウィンドウを開く要求。
    static let openInddDisplaySettingsRequested = Notification.Name("FILLId.openInddDisplaySettingsRequested")
    /// 設定（機能の有効/無効・Fキー等）が変わったとき。ホットキー再登録に使う。
    static let preferencesChanged = Notification.Name("FILLId.preferencesChanged")
}

@main
struct FILLIdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // ⌘キーを押しながら起動 → 表示モードのみリセット（ノッチでアイコンが隠れた場合の救済）
        if NSEvent.modifierFlags.contains(.command) {
            UserDefaults.standard.removeObject(forKey: DisplayModeStore.key)
            AppDelegate.shouldShowResetAlert = true
        }
    }

    var body: some Scene {
        // 設定ウィンドウは AppDelegate 側で自前の NSWindow として表示する。
        // この Settings シーンは Scene 要件を満たすためのダミー（開かれない）。
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings...") {
                        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                    }
                    .keyboardShortcut(",")
                    Button("Document Display Settings...") {
                        NotificationCenter.default.post(name: .openInddDisplaySettingsRequested, object: nil)
                    }
                    .keyboardShortcut(",", modifiers: [.command, .option])
                }
                CommandGroup(replacing: .help) {
                    Button("FILL Id Help") {
                        appDelegate.openHelp()
                    }
                    .keyboardShortcut("?", modifiers: .command)
                    Divider()
                    Button("Change Log") {
                        appDelegate.openChangeLog()
                    }
                }
            }
    }
}
