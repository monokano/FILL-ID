import AppKit
import Carbon

/// グローバルホットキーで発火するアクション。
enum HotKeyAction {
    case paste, pasteTrim
    case toggleGrids
    case fitPage, fitSpread
    case zoomInDeselect, zoomOutDeselect
    case zoomInKeep, zoomOutKeep
}

/// グローバルホットキー管理。RegisterEventHotKey（Carbon Event Manager）を使用。
/// Accessibility 権限は不要。InDesign が最前面のときだけ `activate()` で登録する（HANDOFF.md §7）。
@MainActor
final class HotKeyManager {

    /// ホットキー発火時に呼ばれる。AppDelegate がアクションを実処理へ振り分ける。
    var onAction: ((HotKeyAction) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: HotKeyAction] = [:]
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x46494C69  // 'FILi'

    // MARK: - 有効化 / 無効化

    /// 現在の設定に従ってホットキーを登録する（InDesign 最前面化で呼ぶ）。
    func activate() {
        deactivate()
        installHandlerIfNeeded()
        registerFromPreferences()
    }

    /// すべてのホットキーを解除する（InDesign 離脱で呼ぶ）。
    func deactivate() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        actionsByID.removeAll()
        nextID = 1
    }

    fileprivate func handle(id: UInt32) {
        guard let action = actionsByID[id] else { return }
        onAction?(action)
    }

    // MARK: - 登録

    private func registerFromPreferences() {
        if Preferences.textPaste {
            add(0x09, UInt32(optionKey), .paste)               // ⌥V
            add(0x09, UInt32(optionKey | shiftKey), .pasteTrim) // ⇧⌥V
        }
        if Preferences.viewFit {
            add(0x52, UInt32(cmdKey), .fitPage)                // ⌘0（テンキー0）
            add(0x52, UInt32(cmdKey | optionKey), .fitSpread)  // ⌥⌘0
        }
        if Preferences.showHide {
            add(fkeyCode(Preferences.showHideFkeyIndex), 0, .toggleGrids) // F13 など（修飾なし）
        }
        if Preferences.zoom {
            add(0x45, UInt32(cmdKey), .zoomInDeselect)                 // ⌘＋（テンキー）
            add(0x4E, UInt32(cmdKey), .zoomOutDeselect)                // ⌘−
            add(0x45, UInt32(cmdKey | shiftKey), .zoomInKeep)          // ⇧⌘＋
            add(0x4E, UInt32(cmdKey | shiftKey), .zoomOutKeep)         // ⇧⌘−
        }
    }

    private func add(_ keyCode: UInt32, _ modifiers: UInt32, _ action: HotKeyAction) {
        let id = nextID
        nextID += 1
        let hkID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
            actionsByID[id] = action
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let st = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID)
                if st != noErr { return st }
                let id = hkID.id
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in manager.handle(id: id) }
                return noErr
            },
            1, &spec, selfPtr, &handlerRef)
    }

    /// Fキーのインデックス(0..18)を仮想キーコードへ（旧 SetFkeyCode）。
    private func fkeyCode(_ index: Int) -> UInt32 {
        let map: [UInt32] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, // F1..F10
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50        // F11..F19
        ]
        guard index >= 0 && index < map.count else { return 0x69 } // 既定 F13
        return map[index]
    }
}
