// 设置的分区/分组/设置行数据（cmux 式）。控件用 bind(...) 接 AppSettings，
// 改动即时生效并持久化。新增设置项在这里加一行 SettingsRow 即可被搜索覆盖。
import AppKit
import SwiftUI

extension SettingsView {
    var sections: [SettingsSection] {
        [
            SettingsSection(id: "appearance", icon: "paintpalette.fill", title: "外观", groups: appearanceGroups),
            SettingsSection(id: "typography", icon: "textformat.size", title: "字体与排版", groups: typographyGroups),
            SettingsSection(id: "cursor", icon: "cursorarrow.rays", title: "光标与输入", groups: cursorGroups),
            SettingsSection(id: "terminal", icon: "terminal.fill", title: "终端", groups: terminalGroups),
            SettingsSection(id: "tasks", icon: "rectangle.stack.fill", title: "会话与任务", groups: taskGroups),
            SettingsSection(id: "window", icon: "sidebar.left", title: "窗口与侧栏", groups: windowGroups),
            SettingsSection(id: "update", icon: "arrow.triangle.2.circlepath", title: "更新", groups: updateGroups),
            SettingsSection(id: "keys", icon: "keyboard.fill", title: "快捷键", groups: keyGroups),
            SettingsSection(id: "about", icon: "info.circle.fill", title: "关于与重置", groups: aboutGroups),
        ]
    }

    // MARK: - 外观

    private var appearanceGroups: [SettingsGroup] {
        let follow = store.settings.followSystemTheme
        // 跟随系统时暗/亮各绑一套（theme / themeLight，Ghostty light:…,dark:… 语义）；
        // 关闭时两格都绑 theme，选任一款即为当前唯一生效主题。两态网格结构始终一致
        // （暗色格 + 亮色格），切换开关只改绑定与标题，不整格重排内容。
        let lightKP: WritableKeyPath<AppSettings, String> = follow ? \.themeLight : \.theme
        let themeRows: [SettingsRow] = [
            SettingsRow(id: "follow", title: "跟随系统明暗",
                        subtitle: "开启后亮/暗各用一套主题；关闭则固定用所选主题",
                        keywords: "theme dark light 跟随 系统 明暗",
                        control: switchCtl(\.followSystemTheme)),
            SettingsRow(id: "theme", title: follow ? "夜间主题（暗色）" : "暗色主题",
                        subtitle: follow ? "系统处于暗色时使用" : nil,
                        keywords: "theme 主题 配色 color dark 暗色 夜间", layout: .below,
                        control: themeGrid(\.theme, filter: { !$0.isLight })),
            SettingsRow(id: "themeLight", title: follow ? "日间主题（亮色）" : "亮色主题",
                        subtitle: follow ? "系统处于亮色时使用" : nil,
                        keywords: "theme light 日间 亮色 配色", layout: .below,
                        control: themeGrid(lightKP, filter: { $0.isLight })),
        ]
        let bgRows: [SettingsRow] = [
            SettingsRow(id: "opacity", title: "背景不透明度 · \(Int(store.settings.bgOpacity * 100))%",
                        subtitle: "低于 100% 时整窗半透明",
                        keywords: "opacity 透明 背景", layout: .below,
                        control: sliderCtl(\.bgOpacity, 0.7...1.0, 0.01)),
            SettingsRow(id: "blur", title: "毛玻璃模糊 · \(store.settings.bgBlur)",
                        subtitle: "需不透明度低于 100% 才可见",
                        keywords: "blur 模糊 毛玻璃", layout: .below, control: blurSlider),
        ]
        return [SettingsGroup(header: "主题", rows: themeRows),
                SettingsGroup(header: "窗口背景", rows: bgRows)]
    }

    // MARK: - 字体与排版

    private var typographyGroups: [SettingsGroup] {
        let s = store.settings
        return [SettingsGroup(rows: [
            SettingsRow(id: "font", title: "字体", keywords: "font 字体", control: fontPicker),
            SettingsRow(id: "size", title: "字号 · \(Int(s.fontSize)) pt",
                        keywords: "size 字号", layout: .below, control: sliderCtl(\.fontSize, 9...24, 1)),
            SettingsRow(id: "line", title: "行高微调 · +\(String(format: "%.1f", s.lineSpacing)) pt",
                        keywords: "line height 行高", layout: .below, control: sliderCtl(\.lineSpacing, 0...4, 0.5)),
            SettingsRow(id: "letter", title: "字距微调 · \(String(format: "%.2f", s.letterSpacing)) pt",
                        subtitle: "负值收紧；中文占 2 格，收紧量加倍",
                        keywords: "letter spacing 字距", layout: .below,
                        control: sliderCtl(\.letterSpacing, -1.0...1.0, 0.25)),
            SettingsRow(id: "padding", title: "终端内边距 · \(Int(s.padding)) pt",
                        keywords: "padding 内边距", layout: .below, control: sliderCtl(\.padding, 0...20, 1)),
        ])]
    }

