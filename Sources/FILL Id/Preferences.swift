import Foundation

/// UserDefaults キー。旧 Xojo 版（Bundle ID `com.tama-san.FILLId`）と
/// 同一キーを用いることで、旧ユーザーの設定をそのまま引き継ぐ。
/// （旧キーの一覧は HANDOFF-Xojo.md §7 を参照）
enum PrefKey {
    static let version          = "prefsVer"

    // 機能グループの有効/無効
    static let textPaste        = "Mode:TextPaste"
    static let viewFit          = "Mode:ViewFit"
    static let zoom             = "Mode:Zoom"
    static let showHide         = "Mode:Show"

    // グリッド/ガイド表示プリセット
    static let showGuides         = "Show:Guides"
    static let showFrameEdges     = "Show:FrameEdges"
    static let showCharacterCount = "Show:CharacterCount"
    static let showInvisibles     = "Show:Invisibles"
    static let showFrameGrids     = "Show:FrameGrids"
    static let showLayoutGrids    = "Show:LayoutGrids"
    static let showBaselineGrid   = "Show:BaselineGrid"
    static let showDocumentGrid   = "Show:DocumentGrid"

    static let showHideFkeyIndex  = "Show:FkeyIndex"

    // 新版で追加（接頭辞 FILLId. で旧キーと衝突回避）
    static let pasteFlash         = "FILLId.pasteFlash"
}

/// 設定へのアクセサ。`UserDefaults.register(defaults:)` で既定値を与えるため、
/// 旧ユーザーは保存値が、新規ユーザーは既定値が読まれる（旧 SetDefault 相当）。
enum Preferences {

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PrefKey.textPaste: true,
            PrefKey.viewFit: true,
            PrefKey.zoom: true,
            PrefKey.showHide: true,

            PrefKey.showGuides: true,
            PrefKey.showFrameEdges: true,
            PrefKey.showCharacterCount: false,
            PrefKey.showInvisibles: false,
            PrefKey.showFrameGrids: true,
            PrefKey.showLayoutGrids: true,
            PrefKey.showBaselineGrid: false,
            PrefKey.showDocumentGrid: false,

            PrefKey.showHideFkeyIndex: 12,   // F13

            PrefKey.pasteFlash: true,
        ])
    }

    private static var ud: UserDefaults { .standard }

    // 機能グループ（既定はすべて ON）
    static var textPaste: Bool { ud.bool(forKey: PrefKey.textPaste) }
    static var viewFit:   Bool { ud.bool(forKey: PrefKey.viewFit) }
    static var zoom:      Bool { ud.bool(forKey: PrefKey.zoom) }
    static var showHide:  Bool { ud.bool(forKey: PrefKey.showHide) }

    // 表示切替に使う Fキー（0..18 → F1..F19）
    static var showHideFkeyIndex: Int { ud.integer(forKey: PrefKey.showHideFkeyIndex) }

    // ペースト時に画面を一瞬暗くするか（クリーンペーストの実行合図）
    static var pasteFlash: Bool { ud.bool(forKey: PrefKey.pasteFlash) }

    /// グリッド表示プリセット。InDesign 側 JS の `arr[0..7]` と同じ並びで返す。
    /// arr = [LayoutGrids, FrameGrids, CharacterCount, FrameEdges, Guides, DocumentGrid, BaselineGrid, Invisibles]
    /// （対応は HANDOFF-Xojo.md §5.3）
    static var gridPreset: [Bool] {
        [
            ud.bool(forKey: PrefKey.showLayoutGrids),
            ud.bool(forKey: PrefKey.showFrameGrids),
            ud.bool(forKey: PrefKey.showCharacterCount),
            ud.bool(forKey: PrefKey.showFrameEdges),
            ud.bool(forKey: PrefKey.showGuides),
            ud.bool(forKey: PrefKey.showDocumentGrid),
            ud.bool(forKey: PrefKey.showBaselineGrid),
            ud.bool(forKey: PrefKey.showInvisibles),
        ]
    }
}
