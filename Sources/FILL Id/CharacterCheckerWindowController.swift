import AppKit

/// 「合成できない文字の確認」ウィンドウ。旧 `ViewTextWindow` の移植。
/// テキスト中の不正文字を「次へ」で 1 つずつ検索・選択し、拡大表示とコードポイントを示す。
@MainActor
final class CharacterCheckerWindowController: NSWindowController {

    private let textView: NSTextView
    private let bigCharLabel = NSTextField(labelWithString: "")
    private let codepointLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(labelWithString: "")

    init() {
        // スクロール可能なテキストビュー
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 280))

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = NSLocalizedString("Check Uncompositable Character", comment: "Checker window title")
        window.minSize = NSSize(width: 320, height: 200)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = content

        super.init(window: window)

        // テキストビューの設定（旧 CustomTextArea 相当）
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: 13)

        // 上部バー
        let nextButton = NSButton(title: NSLocalizedString("Next", comment: "Find next"),
                                  target: self, action: #selector(findNext))
        nextButton.bezelStyle = .rounded
        nextButton.frame = NSRect(x: 12, y: 244, width: 80, height: 24)
        nextButton.autoresizingMask = [.maxXMargin, .minYMargin]

        bigCharLabel.frame = NSRect(x: 110, y: 240, width: 60, height: 32)
        bigCharLabel.font = .systemFont(ofSize: 26)
        bigCharLabel.alignment = .center
        bigCharLabel.autoresizingMask = [.maxXMargin, .minYMargin]

        codepointLabel.frame = NSRect(x: 180, y: 246, width: 188, height: 20)
        codepointLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        codepointLabel.textColor = .secondaryLabelColor
        codepointLabel.autoresizingMask = [.width, .minYMargin]

        // テキストビュー領域
        scroll.frame = NSRect(x: 0, y: 28, width: 380, height: 204)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true

        // 結果メッセージ
        resultLabel.frame = NSRect(x: 12, y: 6, width: 356, height: 16)
        resultLabel.font = .systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.autoresizingMask = [.width, .maxYMargin]

        content.addSubview(scroll)
        content.addSubview(nextButton)
        content.addSubview(bigCharLabel)
        content.addSubview(codepointLabel)
        content.addSubview(resultLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// テキストを表示してウィンドウを前面に出す。
    func show(text: String) {
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        bigCharLabel.stringValue = ""
        codepointLabel.stringValue = ""
        resultLabel.stringValue = ""
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func findNext() {
        bigCharLabel.stringValue = ""
        codepointLabel.stringValue = ""
        resultLabel.stringValue = ""

        let text = textView.string
        if text.isEmpty {
            resultLabel.stringValue = NSLocalizedString("There are no characters.", comment: "Empty text")
            return
        }

        let selection = textView.selectedRange()
        let start = selection.location + selection.length

        if let match = BadCharacterScanner.firstMatch(in: text, fromUTF16Offset: start) {
            select(match)
        } else if let wrapped = BadCharacterScanner.firstMatch(in: text, fromUTF16Offset: 0) {
            select(wrapped)
        } else {
            resultLabel.stringValue = NSLocalizedString("No uncompositable characters were found.", comment: "Not found")
        }
    }

    private func select(_ range: NSRange) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        let matched = (textView.string as NSString).substring(with: range)
        bigCharLabel.stringValue = matched
        codepointLabel.stringValue = codepoints(of: matched)
    }

    private func codepoints(of s: String) -> String {
        s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }
}
