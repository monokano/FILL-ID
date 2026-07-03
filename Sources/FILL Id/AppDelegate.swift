import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// ⌘起動で表示モードがリセットされた場合に、起動後ダイアログを出すためのフラグ。
    static var shouldShowResetAlert: Bool = false

    private var statusItem: NSStatusItem?
    /// メニューバー用の共通メニュー。1 個を保持して使い回し、権限警告項目の表示/非表示だけを切り替える
    /// （アプリ切替のたびに再構築しない）。
    private var statusMenu: NSMenu?
    /// オートメーション権限警告のキャッシュ。実際のチェック（ブロックし得る IPC）は
    /// refreshAutomationPermission() がバックグラウンドで行い、メニューはこの値だけを参照する。
    private var automationWarningNeeded = false
    private var permissionRefreshInFlight = false
    private var settingsWindow: NSWindow?
    private var inddSettingsWindow: NSWindow?
    private var changeLogWindowController: ChangeLogWindowController?
    private var helpWindowController: HelpWindowController?
    private var appSwitchObserver: Any?

    private let indesign = InDesignController()
    private let hotKeys = HotKeyManager()
    private lazy var paste = PasteService(indesign: indesign)
    private var checker: CharacterCheckerWindowController?

    // MARK: - ライフサイクル

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherInstances()   // 二重起動を防ぐ（古い/残存インスタンスを終了）
        Preferences.registerDefaults()
        applyDisplayMode()
        refreshAutomationPermission()   // 権限状態の初回キャッシュ（バックグラウンドで確認）

        hotKeys.onAction = { [weak self] action in self?.perform(action) }
        paste.onShowChecker = { [weak self] text in self?.showChecker(text: text) }

        // 最前面アプリの監視（InDesign の出入りでホットキーを有効/無効化）
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.frontmostAppChanged()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(displayModeChanged),
                                               name: .displayModeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showSettings),
                                               name: .openSettingsRequested, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showInddDisplaySettings),
                                               name: .openInddDisplaySettingsRequested, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: .preferencesChanged, object: nil)

        frontmostAppChanged()

        if Self.shouldShowResetAlert {
            Self.shouldShowResetAlert = false
            DispatchQueue.main.async { [weak self] in self?.showResetAlert() }
        }
    }

    /// 同じ Bundle ID の他インスタンス（古い残存プロセス等）を終了し、常に単一起動にする。
    /// 残存インスタンスのメニューバーアイコンが消えない問題を防ぐ。
    private func terminateOtherInstances() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        let myPid = NSRunningApplication.current.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        where app.processIdentifier != myPid {
            app.forceTerminate()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 終了時にメニューバーアイコンが残らないよう、確実に後始末する。
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        hotKeys.deactivate()
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    // MARK: - 最前面監視 → ホットキー

    private func frontmostAppChanged() {
        if indesign.isFrontmost {
            hotKeys.activate()
        } else {
            hotKeys.deactivate()
        }
        updateAppearance()
    }

    private func perform(_ action: HotKeyAction) {
        // 直前の Apple Event が応答待ちの間は、新しいホットキーを無視する（多重送信ガード）。
        // ビジーな InDesign へ送り続けると、送信側がタイムアウトしてもイベントは InDesign 側の
        // キューに残り、後からまとめて実行される（多重ペースト等の事故）。それをここで断つ。
        guard !indesign.isBusy else {
            NSLog("[FILL Id] Hotkey ignored: previous InDesign command still awaiting reply")
            return
        }
        // 発火時点で最前面の InDesign インスタンスを捕捉し、以降の操作はこの pid を狙う。
        guard let target = indesign.captureFrontmostTarget() else { return }
        switch action {
        case .paste:           paste.run(target: target, trim: false)
        case .pasteTrim:       paste.run(target: target, trim: true)
        case .toggleGrids:     indesign.toggleGrids(preset: Preferences.gridPreset, target: target)
        case .fitPage:         indesign.zoomFitPage(target)
        case .fitSpread:       indesign.zoomFitSpread(target)
        case .zoomInDeselect:  indesign.zoomInSelectNothing(target)
        case .zoomOutDeselect: indesign.zoomOutSelectNothing(target)
        case .zoomInKeep:      indesign.zoomIn(target)
        case .zoomOutKeep:     indesign.zoomOut(target)
        }
    }

    @objc private func preferencesChanged() {
        if indesign.isFrontmost { hotKeys.activate() }
        updateAppearance()
    }

    @objc private func displayModeChanged() {
        applyDisplayMode()

        // 「メニューバーのみ」への切替は activationPolicy が .accessory になり、アプリごと
        // 非アクティブ化されて設定ウィンドウが背面に落ちる。ポリシー変更は非同期に反映されるため、
        // 直後に activate しても打ち消されることがある。少し遅らせて設定ウィンドウを前面へ戻す。
        if let window = settingsWindow, window.isVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard window.isVisible else { return }
                self?.bringToFront(window)
            }
        }
    }

    // MARK: - 表示モード（メニューバー / Dock / 両方）

    private func applyDisplayMode() {
        let mode = DisplayModeStore.load()
        switch mode {
        case .menuBar:     NSApp.setActivationPolicy(.accessory)
        case .dock, .both: NSApp.setActivationPolicy(.regular)
        }

        let needStatusItem = (mode == .menuBar || mode == .both)
        if needStatusItem {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.image = menuBarIcon()
                item.menu = ensureStatusMenu()
                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        updateAppearance()
    }

    /// 状態表示（ツールチップ）の更新。アプリ切替のたびに呼ばれるので、ここではメニュー再構築や
    /// 権限チェック（IPC）を行わない（フリーズ対策）。アイコンとメニューは statusItem 生成時に設定済み。
    private func updateAppearance() {
        guard let button = statusItem?.button else { return }
        button.toolTip = stateLabel()
    }

    /// メニューバー用アイコン。アプリアイコンをメニューバーサイズへ縮小して使う（カラー）。
    private func menuBarIcon() -> NSImage? {
        let size = NSSize(width: 19, height: 19)
        guard let source = NSApp.applicationIconImage ?? NSImage(named: "AppIcon") else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        image.isTemplate = false  // アプリアイコンの色を活かす
        return image
    }

    // MARK: - メニュー（メニューバー & Dock 共通）

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        // Dock メニューは「設定…」を上に置く。「終了」は OS が自動付加するのでカスタムでは付けない。
        // 表示はキャッシュ済みの権限状態を使い、次回の表示に向けてバックグラウンドで確認し直す。
        refreshAutomationPermission()
        return buildCommonMenu(settingsOnTop: true, includeQuit: false)
    }

    /// メニューバー & Dock 共通メニュー。
    /// - Parameters:
    ///   - settingsOnTop: `true` で「設定…」を「ドキュメント表示設定…」より上に並べる（Dock メニュー用）。
    ///     既定の `false` はメニューバー用の並び（ドキュメント表示設定… → 設定…）。
    ///   - includeQuit: `false` で「終了」項目を付けない（Dock メニューは OS が自動付加するため）。
    private func buildCommonMenu(settingsOnTop: Bool = false, includeQuit: Bool = true) -> NSMenu {
        let menu = NSMenu()

        // 権限警告の項目は常に持たせ、キャッシュ済みの権限状態で表示/非表示だけを切り替える。
        // ここでは権限チェック（IPC）を行わない（refreshAutomationPermission() がバックグラウンドで更新）。
        let warn = NSMenuItem(
            title: NSLocalizedString("⚠️ Automation permission required (InDesign)", comment: "Automation warning"),
            action: #selector(openAutomationPrefs), keyEquivalent: "")
        warn.target = self
        warn.tag = Self.automationWarningTag
        warn.isHidden = !automationWarningNeeded
        let warnSeparator = NSMenuItem.separator()
        warnSeparator.tag = Self.automationWarningSeparatorTag
        warnSeparator.isHidden = !automationWarningNeeded
        menu.addItem(warn)
        menu.addItem(warnSeparator)

        let inddSettings = NSMenuItem(
            title: NSLocalizedString("Document Display Settings...", comment: "document display settings menu item"),
            action: #selector(showInddDisplaySettings), keyEquivalent: "")
        inddSettings.target = self

        // メニューバー／Dock の共通メニューはショートカット表示なし（keyEquivalent は空）。
        let settings = NSMenuItem(
            title: NSLocalizedString("Settings...", comment: "Settings"),
            action: #selector(showSettings), keyEquivalent: "")
        settings.target = self

        let changeLog = NSMenuItem(
            title: NSLocalizedString("Change Log", comment: "Change log menu item"),
            action: #selector(openChangeLog), keyEquivalent: "")
        changeLog.target = self

        let help = NSMenuItem(
            title: NSLocalizedString("Help", comment: "Help menu item (common menu)"),
            action: #selector(openHelp), keyEquivalent: "")
        help.target = self

        // 設定群（設定／ドキュメント表示設定）は Dock とメニューバーで並びを反転させる。
        // 更新履歴とヘルプの組（更新履歴の下にヘルプ）は反転せず、両メニューで同じ並び。
        let settingsPair = settingsOnTop ? [settings, inddSettings] : [inddSettings, settings]
        let logGroup = [changeLog, help]
        let items: [NSMenuItem] = settingsOnTop
            ? logGroup + [.separator()] + settingsPair
            : settingsPair + [.separator()] + logGroup
        for item in items {
            menu.addItem(item)
        }

        if includeQuit {
            menu.addItem(.separator())

            let quit = NSMenuItem(
                title: NSLocalizedString("Quit", comment: "Quit"),
                action: #selector(quit), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
        }

        return menu
    }

    private func stateLabel() -> String {
        indesign.isFrontmost
            ? NSLocalizedString("InDesign is frontmost", comment: "State: ready")
            : NSLocalizedString("Waiting for InDesign", comment: "State: idle")
    }

    // MARK: - オートメーション権限（キャッシュ + バックグラウンド更新）

    private static let automationWarningTag = 901
    private static let automationWarningSeparatorTag = 902

    /// メニューバー用メニューを生成して保持する（初回のみ構築。以後は同じインスタンスを使い回す）。
    private func ensureStatusMenu() -> NSMenu {
        if let statusMenu { return statusMenu }
        let menu = buildCommonMenu()
        menu.delegate = self
        statusMenu = menu
        return menu
    }

    /// メニューを開くたびに権限状態をバックグラウンドで確認し直す（NSMenuDelegate）。
    /// 表示にはキャッシュ値を使うので、メニューを開く動作がブロックすることはない。
    func menuWillOpen(_ menu: NSMenu) {
        refreshAutomationPermission()
    }

    /// オートメーション権限のキャッシュを最新化する。
    /// `AEDeterminePermissionToAutomateTarget` はブロックし得る IPC のため、必ずバックグラウンドで呼び、
    /// 結果だけをメインスレッドでキャッシュへ反映する（旧実装はアプリ切替のたびにメインスレッドで
    /// 同期実行しており、InDesign がビジーのときにフリーズする起点だった）。
    private func refreshAutomationPermission() {
        guard !permissionRefreshInFlight else { return }
        permissionRefreshInFlight = true
        let bundleID = InDesignController.bundleID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = AutomationPermission.state(forBundleID: bundleID)
            let needsWarning: Bool
            switch state {
            case .denied, .notDetermined: needsWarning = true
            default: needsWarning = false
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permissionRefreshInFlight = false
                if self.automationWarningNeeded != needsWarning {
                    self.automationWarningNeeded = needsWarning
                    if let menu = self.statusMenu {
                        self.applyAutomationWarningVisibility(to: menu)
                    }
                }
            }
        }
    }

    /// 保持中のメニューの警告項目（本体＋セパレーター）の表示/非表示をキャッシュに合わせる。
    private func applyAutomationWarningVisibility(to menu: NSMenu) {
        let hidden = !automationWarningNeeded
        for item in menu.items
        where item.tag == Self.automationWarningTag || item.tag == Self.automationWarningSeparatorTag {
            item.isHidden = hidden
        }
    }

    // MARK: - アクション

    @objc private func openAutomationPrefs() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if isLoginItemEnabled() {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[FILL Id] Failed to change login item: %@", error.localizedDescription)
        }
    }

    private func isLoginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func showSettings() {
        openSettingsWindow()
    }

    private func openSettingsWindow() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = NSLocalizedString("Settings", comment: "Settings window title")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            restoreFrameOrCenter(window, name: "FILLIdSettingsWindow")
            settingsWindow = window
        }
        if let window = settingsWindow { bringToFront(window) }
    }

    /// ウィンドウ位置を記憶する。`name` でフレームを自動保存し、保存済みがあれば復元、なければ中央に置く。
    /// 設定・ドキュメント表示設定ウィンドウで使用（更新履歴・ヘルプは位置記憶しない）。
    /// 高さは SwiftUI コンテンツ（fixedSize）で決まるため、**表示前に**レイアウトを確定（`fittingSize` に
    /// 合わせる）してから左上で再配置する。これで表示時にリサイズ＝上端の移動が起きず、ちらつかない。
    private func restoreFrameOrCenter(_ window: NSWindow, name: String) {
        window.setFrameAutosaveName(name)          // 以後の移動を自動保存
        let restored = window.setFrameUsingName(name)
        // 復元できたら、保存フレームの左上（上端位置）を控えておく。
        let savedTopLeft = restored ? NSPoint(x: window.frame.minX, y: window.frame.maxY) : nil

        // 表示前にコンテンツ高さを確定させる（setFrameUsingName の保存サイズは自然サイズに戻す）。
        if let contentView = window.contentView {
            contentView.layoutSubtreeIfNeeded()
            window.setContentSize(contentView.fittingSize)
        }

        if let topLeft = savedTopLeft {
            window.setFrameTopLeftPoint(topLeft)   // 保存位置（左上）へ再配置
        } else {
            window.center()                        // 初回（保存なし）のみ中央
        }
    }

    /// ウィンドウを最前面に出し、FILL Id をアクティブにする。
    /// InDesign が最前面のときに設定等を開くと、InDesign のドキュメントウィンドウの背後に隠れてしまう。
    /// `NSApp.activate` だけでは隠れることがあるため、`orderFrontRegardless()` で確実に前面化する。
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc private func showInddDisplaySettings() {
        openInddDisplaySettingsWindow()
    }

    private func openInddDisplaySettingsWindow() {
        if inddSettingsWindow == nil {
            let hosting = NSHostingController(rootView: InddDisplaySettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = NSLocalizedString("Document Display Settings", comment: "document display settings window title")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            restoreFrameOrCenter(window, name: "FILLIdInddDisplaySettingsWindow")
            inddSettingsWindow = window
        }
        if let window = inddSettingsWindow { bringToFront(window) }
    }

    /// 更新履歴ウィンドウを開く（ヘルプメニュー／共通メニューから呼ばれる）。Glow Id の方式を流用。
    @objc func openChangeLog() {
        if changeLogWindowController == nil {
            changeLogWindowController = ChangeLogWindowController()
        }
        changeLogWindowController?.show()
    }

    /// ヘルプウィンドウを開く（ヘルプメニュー／共通メニューから呼ばれる）。Glow Id の方式を流用。
    @objc func openHelp() {
        if helpWindowController == nil {
            helpWindowController = HelpWindowController()
        }
        helpWindowController?.show()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showChecker(text: String) {
        if checker == nil { checker = CharacterCheckerWindowController() }
        checker?.show(text: text)
    }

    private func showResetAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Display settings reset", comment: "Reset alert title")
        alert.informativeText = NSLocalizedString("Display mode has been reset to \"Menu Bar and Dock\".", comment: "Reset alert body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK"))
        alert.runModal()
    }
}
