import AppKit
import Carbon

/// 操作対象の InDesign インスタンス。**pid で特定**する（複数バージョン同時起動対応の要）。
/// 全バージョンが同一 Bundle ID `com.adobe.InDesign` のため、パスや名前では特定できず、
/// `tell application` 系はバンドルID解決で1インスタンスに収束してしまう。pid 指定の Apple Event なら確実。
struct InDesignTarget {
    let pid: pid_t
    let name: String   // 診断ログ用（例: "Adobe InDesign 2026"）
}

/// InDesign 連携。`do script`（JavaScript）を **pid 指定の Apple Event** で送る（HANDOFF.md §8.1）。
@MainActor
final class InDesignController {

    static let bundleID = "com.adobe.InDesign"

    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID
    }

    /// 発火時点で最前面の InDesign インスタンスを捕捉する。
    /// ホットキーは InDesign 最前面時のみ発火するので、これが「作業中の特定バージョン」。
    func captureFrontmostTarget() -> InDesignTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == Self.bundleID else { return nil }
        // localizedName は全バージョン "InDesign" になるため、診断用の名前は .app 名から採る（例: "Adobe InDesign 2026"）。
        let name = app.bundleURL?.deletingPathExtension().lastPathComponent ?? app.localizedName ?? "InDesign"
        return InDesignTarget(pid: app.processIdentifier, name: name)
    }

    /// 対象 InDesign を最前面へ（アラート操作後などに使う）。
    func activate(_ target: InDesignTarget) {
        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
    }

    // MARK: - 公開操作

    /// 現在の選択がテキスト挿入可能か（旧 IsSetCursor 相当）。
    func isSetCursor(_ target: InDesignTarget) -> Bool {
        let js = """
        var ok=false;
        if(app.documents.length>0 && app.selection.length>0){
        var k=app.selection[0].constructor.name;
        ok=(k=="Text"||k=="InsertionPoint"||k=="Character"||k=="Word"||k=="Line"||k=="Paragraph"||k=="TextStyleRange"||k=="TextColumn");
        }
        ok;
        """
        return runJavaScript(js, target: target, wantsResult: true)?.booleanValue ?? false
    }

    /// 選択範囲の contents を直接置換する（⌘V は送らない）。undo mode=fast entire script で 1 回の Undo にまとめる。
    /// 空（""）にはせず**先頭1文字を残してから**置換することで、選択範囲（先頭文字）の書式を保持する。
    /// （`contents=""` で空にすると書式の拠り所が消え、挿入位置の書式を拾って選択範囲の書式が落ちることがある。）
    /// 仕上げに `parentStory.recompose()` で再組版を明示的に走らせる。
    /// 末尾でキャレットを立てる: 置換“前”に末尾の挿入ポイントを `select()` しておく。
    /// InsertionPoint はテキストに張り付いた生きた参照で、前方の挿入・削除に合わせて自動追従するため、
    /// 置換後はそのまま挿入テキスト直後にキャレットが残る。文字数を数えないのでサロゲートペアの影響を受けず、
    /// 60万字規模でも追加コストが無い（`id_モジ入力するだけ.jsx` の `pepsi()` と同方式）。
    func setText(_ text: String, target: InDesignTarget) {
        guard !text.isEmpty else { return }
        let js = """
        var t=\(Self.jsString(text));
        if(app.selection.length>0){
        var s=app.selection[0];
        s.insertionPoints[-1].select();
        if(s.contents.length>0){s.contents=s.contents.substring(0,1);}
        s.contents=t;
        try{s.parentStory.recompose();}catch(e){}
        }
        """
        runJavaScript(js, target: target, undo: true)
    }

    func zoomFitPage(_ t: InDesignTarget)   { runJavaScript("try{app.menuActions.itemByID(118788).invoke();}catch(e){}", target: t) }
    func zoomFitSpread(_ t: InDesignTarget) { runJavaScript("try{app.menuActions.itemByID(118787).invoke();}catch(e){}", target: t) }
    func zoomIn(_ t: InDesignTarget)  { runJavaScript("try{app.menuActions.itemByID(118785).invoke();}catch(e){}", target: t) }
    func zoomOut(_ t: InDesignTarget) { runJavaScript("try{app.menuActions.itemByID(118786).invoke();}catch(e){}", target: t) }

    func zoomInSelectNothing(_ t: InDesignTarget) {
        runJavaScript("try{try{app.menuActions.itemByID(278).invoke();}catch(e){}app.menuActions.itemByID(118785).invoke();}catch(e){}", target: t)
    }
    func zoomOutSelectNothing(_ t: InDesignTarget) {
        runJavaScript("try{try{app.menuActions.itemByID(278).invoke();}catch(e){}app.menuActions.itemByID(118786).invoke();}catch(e){}", target: t)
    }

    /// グリッド/ガイドの表示トグル（旧 SetGrids）。
    func toggleGrids(preset: [Bool], target: InDesignTarget) {
        let arr = "arr = new Array(" + preset.map { $0 ? "true" : "false" }.joined(separator: ",") + ");"
        let js = "if(app.documents.length>0){\n" + arr + "\n" + Self.gridJSBody + "\n}"
        runJavaScript(js, target: target)
    }

    // MARK: - pid 指定の do script 送信

    @discardableResult
    private func runJavaScript(_ js: String, target: InDesignTarget, undo: Bool = false, wantsResult: Bool = false) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: Self.osType("K2  "),   // InDesign スイート
            eventID: Self.osType("dosc"),          // do script
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: target.pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))

        // 直接オブジェクト = スクリプト本体
        event.setParam(NSAppleEventDescriptor(string: js), forKeyword: Self.osType("----"))
        // language = javascript
        event.setParam(NSAppleEventDescriptor(enumCode: Self.osType("JSLg")), forKeyword: Self.osType("doLg"))
        // undo mode = fast entire script
        if undo {
            event.setParam(NSAppleEventDescriptor(enumCode: Self.osType("eSfU")), forKeyword: Self.osType("pSUM"))
        }

        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 30)
            if let err = reply.paramDescriptor(forKeyword: Self.osType("errs"))?.stringValue, !err.isEmpty {
                NSLog("[FILL Id] InDesign script error (%@): %@", target.name, err)
            }
            return reply.paramDescriptor(forKeyword: Self.osType("----"))
        } catch {
            NSLog("[FILL Id] do script send failed (%@): %@", target.name, error.localizedDescription)
            return nil
        }
    }

    /// 4文字コード→OSType（4文字未満は空白でパディング。例: "K2  "）。
    private static func osType(_ s: String) -> OSType {
        var bytes = Array(s.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        return bytes.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }

    /// 文字列を JavaScript の文字列リテラル（前後のダブルクォート含む）へ。
    /// CR はそのまま `\r`（InDesign の段落区切り）として埋め込む。
    private static func jsString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\r": out += "\\r"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
        return out
    }

    /// グリッド表示トグルの JavaScript 本体（旧 `SetGrids.myJavaScript`）。
    /// `arr[0..7]`: 0=レイアウトグリッド 1=フレームグリッド 2=文字数 3=フレーム枠 4=ガイド 5=ドキュメントグリッド 6=ベースライン 7=制御文字
    private static let gridJSBody = #"""
    b=false;
    myDoc=app.activeDocument;

    var appVer = parseInt(app.version, 10);

    //2023-2024のバグ対策
    if (appVer>=18 &&appVer<=19 ) {
    	app.toolBoxTools.currentTool = UITools.SELECTION_TOOL;
    }

    //いずれかが表示されているか
    b=myDoc.cjkGridPreferences.showAllLayoutGrids;
    if (b==false){b=myDoc.cjkGridPreferences.showAllFrameGrids;}
    if (b==false){b=myDoc.cjkGridPreferences.showCharacterCount;}
    if (b==false){b=myDoc.viewPreferences.showFrameEdges;}
    if (b==false){b=myDoc.guidePreferences.guidesShown;}
    if (b==false){b=myDoc.gridPreferences.documentGridShown;}
    if (b==false){b=myDoc.gridPreferences.baselineGridShown;}
    if (b==false){b=myDoc.textPreferences.showInvisibles;}

    if (b==true){
    if (myDoc.cjkGridPreferences.showAllLayoutGrids){app.menuActions.itemByID(49922).invoke();}
    if (myDoc.cjkGridPreferences.showAllFrameGrids){app.menuActions.itemByID(50179).invoke();}
    if (myDoc.cjkGridPreferences.showCharacterCount){app.menuActions.itemByID(50178).invoke();}
    if (myDoc.viewPreferences.showFrameEdges){app.menuActions.itemByID(24331).invoke();}
    if (myDoc.guidePreferences.guidesShown){app.menuActions.itemByID(24325).invoke();}
    if (myDoc.gridPreferences.documentGridShown){app.menuActions.itemByID(24329).invoke();}
    if (myDoc.gridPreferences.baselineGridShown){app.menuActions.itemByID(24327).invoke();}
    if (myDoc.textPreferences.showInvisibles){app.menuActions.itemByID(119553).invoke();}
    }else{
    if (arr[0] != myDoc.cjkGridPreferences.showAllLayoutGrids){app.menuActions.itemByID(49922).invoke();}
    if (arr[1] != myDoc.cjkGridPreferences.showAllFrameGrids){app.menuActions.itemByID(50179).invoke();}
    if (arr[2] != myDoc.cjkGridPreferences.showCharacterCount){app.menuActions.itemByID(50178).invoke();}
    if (arr[3] != myDoc.viewPreferences.showFrameEdges){app.menuActions.itemByID(24331).invoke();}
    if (arr[4] != myDoc.guidePreferences.guidesShown){app.menuActions.itemByID(24325).invoke();}
    if (arr[5] != myDoc.gridPreferences.documentGridShown){app.menuActions.itemByID(24329).invoke();}
    if (arr[6] != myDoc.gridPreferences.baselineGridShown){app.menuActions.itemByID(24327).invoke();}
    if (arr[7] != myDoc.textPreferences.showInvisibles){app.menuActions.itemByID(119553).invoke();}
    }
    """#
}