    // MARK: - 光标与输入

    private var cursorGroups: [SettingsGroup] {
        [SettingsGroup(header: "光标", rows: [
            SettingsRow(id: "shape", title: "光标形状", keywords: "cursor 光标 形状", layout: .below,
                        control: segCtl(\.cursorShape,
                                        [("block", "█ 块"), ("bar", "▏竖线"), ("underline", "▁ 下划线")], width: 280)),
            SettingsRow(id: "blink", title: "光标闪烁", keywords: "blink 闪烁", control: switchCtl(\.cursorBlink)),
        ]),
         SettingsGroup(header: "输入", rows: [
            SettingsRow(id: "copy", title: "选中即复制", subtitle: "选中文本立即写入剪贴板",
                        keywords: "copy 复制 选中", control: switchCtl(\.copyOnSelect)),
            SettingsRow(id: "paste", title: "多行粘贴前确认", subtitle: "防止整块内容被 shell 逐行自动执行",
                        keywords: "paste 粘贴 确认", control: switchCtl(\.confirmMultilinePaste)),
         ])]
    }

    // MARK: - 终端

    private var terminalGroups: [SettingsGroup] {
        [SettingsGroup(rows: [
            SettingsRow(id: "scrollback", title: "回看行数", subtitle: "对新建会话生效；越大每会话内存越高",
                        keywords: "scrollback 回看 行数", layout: .below,
                        control: segCtl(\.scrollback,
                                        [(500, "500"), (1000, "1000"), (2000, "2000"), (5000, "5000"), (10000, "10000")],
                                        width: 340)),
            SettingsRow(id: "gpu", title: "GPU 渲染", subtitle: "Metal · ProMotion 高刷；约 +150MB 内存",
                        keywords: "gpu metal 渲染", control: switchCtl(\.gpuRender)),
        ])]
    }

    // MARK: - 会话与任务

    private var taskGroups: [SettingsGroup] {
        [SettingsGroup(rows: [
            SettingsRow(id: "starter", title: "新建任务默认启动",
                        subtitle: "⌘⇧N 引导面板的初始启动方式；⌘N 即时新建始终是纯 Shell",
                        keywords: "starter claude codex 启动 默认 任务", layout: .below,
                        control: segCtl(\.defaultNewTaskStarter,
                                        [("", "纯 Shell"), ("claude", "Claude"), ("codex", "Codex")], width: 280)),
        ])]
    }

    // MARK: - 窗口与侧栏

    private var windowGroups: [SettingsGroup] {
        [SettingsGroup(rows: [
            SettingsRow(id: "sidebarVisible", title: "显示侧边栏", subtitle: "也可用标签条左侧按钮切换",
                        keywords: "sidebar 侧边栏", control: switchCtl(\.sidebarVisible)),
            SettingsRow(id: "sidebarWidth", title: "侧边栏宽度 · \(Int(store.settings.sidebarWidth)) pt",
                        keywords: "sidebar width 侧栏 宽度", layout: .below,
                        control: sliderCtl(\.sidebarWidth, 170...460, 1)),
        ])]
    }

    // MARK: - 更新

    private var updateGroups: [SettingsGroup] {
        [SettingsGroup(rows: [
            SettingsRow(id: "autoUpdate", title: "自动检查更新",
                        subtitle: "启动后台 + 每 24 小时查 GitHub Releases",
                        keywords: "update 更新", control: switchCtl(\.autoUpdateCheck)),
            SettingsRow(id: "checkNow", title: "检查更新", subtitle: "当前版本 \(Updater.currentVersion)",
                        keywords: "update 更新 检查 version",
                        control: AnyView(Button("立即检查") { Updater.check(interactive: true) }.controlSize(.small))),
        ])]
    }

    // MARK: - 快捷键（只读速查）

    private var keyGroups: [SettingsGroup] {
        let items: [(String, String)] = [
            ("新建标签", "⌘T"), ("即时新建（当前目录 Shell）", "⌘N"), ("新建任务引导", "⌘⇧N"),
            ("关闭当前", "⌘W"), ("分屏", "⌘D"), ("搜索", "⌘F"), ("清屏", "⌘K"),
            ("命令面板", "⌘P"), ("诊断面板", "⌘⇧I"), ("恢复刚关闭的", "⌘⇧T"),
            ("切换标签 1–9", "⌘1–9"), ("设置", "⌘,"),
        ]
        return [SettingsGroup(header: "常用快捷键", rows: items.enumerated().map { i, it in
            SettingsRow(id: "key\(i)", title: it.0, keywords: "shortcut 快捷键 \(it.0)",
                        control: AnyView(Text(it.1).font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(Theme.fg2)))
        })]
    }

