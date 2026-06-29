import SwiftUI
import ServiceManagement

/// 設定ウィンドウ。1枚のウィンドウに「一般」と「機能」を縦に並べ、区切り線で分ける。
/// グルーピング（GroupBox / Form セクション枠）は使わず、フラットに並べる。
struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeneralSettingsView()
            Divider()
                .padding(.horizontal, 20)   // 一般／機能の区切り線。左右インセット 20
            FeaturesSettingsView()
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 一般

/// 動作トグルと表示モード。グループ枠なしのフラットレイアウト。
struct GeneralSettingsView: View {
    @AppStorage(DisplayModeStore.key) private var rawMode: String = DisplayModeStore.defaultValue.rawValue
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    private var displayMode: Binding<DisplayMode> {
        Binding(
            get: { DisplayMode(rawValue: rawMode) ?? DisplayModeStore.defaultValue },
            set: { newValue in
                rawMode = newValue.rawValue
                NotificationCenter.default.post(name: .displayModeChanged, object: nil)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 動作
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at Login", isOn: $launchAtLogin)
            }
            .toggleStyle(.checkbox)

            // 区切り線（外側の 30 マージンから -10 はみ出させ、もう一方の区切り線と同じ左右インセット 20 に揃える）
            Divider()
                .padding(.horizontal, -10)

            // 表示モード（ラジオはボタンがラベルの左／行間は詰める）
            VStack(alignment: .leading, spacing: 6) {
                Text("Display Mode")
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(DisplayMode.allCases) { mode in
                        RadioRow(title: mode.label,
                                 isSelected: displayMode.wrappedValue == mode) {
                            displayMode.wrappedValue = mode
                        }
                    }
                }

                Text("Hold ⌘ while launching to reset display mode to the initial state (Menu Bar and Dock).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 30)   // 左右はゆったり
        .padding(.top, 22)          // ウィンドウ上マージン
        .padding(.bottom, 16)       // 区切り線までの間隔
        .frame(width: 320, alignment: .leading)
        .onChange(of: launchAtLogin) { newValue in setLaunchAtLogin(newValue) }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[FILL Id] Failed to change login item: %@", error.localizedDescription)
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

/// ラジオ1行。ボタン（円）をラベルの左に置く。
private struct RadioRow: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 機能

/// ホットキー機能の個別 ON/OFF。グループ枠なしでチェックボックスを直接並べる。
struct FeaturesSettingsView: View {
    @AppStorage(PrefKey.textPaste) private var textPaste = true
    @AppStorage(PrefKey.viewFit)   private var viewFit = true
    @AppStorage(PrefKey.zoom)      private var zoom = true
    @AppStorage(PrefKey.pasteFlash) private var pasteFlash = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // クリーンペーストと、その従属設定（ペースト時に画面を一瞬暗くする）
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Clean paste (⌥V / ⇧⌥V)", isOn: $textPaste)

                // クリーンペーストより右にインデント＋小さめ＋OFF時グレーアウト
                Toggle("Briefly dim the screen on paste", isOn: $pasteFlash)
                    .controlSize(.small)
                    .padding(.leading, 20)
                    .disabled(!textPaste)
            }

            Toggle("Fit page / spread (⌘0 / ⌥⌘0)", isOn: $viewFit)
            Toggle("Zoom in / out (⌘± / ⇧⌘±)", isOn: $zoom)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 30)   // 左右はゆったり
        .padding(.top, 16)          // 区切り線からの間隔
        .padding(.bottom, 22)       // ウィンドウ下マージン
        .frame(width: 320, alignment: .leading)
        .onChange(of: textPaste) { _ in postPrefsChanged() }
        .onChange(of: viewFit)   { _ in postPrefsChanged() }
        .onChange(of: zoom)      { _ in postPrefsChanged() }
    }

    private func postPrefsChanged() {
        NotificationCenter.default.post(name: .preferencesChanged, object: nil)
    }
}
