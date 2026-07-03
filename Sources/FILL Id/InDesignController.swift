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
///
/// 送信は専用のシリアルキューで行い、**メインスレッドをブロックしない**（フリーズ対策）。
/// InDesign がビジーで応答しなくても、固まるのはバックグラウンドのキューだけで、
/// UI・メニュー・最前面監視は生きたまま。結果が要る操作は completion（メインスレッド）で受け取る。
@MainActor
final class InDesignController {

    static let bundleID = "com.adobe.InDesign"

    /// Apple Event 送信用のシリアルキュー。送信順を保証するため 1 本に直列化する。
    private let sendQueue = DispatchQueue(label: "com.tama-san.FILLId.indesign-ae", qos: .userInitiated)

    /// 応答待ち中の Apple Event の数（メインスレッドで読み書き）。
    private var inFlightCount = 0

    /// InDesign への送信が応答待ち中か。ホットキーの多重発火ガード（AppDelegate.perform）が参照する。
    /// ビジー中の連打を無視しないと、送信側がタイムアウトしてもイベントは InDesign 側のキューに残り、
    /// 後からまとめて実行される（多重ペースト等）。
    var isBusy: Bool { inFlightCount > 0 }

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

    /// 現在の選択がテキスト挿入可能か（旧 IsSetCursor 相当）。結果はメインスレッドで返す。
    /// 通常のペーストでは使わない（`setText` がスクリプト内で同じ確認を行う）。
    /// 不正文字の警告を出す前の事前確認にのみ使う。
    func isSetCursor(_ target: InDesignTarget, completion: @escaping @MainActor (Bool) -> Void) {
        let js = """
        var ok=false;
        if(app.documents.length>0 && app.selection.length>0){
        var k=app.selection[0].constructor.name;
        ok=(k=="Text"||k=="InsertionPoint"||k=="Character"||k=="Word"||k=="Line"||k=="Paragraph"||k=="TextStyleRange"||k=="TextColumn");
        }
        ok;
        """
        runJavaScript(js, target: target) { reply in
            completion(reply?.booleanValue ?? false)
        }
    }

    /// 選択範囲の contents を直接置換する（⌘V は送らない）。undo mode=fast entire script で 1 回の Undo にまとめる。
    /// カーソル確認（旧 isSetCursor）と置換を 1 本のスクリプトに統合し、InDesign との往復を 1 回にしている。
    /// テキスト系の選択でなければ何もせず、completion に false を返す。
    /// 空（""）にはせず**先頭1文字を残してから**置換することで、選択範囲（先頭文字）の書式を保持する。
    /// （`contents=""` で空にすると書式の拠り所が消え、挿入位置の書式を拾って選択範囲の書式が落ちることがある。）
    /// 末尾でキャレットを立てる: 置換“前”に末尾の挿入ポイントを `select()` しておく。
    /// InsertionPoint はテキストに張り付いた生きた参照で、前方の挿入・削除に合わせて自動追従するため、
    /// 置換後はそのまま挿入テキスト直後にキャレットが残る。文字数を数えないのでサロゲートペアの影響を受けない。
    /// タイムアウトは巨大テキスト（60万字級）の置換に時間がかかり得るため 30 秒とする（他の操作は既定の 5 秒）。
    func setText(_ text: String, target: InDesignTarget, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !text.isEmpty else { completion?(false); return }
        let js = """
        var r="";
        if(app.documents.length>0 && app.selection.length>0){
        var s=app.selection[0];
        var k=s.constructor.name;
        if(k=="Text"||k=="InsertionPoint"||k=="Character"||k=="Word"||k=="Line"||k=="Paragraph"||k=="TextStyleRange"||k=="TextColumn"){
        var t=\(Self.jsString(text));
        s.insertionPoints[-1].select();
        if(s.contents.length>0){s.contents=s.contents.substring(0,1);}
        s.contents=t;
        r="ok";
        }
        }
        r;
        """
        runJavaScript(js, target: target, undo: true, timeout: 30) { reply in
            completion?(reply?.stringValue == "ok")
        }
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

    // MARK: - pid 指定の do script 送信（バックグラウンド・シリアルキュー）

    /// `do script` をシリアルキューから送信する。completion はメインスレッドで呼ばれる
    /// （引数は reply の ---- パラメータ。送信失敗・タイムアウト時は nil）。
    /// タイムアウトの既定は 5 秒。ビジーな InDesign を長く待たず、多重発火ガード（isBusy）を早めに解く。
    private func runJavaScript(_ js: String, target: InDesignTarget, undo: Bool = false,
                               timeout: TimeInterval = 5,
                               completion: (@MainActor (NSAppleEventDescriptor?) -> Void)? = nil) {
        inFlightCount += 1
        sendQueue.async {
            let result = Self.sendDoScript(js, to: target, undo: undo, timeout: timeout)
            Task { @MainActor in
                self.inFlightCount -= 1
                completion?(result)
            }
        }
    }

    /// Apple Event を組み立てて同期送信する。ブロックしてよいバックグラウンドスレッド（sendQueue）から呼ぶ。
    private nonisolated static func sendDoScript(_ js: String, to target: InDesignTarget,
                                                 undo: Bool, timeout: TimeInterval) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: osType("K2  "),   // InDesign スイート
            eventID: osType("dosc"),          // do script
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: target.pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))

        // 直接オブジェクト = スクリプト本体
        event.setParam(NSAppleEventDescriptor(string: js), forKeyword: osType("----"))
        // language = javascript
        event.setParam(NSAppleEventDescriptor(enumCode: osType("JSLg")), forKeyword: osType("doLg"))
        // undo mode = fast entire script
        if undo {
            event.setParam(NSAppleEventDescriptor(enumCode: osType("eSfU")), forKeyword: osType("pSUM"))
        }

        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: timeout)
            if let err = reply.paramDescriptor(forKeyword: osType("errs"))?.stringValue, !err.isEmpty {
                NSLog("[FILL Id] InDesign script error (%@): %@", target.name, err)
            }
            return reply.paramDescriptor(forKeyword: osType("----"))
        } catch {
            NSLog("[FILL Id] do script send failed (%@): %@", target.name, error.localizedDescription)
            return nil
        }
    }

    /// 4文字コード→OSType（4文字未満は空白でパディング。例: "K2  "）。
    private nonisolated static func osType(_ s: String) -> OSType {
        var bytes = Array(s.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        return bytes.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }

    /// 文字列を JavaScript の文字列リテラル（前後のダブルクォート含む）へ。
    /// CR はそのまま `\r`（InDesign の段落区切り）として埋め込む。
    private nonisolated static func jsString(_ s: String) -> String {
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
