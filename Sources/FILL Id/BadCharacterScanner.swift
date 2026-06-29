import Foundation

/// 「合成できない／使用を避けたい文字」の検出。旧 `Paste.HasBadCharacter` の移植。
enum BadCharacterScanner {

    /// 結合文字(\p{M}) / 私用領域(\p{Co}) / 国旗絵文字 / 肌色修飾子
    static let pattern = #"[\p{M}\p{Co}\x{1F1E6}-\x{1F1FF}\x{1F3FB}-\x{1F3FF}]"#

    private static let regex = try! NSRegularExpression(pattern: pattern)

    /// 不正文字を含むかどうか。
    static func hasBadCharacter(_ s: String) -> Bool {
        if s.isEmpty { return false }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return regex.firstMatch(in: s, range: range) != nil
    }

    /// `startIndex`（UTF-16 オフセット）以降で最初にマッチする範囲を返す。
    /// 見つからなければ nil。確認ウィンドウの「次へ」検索に使う。
    static func firstMatch(in s: String, fromUTF16Offset start: Int) -> NSRange? {
        let length = (s as NSString).length
        guard start <= length else { return nil }
        let range = NSRange(location: start, length: length - start)
        return regex.firstMatch(in: s, range: range)?.range
    }
}
