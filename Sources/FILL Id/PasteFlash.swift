import AppKit
import QuartzCore

/// ペースト実行の合図として、画面を一瞬だけ暗くしてフェードする（旧版のディスプレイ・ガンマ変化のモダン版）。
/// 透過・クリックスルー・フォーカス非奪取のオーバーレイで、InDesign の最前面状態を乱さない。
@MainActor
final class PasteFlash {

    /// マウスのある画面を一瞬フラッシュする。
    func flash() {
        guard let screen = screenWithMouse() ?? NSScreen.main else { return }

        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true            // クリックは下のアプリへ素通り
        panel.level = .screenSaver                  // 全面・フルスクリーンの上にも出す
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0

        let view = NSView(frame: panel.frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        panel.contentView = view

        panel.orderFrontRegardless()                // アクティブ化せずに前面へ

        // じんわり暗く → ゆっくりフェードアウト（柔らかい合図）。
        // 完了ハンドラが panel を強参照するため、アニメーション中はパネルが保持される（配列管理不要）。
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.18           // 薄めのピーク
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.42
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0.0        // ゆっくり消える
            }, completionHandler: {
                panel.orderOut(nil)
            })
        })
    }

    private func screenWithMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}
