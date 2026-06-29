import AppKit

/// クリーンペースト。旧 `Paste` モジュールの移植。
/// クリップボード → NFC正規化(合成除外保護) → 改行CR化 → (任意トリム) → 不正文字チェック → InDesign へ流し込み。
@MainActor
final class PasteService {

    private let indesign: InDesignController
    private let flash = PasteFlash()

    /// 「確認する」が選ばれたときに、合成不可文字チェックウィンドウを開くためのコールバック。
    var onShowChecker: ((String) -> Void)?

    init(indesign: InDesignController) {
        self.indesign = indesign
    }

    /// ペースト実行の合図（設定がオンのとき画面を一瞬暗くする）。
    private func flashIfEnabled() {
        if Preferences.pasteFlash { flash.flash() }
    }

    /// ペーストを実行する。`target` は発火時に捕捉した InDesign インスタンス。`trim` で前後空白を除去（⇧⌥V）。
    func run(target: InDesignTarget, trim: Bool) {
        guard indesign.isSetCursor(target) else { return }
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return }

        var s = TextNormalizer.nfcSafe(raw)
        s = TextNormalizer.unifyToCR(s)
        if trim {
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s.isEmpty else { return }

        if BadCharacterScanner.hasBadCharacter(s) {
            showBadCharacterAlert(s, target: target)
        } else {
            indesign.setText(s, target: target)
            flashIfEnabled()
        }
    }

    private func showBadCharacterAlert(_ s: String, target: InDesignTarget) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "Some characters cannot be composed.",
            comment: "Bad character alert title")
        alert.informativeText = NSLocalizedString(
            "It is better to avoid characters that cannot be composed.",
            comment: "Bad character alert body")
        alert.addButton(withTitle: NSLocalizedString("Check", comment: "Open checker"))   // 確認する
        alert.addButton(withTitle: NSLocalizedString("Paste", comment: "Paste anyway"))   // ペースト
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel paste"))  // 中止

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:   // 確認する
            onShowChecker?(s)
        case .alertSecondButtonReturn:  // ペースト
            indesign.setText(s, target: target)
            flashIfEnabled()
            indesign.activate(target)   // ペースト後に対象 InDesign を前面へ戻す
        default:                        // 中止
            break
        }
    }
}
