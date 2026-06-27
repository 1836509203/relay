import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store = SessionStore.shared
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var selected: SettingsSection = .general
    @State private var query = ""
    @State private var searchHovered = false
    @FocusState private var searchFocused: Bool

    let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general, terminal, appearance, shortcuts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "通用"
            case .terminal: return "终端"
            case .appearance: return "外观"
            case .shortcuts: return "快捷键"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .terminal: return "terminal"
            case .appearance: return "slider.horizontal.3"
            case .shortcuts: return "keyboard"
            }
        }

        var detail: String {
            switch self {
            case .general: return "更新、版本和基础行为"
            case .terminal: return "字体、回看和渲染"
            case .appearance: return "主题、字体和终端显示"
            case .shortcuts: return "常用命令"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.chromeLine).frame(width: 1)
            detailPane
        }
        .frame(minWidth: 720, minHeight: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.workspace)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: embedded ? 42 : 18)

            if let onClose {
                Button(action: onClose) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 16)
                        Text("返回应用")
                            .font(Theme.uiFont(size: 13, weight: .medium))
                    }
                    .foregroundColor(Theme.sidebarPrimary.opacity(0.76))
                    .frame(height: 30)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)

                settingsSearchField
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
            } else {
                Text("设置")
                    .font(Theme.uiFont(size: 18, weight: .semibold))
                    .foregroundColor(Theme.fg0)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }

            sidebarSections

            Spacer()
        }
        .frame(width: embedded ? 300 : 188)
        .background {
            SidebarPanelBackground(
                isActive: windowActive,
                translucent: embedded && store.settings.translucentSidebar
            )
            .ignoresSafeArea()
        }
    }

    private var embedded: Bool { onClose != nil }

    private var windowActive: Bool {
        controlActiveState != .inactive
    }

    private var filteredSections: [SettingsSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter {
            "\($0.title) \($0.detail)".lowercased().contains(q)
        }
    }

    private var settingsSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
            TextField("搜索设置...", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.uiFont(size: 12, weight: .medium))
                .foregroundColor(Theme.sidebarPrimary)
                .focused($searchFocused)
            Spacer(minLength: 6)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.sidebarSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundColor(Theme.sidebarSecondary)
        .frame(height: 28)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.sidebarControl.opacity(searchFocused || searchHovered ? 1.0 : 0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Theme.sidebarSelectionInactiveStroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
        .onHover { searchHovered = $0 }
    }

    @ViewBuilder private var sidebarSections: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settingsGroup("个人", [.general, .appearance])
            settingsGroup("终端", [.terminal, .shortcuts])
        } else {
            VStack(spacing: 3) {
                ForEach(filteredSections) { section in
                    sidebarRow(section)
                }
            }
            .padding(.horizontal, embedded ? 8 : 10)
        }
    }

    private func settingsGroup(_ title: String, _ sections: [SettingsSection]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if embedded {
                Text(title)
                    .font(Theme.uiFont(size: 12, weight: .semibold))
                    .foregroundColor(Theme.sidebarSecondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
            }
            ForEach(sections) { section in
                sidebarRow(section)
            }
        }
        .padding(.horizontal, embedded ? 8 : 10)
        .padding(.bottom, embedded ? 14 : 4)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        SettingsSidebarRow(section: section, selected: $selected, compact: embedded)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                switch selected {
                case .general:
                    generalSettings
                case .terminal:
                    terminalSettings
                case .appearance:
                    appearanceSettings
                case .shortcuts:
                    shortcutSettings
                }
            }
            .padding(.top, embedded ? 62 : 24)
            .padding(.bottom, 34)
            .padding(.horizontal, embedded ? 42 : 24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.workspace)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selected.title)
                .font(Theme.uiFont(size: CGFloat(store.settings.uiFontSize + (embedded ? 7 : 8)), weight: .semibold))
                .foregroundColor(Theme.fg0)
            Text(selected.detail)
                .font(Theme.uiFont(size: CGFloat(max(11, store.settings.uiFontSize - 2))))
                .foregroundColor(Theme.fg2)
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSectionBlock(
                title: "应用",
                detail: "控制更新检查和 Relay 的基础行为。"
            ) {
                SettingsCard {
                    SettingsRow(
                        title: "自动检查更新",
                        detail: "启动后静默检查，发现新版本时用系统通知提醒。"
                    ) {
                        Toggle("", isOn: bind(\.autoUpdateCheck))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "立即检查更新",
                        detail: "当前版本 \(Updater.currentVersion)。"
                    ) {
                        Button("检查更新") { Updater.check(interactive: true) }
                            .controlSize(.small)
                    }
                }
            }

            SettingsSectionBlock(
                title: "窗口",
                detail: "侧栏、标签栏和主工作区使用统一的 Codex 风格外壳。"
            ) {
                SettingsCard {
                    SettingsRow(
                        title: "侧栏宽度",
                        detail: "\(Int(store.settings.sidebarWidth)) pt，可在主界面拖拽右缘调整。"
                    ) {
                        Slider(value: sidebarWidthBinding, in: 180...360, step: 1)
                            .frame(width: 220)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "默认显示侧栏",
                        detail: "关闭后，新窗口仍可从左上角按钮重新展开。"
                    ) {
                        Toggle("", isOn: bind(\.sidebarVisible))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSectionBlock(
                title: "文字",
                detail: "字体、字号和字格密度会应用到所有已打开终端。"
            ) {
                SettingsCard {
                    SettingsRow(title: "字体", detail: "用于所有终端会话。") {
                        CodexFontMenuControl(selection: fontBinding, fonts: TerminalTheme.availableFonts())
                    }
                    SettingsDivider()
                    SettingsRow(title: "字号", detail: "\(Int(store.settings.fontSize)) pt") {
                        Slider(value: sizeBinding, in: 9...24, step: 1)
                            .frame(width: 220)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "行高微调",
                        detail: "+\(String(format: "%.1f", store.settings.lineSpacing)) pt"
                    ) {
                        Slider(value: lineSpacingBinding, in: 0...4, step: 0.5)
                            .frame(width: 220)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "字距微调",
                        detail: "\(String(format: "%.2f", store.settings.letterSpacing)) pt"
                    ) {
                        Slider(value: letterSpacingBinding, in: -1.0...1.0, step: 0.25)
                            .frame(width: 220)
                    }
                }
            }

            SettingsSectionBlock(
                title: "性能",
                detail: "控制回看缓冲和终端渲染路径。"
            ) {
                SettingsCard {
                    SettingsRow(title: "回看行数", detail: "对新建会话生效，行数越大内存越高。") {
                        Picker("", selection: scrollbackBinding) {
                            ForEach([500, 1000, 2000, 5000, 10000], id: \.self) { n in
                                Text("\(n)").tag(n)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 118)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "GPU 渲染",
                        detail: "Metal 渲染适合高频输出；会增加约 150MB 内存占用。"
                    ) {
                        Toggle("", isOn: gpuBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private var appearanceSettings: some View {
        let baseTheme = TerminalTheme.by(id: store.effectiveThemeId)
        let effectiveTheme = store.effectiveTheme

        return VStack(alignment: .leading, spacing: 24) {
            AppearanceModeSelector(selected: appearanceMode) { mode in
                setAppearanceMode(mode)
            }

            ThemeCodePreview(theme: effectiveTheme)

            SettingsCard {
                themePickerRow(title: "浅色主题", themes: lightThemes, selection: themeLightBinding)
                SettingsDivider()
                themePickerRow(title: "深色主题", themes: darkThemes, selection: themeBinding)
                SettingsDivider()
                SettingsRow(title: "强调色", detail: "终端光标和高亮色。") {
                    EditableColorValueField(
                        hex: colorOverrideBinding(\.customAccentHex, fallback: baseTheme.caret),
                        defaultHex: baseTheme.caret,
                        isOverridden: store.settings.customAccentHex != nil,
                        reset: { resetColorOverride(\.customAccentHex) }
                    )
                }
                SettingsDivider()
                SettingsRow(title: "背景", detail: "终端主背景色。") {
                    EditableColorValueField(
                        hex: colorOverrideBinding(\.customBackgroundHex, fallback: baseTheme.bg),
                        defaultHex: baseTheme.bg,
                        isOverridden: store.settings.customBackgroundHex != nil,
                        reset: { resetColorOverride(\.customBackgroundHex) }
                    )
                }
                SettingsDivider()
                SettingsRow(title: "前景", detail: "终端默认文字色。") {
                    EditableColorValueField(
                        hex: colorOverrideBinding(\.customForegroundHex, fallback: baseTheme.fg),
                        defaultHex: baseTheme.fg,
                        isOverridden: store.settings.customForegroundHex != nil,
                        reset: { resetColorOverride(\.customForegroundHex) }
                    )
                }
                SettingsDivider()
                SettingsRow(title: "UI 字体", detail: "Relay 界面使用的字体。") {
                    CodexFontMenuControl(selection: uiFontNameBinding, fonts: TerminalTheme.availableUIFonts())
                }
                SettingsDivider()
                SettingsRow(title: "代码字体", detail: "终端等宽字体。") {
                    CodexFontMenuControl(selection: fontBinding, fonts: TerminalTheme.availableFonts())
                }
                SettingsDivider()
                SettingsRow(title: "半透明侧边栏", detail: "选中项显示毛玻璃层次，侧栏底色跟随 Codex 风格。") {
                    Toggle("", isOn: translucentSidebarBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "任务分组", detail: "侧栏按工具类型或项目目录聚合。") {
                    Picker("", selection: taskGroupingBinding) {
                        ForEach(SidebarTaskGrouping.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                SettingsDivider()
                SettingsRow(title: "对比度", detail: "调节侧栏与主工作区的视觉分离强度。") {
                    HStack(spacing: 10) {
                        Slider(value: uiContrastBinding, in: 30...80, step: 1)
                            .frame(width: 176)
                        ValueBadge("\(Int(store.settings.uiContrast))")
                    }
                }
            }

            SettingsCard {
                SettingsRow(
                    title: "减少动态效果",
                    detail: "减少动画效果或匹配系统设置。"
                ) {
                    Picker("", selection: motionPreferenceBinding) {
                        Text("系统").tag("system")
                        Text("开启").tag("on")
                        Text("关闭").tag("off")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 176)
                }
                SettingsDivider()
                SettingsRow(title: "UI 字号", detail: "调整 Relay 界面使用的基准字号。") {
                    HStack(spacing: 10) {
                        Slider(value: uiFontSizeBinding, in: 12...18, step: 1)
                            .frame(width: 176)
                        ValueBadge("\(Int(store.settings.uiFontSize))")
                    }
                }
                SettingsDivider()
                SettingsRow(title: "代码字体大小", detail: "调整终端内容使用的基础字号。") {
                    HStack(spacing: 10) {
                        Slider(value: sizeBinding, in: 9...24, step: 1)
                            .frame(width: 176)
                        ValueBadge("\(Int(store.settings.fontSize))")
                    }
                }
            }

            SettingsCard {
                SettingsRow(
                    title: "高刷渲染",
                    detail: "Metal 渲染跟随 ProMotion/高刷新屏幕；关闭后使用 CoreGraphics。"
                ) {
                    Toggle("", isOn: gpuBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "显示行数", detail: "终端保留的历史输出行数，对新建会话生效。") {
                    Picker("", selection: scrollbackBinding) {
                        ForEach([500, 1000, 2000, 5000, 10000], id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                }
                SettingsDivider()
                SettingsRow(title: "窗口透明度", detail: "\(Int(store.settings.bgOpacity * 100))%") {
                    Slider(value: opacityBinding, in: 0.7...1.0, step: 0.01)
                        .frame(width: 220)
                }
                SettingsDivider()
                SettingsRow(
                    title: "毛玻璃模糊",
                    detail: store.settings.bgOpacity >= 0.999
                        ? "需要透明度低于 100% 才可见。"
                        : "\(store.settings.bgBlur)"
                ) {
                    Slider(value: blurBinding, in: 0...40, step: 1)
                        .frame(width: 220)
                        .disabled(store.settings.bgOpacity >= 0.999)
                }
                SettingsDivider()
                SettingsRow(title: "终端内边距", detail: "\(Int(store.settings.padding)) pt") {
                    Slider(value: paddingBinding, in: AppSettings.minimumPadding...24, step: 1)
                        .frame(width: 220)
                }
                SettingsDivider()
                SettingsRow(title: "光标形状", detail: "选择终端光标样式。") {
                    Picker("", selection: cursorShapeBinding) {
                        Text("块").tag("block")
                        Text("竖线").tag("bar")
                        Text("下划线").tag("underline")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
                SettingsDivider()
                SettingsRow(title: "光标闪烁", detail: "关闭后光标保持常亮。") {
                    Toggle("", isOn: cursorBlinkBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    private var shortcutSettings: some View {
        SettingsCard {
            ShortcutRow(keys: "⌘T", title: "新建标签页")
            SettingsDivider()
            ShortcutRow(keys: "⌘D", title: "左右分屏")
            SettingsDivider()
            ShortcutRow(keys: "⇧⌘D", title: "取消分屏")
            SettingsDivider()
            ShortcutRow(keys: "⌘F", title: "搜索终端内容")
            SettingsDivider()
            ShortcutRow(keys: "⌘K", title: "清屏")
            SettingsDivider()
            ShortcutRow(keys: "⌘1-9", title: "切换任务")
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0; store.applySettings() }
        )
    }

    private var fontBinding: Binding<String> { bind(\.fontName) }
    private var uiFontNameBinding: Binding<String> { bind(\.uiFontName) }
    private var sizeBinding: Binding<Double> { bind(\.fontSize) }
    private var cursorShapeBinding: Binding<String> { bind(\.cursorShape) }
    private var cursorBlinkBinding: Binding<Bool> { bind(\.cursorBlink) }
    private var opacityBinding: Binding<Double> { bind(\.bgOpacity) }
    private var lineSpacingBinding: Binding<Double> { bind(\.lineSpacing) }
    private var letterSpacingBinding: Binding<Double> { bind(\.letterSpacing) }
    private var paddingBinding: Binding<Double> { bind(\.padding) }
    private var scrollbackBinding: Binding<Int> { bind(\.scrollback) }
    private var gpuBinding: Binding<Bool> { bind(\.gpuRender) }
    private var sidebarWidthBinding: Binding<Double> { bind(\.sidebarWidth) }
    private var themeBinding: Binding<String> { bind(\.theme) }
    private var themeLightBinding: Binding<String> { bind(\.themeLight) }
    private var translucentSidebarBinding: Binding<Bool> { bind(\.translucentSidebar) }
    private var taskGroupingBinding: Binding<SidebarTaskGrouping> { bind(\.taskGrouping) }
    private var uiContrastBinding: Binding<Double> { bind(\.uiContrast) }
    private var motionPreferenceBinding: Binding<String> { bind(\.motionPreference) }
    private var uiFontSizeBinding: Binding<Double> { bind(\.uiFontSize) }

    private func colorOverrideBinding(
        _ keyPath: WritableKeyPath<AppSettings, UInt32?>,
        fallback: UInt32
    ) -> Binding<UInt32> {
        Binding(
            get: { store.settings[keyPath: keyPath] ?? fallback },
            set: {
                store.settings[keyPath: keyPath] = $0
                store.applySettings()
            }
        )
    }

    private func resetColorOverride(_ keyPath: WritableKeyPath<AppSettings, UInt32?>) {
        store.settings[keyPath: keyPath] = nil
        store.applySettings()
    }

    private var appearanceMode: SettingsAppearanceMode {
        guard !store.settings.followSystemTheme else { return .system }
        return TerminalTheme.by(id: store.settings.theme).isLight ? .light : .dark
    }

    private var darkThemes: [TerminalTheme] {
        orderedThemes(
            ids: [
                "rose-pine", "ayu-mirage", "catppuccin-mocha", "relay-dark",
                "dracula", "nord", "spacegray", "gruvbox-dark",
                "tokyo-night", "night-owl", "one-dark", "solarized-dark",
                "xcode-dark", "apple-pro", "ocean"
            ],
            selected: store.settings.theme,
            wantLight: false
        )
    }

    private var lightThemes: [TerminalTheme] {
        orderedThemes(
            ids: [
                "rose-pine-dawn", "ayu-light", "catppuccin-latte", "light",
                "xcode-light", "apple-basic", "tokyo-night-day", "novel"
            ],
            selected: store.settings.themeLight,
            wantLight: true
        )
    }

    private func orderedThemes(ids: [String], selected: String, wantLight: Bool) -> [TerminalTheme] {
        var seen = Set<String>()
        var output: [TerminalTheme] = []

        for id in ids {
            let theme = TerminalTheme.by(id: id)
            guard theme.isLight == wantLight, !seen.contains(theme.id) else { continue }
            output.append(theme)
            seen.insert(theme.id)
        }

        let current = TerminalTheme.by(id: selected)
        if current.isLight == wantLight, !seen.contains(current.id) {
            output.insert(current, at: 0)
            seen.insert(current.id)
        }

        for theme in TerminalTheme.all where theme.isLight == wantLight && !seen.contains(theme.id) {
            output.append(theme)
            seen.insert(theme.id)
        }

        return output
    }

    private var blurBinding: Binding<Double> {
        Binding(
            get: { Double(store.settings.bgBlur) },
            set: { store.settings.bgBlur = Int($0); store.applySettings() }
        )
    }

    private func setAppearanceMode(_ mode: SettingsAppearanceMode) {
        switch mode {
        case .system:
            store.settings.followSystemTheme = true
            if TerminalTheme.by(id: store.settings.theme).isLight {
                store.settings.theme = TerminalTheme.counterpart(of: store.settings.theme, wantLight: false)
            }
            if !TerminalTheme.by(id: store.settings.themeLight).isLight {
                store.settings.themeLight = TerminalTheme.counterpart(of: store.settings.themeLight, wantLight: true)
            }
        case .light:
            store.settings.followSystemTheme = false
            let light = TerminalTheme.by(id: store.settings.themeLight).isLight
                ? store.settings.themeLight
                : "catppuccin-latte"
            store.settings.theme = light
            store.settings.themeLight = light
        case .dark:
            store.settings.followSystemTheme = false
            let dark = TerminalTheme.by(id: store.settings.theme).isLight
                ? TerminalTheme.counterpart(of: store.settings.theme, wantLight: false)
                : store.settings.theme
            store.settings.theme = TerminalTheme.by(id: dark).isLight ? "relay-dark" : dark
        }
        store.applySettings()
    }

    private func themePickerRow(
        title: String,
        themes: [TerminalTheme],
        selection: Binding<String>
    ) -> some View {
        SettingsRow(title: title, detail: TerminalTheme.by(id: selection.wrappedValue).name) {
            CodexThemeMenuControl(selection: selection, themes: themes)
        }
    }
}

private enum SettingsAppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

private struct AppearanceModeSelector: View {
    let selected: SettingsAppearanceMode
    let select: (SettingsAppearanceMode) -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(SettingsAppearanceMode.allCases) { mode in
                Button {
                    select(mode)
                } label: {
                    VStack(spacing: 10) {
                        AppearancePreviewCard(mode: mode, selected: selected == mode)
                            .aspectRatio(1.58, contentMode: .fit)
                        Text(mode.title)
                            .font(Theme.uiFont(size: 13, weight: .semibold))
                            .foregroundColor(selected == mode ? Theme.fg0 : Theme.fg2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct AppearancePreviewCard: View {
    let mode: SettingsAppearanceMode
    let selected: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let dark = mode == .dark
            let split = mode == .system
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(dark ? Color(hex: 0x5C5C5C) : Color(hex: 0xF4F4F4))

                if split {
                    HStack(spacing: 0) {
                        Color(hex: 0xDCDCDC)
                        Color(hex: 0x5F5F5F)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(spacing: 9) {
                    Capsule()
                        .fill((dark || split) ? Color.white.opacity(0.38) : Color.black.opacity(0.16))
                        .frame(width: size.width * 0.30, height: 7)
                    Capsule()
                        .fill((dark || split) ? Color.white.opacity(0.32) : Color.black.opacity(0.10))
                        .frame(width: size.width * 0.52, height: 5)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(dark ? Color.white.opacity(0.92) : Color.white.opacity(0.96))
                        .frame(width: size.width * 0.82, height: size.height * 0.40)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 8) {
                                Capsule().fill(Color.black.opacity(0.12)).frame(width: size.width * 0.26, height: 7)
                                Capsule().fill(Color.black.opacity(0.08)).frame(width: size.width * 0.40, height: 5)
                                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
                                Capsule().fill(Color.black.opacity(0.13)).frame(width: size.width * 0.28, height: 7)
                                Capsule().fill(Color.black.opacity(0.08)).frame(width: size.width * 0.38, height: 5)
                            }
                            .padding(12)
                        }
                }
                .padding(16)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Color(hex: 0x6CB6FF) : Theme.chromeLine, lineWidth: selected ? 2 : 1)
            )
        }
    }
}

private struct ThemeCodePreview: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 0) {
            codeColumn(
                tint: Color(hex: theme.ansi.indices.contains(1) ? theme.ansi[1] : theme.caret),
                lines: [
                    ("1", "const themePreview: ThemeConfig = {"),
                    ("2", "  surface: \"sidebar\","),
                    ("3", "  accent: \"\(hexString(theme.caret))\","),
                    ("4", "  contrast: 60,")
                ],
                highlight: Color(hex: theme.ansi.indices.contains(1) ? theme.ansi[1] : theme.caret).opacity(0.20)
            )
            Rectangle().fill(Theme.chromeLine).frame(width: 1)
            codeColumn(
                tint: Color(hex: theme.ansi.indices.contains(2) ? theme.ansi[2] : theme.caret),
                lines: [
                    ("1", "const themePreview: ThemeConfig = {"),
                    ("2", "  surface: \"sidebar-elevated\","),
                    ("3", "  accent: \"\(hexString(theme.fg))\","),
                    ("4", "  contrast: 68,")
                ],
                highlight: Color(hex: theme.ansi.indices.contains(2) ? theme.ansi[2] : theme.caret).opacity(0.16)
            )
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .frame(height: 108)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.workspaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.chromeLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func codeColumn(
        tint: Color,
        lines: [(String, String)],
        highlight: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    Text(lines[index].0)
                        .foregroundColor(Theme.fg2)
                        .frame(width: 20, alignment: .trailing)
                    Text(lines[index].1)
                        .foregroundColor(index == 0 ? Theme.fg0 : tint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
                .background(index == 1 || index == 2 ? highlight : Color.clear)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }
}

private struct ColorValuePill: View {
    let hex: UInt32

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(Theme.chromeLine, lineWidth: 1)
                .background(Circle().fill(Color(hex: hex)))
                .frame(width: 13, height: 13)
            Text(hexString(hex))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(foreground)
        .frame(width: 118, height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: hex)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.chromeLine, lineWidth: 1))
    }

    private var foreground: Color {
        let r = Double((hex >> 16) & 0xFF)
        let g = Double((hex >> 8) & 0xFF)
        let b = Double(hex & 0xFF)
        let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        return lum > 0.58 ? Color.black.opacity(0.78) : Color.white.opacity(0.92)
    }
}

private struct EditableColorValueField: View {
    @Binding var hex: UInt32
    let defaultHex: UInt32
    let isOverridden: Bool
    let reset: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: colorSelection, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 24, height: 24)

            TextField("#RRGGBB", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(foreground)
                .focused($focused)
                .onSubmit(commitDraft)
                .onChange(of: focused) { isFocused in
                    if !isFocused { commitDraft() }
                }
                .onChange(of: hex) { next in
                    if !focused { draft = hexString(next) }
                }
                .onAppear { draft = hexString(hex) }

            if isOverridden {
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(foreground.opacity(0.82))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("还原主题默认值")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, isOverridden ? 6 : 10)
        .frame(width: 190, height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: hex)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.chromeLine, lineWidth: 1))
    }

    private var colorSelection: Binding<Color> {
        Binding(
            get: { Color(hex: hex) },
            set: { color in
                if let ns = NSColor(color).usingColorSpace(.sRGB) {
                    hex = ns.hex6
                    draft = hexString(ns.hex6)
                }
            }
        )
    }

    private var foreground: Color {
        let r = Double((hex >> 16) & 0xFF)
        let g = Double((hex >> 8) & 0xFF)
        let b = Double(hex & 0xFF)
        let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        return lum > 0.58 ? Color.black.opacity(0.78) : Color.white.opacity(0.92)
    }

    private func commitDraft() {
        guard let next = parseHexColor(draft) else {
            draft = hexString(hex)
            return
        }
        hex = next
        draft = hexString(next)
    }
}

private struct DisabledValueField: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Theme.fg2)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(width: 190, height: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chromeControl))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.chromeLine, lineWidth: 1))
    }
}

private struct ValueBadge: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(Theme.fg0)
            .frame(width: 48, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chromeControl))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.chromeLine, lineWidth: 1))
    }
}

private func hexString(_ hex: UInt32) -> String {
    String(format: "#%06X", hex)
}

private func parseHexColor(_ value: String) -> UInt32? {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, text.allSatisfy({ $0.isHexDigit }) else { return nil }
    return UInt32(text, radix: 16)
}

private struct CodexThemeMenuControl: View {
    @Binding var selection: String
    let themes: [TerminalTheme]

    private var selectedTheme: TerminalTheme {
        themes.first { $0.id == selection } ?? TerminalTheme.by(id: selection)
    }

    var body: some View {
        Menu {
            ForEach(themes, id: \.id) { theme in
                Button {
                    selection = theme.id
                } label: {
                    Label(codexThemeName(theme), systemImage: selection == theme.id ? "checkmark" : "textformat")
                }
            }
        } label: {
            CodexMenuField(
                title: codexThemeName(selectedTheme),
                accessory: .theme(selectedTheme)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct CodexFontMenuControl: View {
    @Binding var selection: String
    let fonts: [(id: String, label: String)]

    private var selectedLabel: String {
        fonts.first { $0.id == selection }?.label ?? selection
    }

    var body: some View {
        Menu {
            ForEach(fonts, id: \.id) { font in
                Button {
                    selection = font.id
                } label: {
                    Label(font.label, systemImage: selection == font.id ? "checkmark" : "textformat")
                }
            }
        } label: {
            CodexMenuField(
                title: selectedLabel,
                accessory: .font
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct CodexMenuField: View {
    @ObservedObject private var store = SessionStore.shared

    enum Accessory {
        case theme(TerminalTheme)
        case font
    }

    let title: String
    let accessory: Accessory

    var body: some View {
        HStack(spacing: 9) {
            switch accessory {
            case .theme(let theme):
                ThemeAaBadge(theme: theme)
            case .font:
                FontAaBadge()
            }

            Text(title)
                .font(Theme.uiFont(size: CGFloat(max(12, store.settings.uiFontSize - 1)), weight: .semibold))
                .foregroundColor(Theme.fg0)
                .lineLimit(1)

            Spacer(minLength: 8)

            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.fg2)
        }
        .padding(.horizontal, 10)
        .frame(width: 190, height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.chromeControlHover))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.chromeLine, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct ThemeAaBadge: View {
    let theme: TerminalTheme

    var body: some View {
        Text("Aa")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Color(hex: theme.fg))
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(hex: theme.bg)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.chromeLine, lineWidth: 1))
    }
}

private struct FontAaBadge: View {
    var body: some View {
        Text("Aa")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Theme.fg0)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.workspaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.chromeLine, lineWidth: 1))
    }
}

private func codexThemeName(_ theme: TerminalTheme) -> String {
    switch theme.id {
    case "relay-dark", "light": return "Codex"
    case "catppuccin-mocha", "catppuccin-latte": return "Catppuccin"
    case "ayu-mirage", "ayu-light": return "Ayu"
    case "dracula": return "Dracula"
    case "gruvbox-dark": return "Gruvbox"
    case "one-dark": return "One"
    case "nord": return "Nord"
    case "tokyo-night", "tokyo-night-day": return "Linear"
    case "rose-pine", "rose-pine-dawn": return "Absolutely"
    case "night-owl": return "GitHub"
    case "spacegray": return "Notion"
    case "solarized-dark": return "Solarized"
    case "xcode-dark", "xcode-light": return "Xcode"
    case "apple-pro", "apple-basic": return "Apple"
    default: return theme.name
    }
}

private struct SettingsSidebarRow: View {
    @ObservedObject private var store = SessionStore.shared

    let section: SettingsView.SettingsSection
    @Binding var selected: SettingsView.SettingsSection
    let compact: Bool

    @State private var hovered = false

    private var active: Bool { selected == section }

    var body: some View {
        Button {
            selected = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)

                if compact {
                    Text(section.title)
                        .font(Theme.uiFont(size: CGFloat(max(12, store.settings.uiFontSize - 1)), weight: .medium))
                        .lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.title)
                            .font(Theme.uiFont(size: CGFloat(max(12, store.settings.uiFontSize - 1)), weight: .semibold))
                        Text(section.detail)
                            .font(Theme.uiFont(size: CGFloat(max(10, store.settings.uiFontSize - 3.5))))
                            .foregroundColor(Theme.fg2)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .foregroundColor(active ? Theme.sidebarPrimary : Theme.sidebarPrimary.opacity(compact ? 0.86 : 0.72))
            .frame(height: compact ? 30 : 44)
            .padding(.horizontal, compact ? 9 : 9)
            .background(SettingsSidebarRowBackground(isActive: active, isHovered: hovered, compact: compact))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct SettingsSidebarRowBackground: View {
    @Environment(\.controlActiveState) private var controlActiveState
    let isActive: Bool
    let isHovered: Bool
    let compact: Bool

    private var windowActive: Bool {
        controlActiveState != .inactive
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous)

        ZStack {
            if isActive {
                shape.fill(
                    LinearGradient(
                        colors: windowActive
                            ? [Theme.sidebarSelectionHighlight, Theme.sidebarSelection]
                            : [Theme.sidebarSelectionInactiveStroke, Theme.sidebarSelectionInactive],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.stroke(
                    windowActive ? Theme.sidebarSelectionStroke : Theme.sidebarSelectionInactiveStroke,
                    lineWidth: 1
                )
            } else if isHovered {
                shape.fill(compact ? Theme.sidebarHover : Theme.chromeControlHover)
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.workspaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.chromeLine, lineWidth: 1)
        )
    }
}

private struct SettingsSectionBlock<Content: View>: View {
    @ObservedObject private var store = SessionStore.shared

    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.uiFont(size: CGFloat(max(13, store.settings.uiFontSize)), weight: .semibold))
                    .foregroundColor(Theme.fg0)
                Text(detail)
                    .font(Theme.uiFont(size: CGFloat(max(11, store.settings.uiFontSize - 2))))
                    .foregroundColor(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

private struct SettingsRow<Content: View>: View {
    @ObservedObject private var store = SessionStore.shared

    let title: String
    let detail: String
    @ViewBuilder let control: Content

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.uiFont(size: CGFloat(max(12, store.settings.uiFontSize - 1)), weight: .semibold))
                    .foregroundColor(Theme.fg0)
                Text(detail)
                    .font(Theme.uiFont(size: CGFloat(max(10, store.settings.uiFontSize - 2.5))))
                    .foregroundColor(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 58)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.chromeLine)
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

private struct ShortcutRow: View {
    let keys: String
    let title: String

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(Theme.uiFont(size: 13, weight: .semibold))
                .foregroundColor(Theme.fg0)
            Spacer()
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.fg2)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chromeControl))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
