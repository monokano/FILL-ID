import SwiftUI

/// indd表示設定ウィンドウ。グリッド・ガイドの表示切替プリセットを管理する。
/// 頻繁にアクセスするため、設定ウィンドウから分離してメニューバー／Dock メニューから直接開く。
struct InddDisplaySettingsView: View {
    // 表示切替の有効/無効（旧キー Mode:Show）
    @AppStorage(PrefKey.showHide) private var showHide = true
    @AppStorage(PrefKey.showHideFkeyIndex) private var fkeyIndex = 12

    // グリッドプリセット
    @AppStorage(PrefKey.showGuides)         private var showGuides = true
    @AppStorage(PrefKey.showFrameEdges)     private var showFrameEdges = true
    @AppStorage(PrefKey.showCharacterCount) private var showCharacterCount = false
    @AppStorage(PrefKey.showInvisibles)     private var showInvisibles = false
    @AppStorage(PrefKey.showFrameGrids)     private var showFrameGrids = true
    @AppStorage(PrefKey.showLayoutGrids)    private var showLayoutGrids = true
    @AppStorage(PrefKey.showBaselineGrid)   private var showBaselineGrid = false
    @AppStorage(PrefKey.showDocumentGrid)   private var showDocumentGrid = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable display toggle", isOn: $showHide)
                    .padding(.leading, 6)   // グループ内の左マージンを少し広げる

                Picker("Toggle key", selection: $fkeyIndex) {
                    ForEach(0..<19, id: \.self) { i in
                        Text("F\(i + 1)").tag(i)
                    }
                }
                .padding(.leading, 6)
                .disabled(!showHide)
            }

            Section("Settings") {
                Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 8) {
                    GridRow {
                        Toggle("Guides", isOn: $showGuides).gridColumnAlignment(.leading)
                        Toggle("Frame grids", isOn: $showFrameGrids).gridColumnAlignment(.leading)
                    }
                    GridRow {
                        Toggle("Frame edges", isOn: $showFrameEdges)
                        Toggle("Layout grids", isOn: $showLayoutGrids)
                    }
                    GridRow {
                        Toggle("Character count", isOn: $showCharacterCount)
                        Toggle("Baseline grid", isOn: $showBaselineGrid)
                    }
                    GridRow {
                        Toggle("Invisibles", isOn: $showInvisibles)
                        Toggle("Document grid", isOn: $showDocumentGrid)
                    }
                }
                .padding(.leading, 6)   // グループ内の左マージンを少し広げる
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!showHide)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.checkbox)
        .frame(width: 370)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: showHide)  { _ in postPrefsChanged() }
        .onChange(of: fkeyIndex) { _ in postPrefsChanged() }
    }

    private func postPrefsChanged() {
        NotificationCenter.default.post(name: .preferencesChanged, object: nil)
    }
}
