import Foundation

/// テキスト正規化。旧 Xojo 版 `UnicodeNormalization` の移植。
enum TextNormalizer {

    /// 合成除外文字（Composition Exclusions, astral 含む）。
    /// 旧 `UnicodeNormalization.CompositionExclusions` 定数から移植（HANDOFF-Xojo.md §8）。
    /// raw string literal なのでバックスラッシュはそのまま ICU の `\x{...}` として解釈される。
    private static let compositionExclusionsPattern =
        #"[\x{0340}\x{0341}\x{0343}\x{0344}\x{0374}\x{037E}\x{0387}\x{0958}-\x{095F}\x{09DC}\x{09DD}\x{09DF}\x{0A33}\x{0A36}\x{0A59}-\x{0A5B}\x{0A5E}\x{0B5C}\x{0B5D}\x{0F43}\x{0F4D}\x{0F52}\x{0F57}\x{0F5C}\x{0F69}\x{0F73}\x{0F75}\x{0F76}\x{0F78}\x{0F81}\x{0F93}\x{0F9D}\x{0FA2}\x{0FA7}\x{0FAC}\x{0FB9}\x{1F71}\x{1F73}\x{1F75}\x{1F77}\x{1F79}\x{1F7B}\x{1F7D}\x{1FBB}\x{1FBE}\x{1FC9}\x{1FCB}\x{1FD3}\x{1FDB}\x{1FE3}\x{1FEB}\x{1FEE}\x{1FEF}\x{1FF9}\x{1FFB}\x{1FFD}\x{2000}\x{2001}\x{2126}\x{212A}\x{212B}\x{2329}-\x{232A}\x{2ADC}\x{F900}-\x{FAFF}\x{FB1D}\x{FB1F}\x{FB2A}-\x{FB36}\x{FB38}-\x{FB3C}\x{FB3E}\x{FB40}\x{FB41}\x{FB43}\x{FB44}\x{FB46}-\x{FB4E}\x{1D15E}-\x{1D164}\x{1D1BB}-\x{1D1C0}\x{2F800}-\x{2FA1F}]"#

    private static let exclusionsRegex = try! NSRegularExpression(pattern: compositionExclusionsPattern)

    /// 合成除外文字を保護した NFC 正規化。
    /// 単純な NFC だと互換漢字などが統合漢字へ化けるため、合成除外文字を一時退避してから NFC を適用する。
    static func nfcSafe(_ input: String) -> String {
        if input.isEmpty { return input }
        // ASCII のみなら正規化不要（既に NFC かつ合成除外文字なし）
        if input.allSatisfy({ $0.isASCII }) { return input }

        // 1. 合成除外文字を「正規化されない一意な文字列(UUID)」へ退避
        let ns = input as NSString
        let matches = exclusionsRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))

        var protectedChars: [String] = []
        var placeholders: [String] = []
        var seen = Set<String>()
        for m in matches {
            let ch = ns.substring(with: m.range)
            if seen.insert(ch).inserted {
                protectedChars.append(ch)
                placeholders.append(UUID().uuidString)
            }
        }

        var work = input
        for (ch, ph) in zip(protectedChars, placeholders) {
            work = work.replacingOccurrences(of: ch, with: ph)
        }

        // 2. NFC を適用
        work = work.precomposedStringWithCanonicalMapping

        // 3. 退避した文字を逆順で復元
        for (ch, ph) in zip(protectedChars, placeholders).reversed() {
            work = work.replacingOccurrences(of: ph, with: ch)
        }
        return work
    }

    /// 改行を CR（InDesign の段落区切り）へ統一する。
    static func unifyToCR(_ input: String) -> String {
        // まず CRLF/CR を LF に寄せてから CR へ全置換
        let lf = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return lf.replacingOccurrences(of: "\n", with: "\r")
    }
}