    // MARK: - 关于与重置

    private var aboutGroups: [SettingsGroup] {
        [SettingsGroup(rows: [
            SettingsRow(id: "version", title: "Relay 版本", keywords: "version 版本",
                        control: AnyView(Text(Updater.currentVersion)
                            .font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.fg2))),
            SettingsRow(id: "datadir", title: "数据目录", subtitle: "会话、设置、回看的存放位置",
                        keywords: "data 目录 finder 访达",
                        control: AnyView(Button("在访达中显示") { revealDataDir() }.controlSize(.small))),
        ]),
         SettingsGroup(rows: [
            SettingsRow(id: "reset", title: "恢复默认设置", subtitle: "重置所有外观与行为选项（保留任务模板）",
                        keywords: "reset 重置 默认",
                        control: AnyView(Button("恢复默认") { confirmReset() }.controlSize(.small).tint(.red))),
         ])]
    }

    // MARK: - 控件构造

    func switchCtl(_ kp: WritableKeyPath<AppSettings, Bool>) -> AnyView {
        AnyView(Toggle("", isOn: bind(kp)).labelsHidden().toggleStyle(.switch).controlSize(.small))
    }

    func sliderCtl(_ kp: WritableKeyPath<AppSettings, Double>,
                   _ range: ClosedRange<Double>, _ step: Double, width: CGFloat = 340) -> AnyView {
        // 拖动中只改 settings（@Published 即时驱动标题数值与依赖 settings 的 SwiftUI
        // 预览，如内边距/不透明度/侧栏宽度），松手（editing 结束）才调一次重量级
        // applySettings()——否则每个中间值都触发逐视图字体重算 + 全屏 refresh + 落盘，
        // 拖动肉眼掉帧。离散控件（开关/分段）仍走 bind() 即时 apply。
        let v = Binding<Double>(
            get: { store.settings[keyPath: kp] },
            set: { store.settings[keyPath: kp] = $0 })
        return AnyView(Slider(value: v, in: range, step: step,
                              onEditingChanged: { if !$0 { store.applySettings() } })
            .frame(maxWidth: width))
    }

    func segCtl<T: Hashable>(_ kp: WritableKeyPath<AppSettings, T>,
                             _ options: [(T, String)], width: CGFloat = 300) -> AnyView {
        AnyView(Picker("", selection: bind(kp)) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                Text(opt.1).tag(opt.0)
            }
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: width))
    }

    var fontPicker: AnyView {
        AnyView(Picker("", selection: bind(\.fontName)) {
            ForEach(TerminalTheme.availableFonts(), id: \.id) { f in Text(f.label).tag(f.id) }
        }.labelsHidden().frame(maxWidth: 240))
    }

    /// bgBlur 是 Int，Slider 要 Double：单独桥一层。
    var blurSlider: AnyView {
        // 同 sliderCtl：拖动中只改 settings，松手才 applySettings()（Int↔Double 桥接）。
        let b = Binding<Double>(
            get: { Double(store.settings.bgBlur) },
            set: { store.settings.bgBlur = Int($0) })
        return AnyView(Slider(value: b, in: 0...40, step: 1,
                              onEditingChanged: { if !$0 { store.applySettings() } })
            .frame(maxWidth: 340)
            .disabled(store.settings.bgOpacity >= 0.999))
    }

    // MARK: - 主题卡片网格

    func themeGrid(_ kp: WritableKeyPath<AppSettings, String>,
                   filter: (TerminalTheme) -> Bool) -> AnyView {
        let themes = TerminalTheme.all.filter(filter)
        let current = store.settings[keyPath: kp]
        let cols = [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 10)]
        return AnyView(
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                ForEach(themes) { t in
                    themeCard(t, selected: t.id == current) {
                        store.settings[keyPath: kp] = t.id
                        store.applySettings()
                    }
                }
            }
        )
    }

    private func themeCard(_ t: TerminalTheme, selected: Bool,
                           _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aa").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: t.fg))
                    HStack(spacing: 2) {
                        ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2).fill(Color(hex: t.ansi[i])).frame(height: 7)
                        }
                    }
                }
                .padding(7).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: t.bg)))
                Text(t.name).font(.system(size: 10.5)).foregroundColor(Theme.fg2).lineLimit(1)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? Color.accentColor : Theme.line, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
