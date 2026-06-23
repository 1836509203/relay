// 设置（⌘,）：主题（含明暗跟随）/ 字体 / 字号 / 光标 / 背景透明毛玻璃 /
// 行高 / 内边距 / 回看 / 渲染器，改动即时生效并持久化。
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store = SessionStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("终端外观")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.fg0)

            themeSection
            fontSection
            cursorSection
            backgroundSection
            layoutSection
            scrollbackSection
            gpuSection
            updateSection

            Divider()

            Text("快捷键：⌘T 新建 · ⌘W 关闭 · ⌘D 分屏 · ⌘F 搜索 · ⌘K 清屏 · ⌘1-9 切换")
                .font(.system(size: 10.5))
                .foregroundColor(Theme.fg3)
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.bg1)
    }

    // MARK: - 分区

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("配色主题").font(.system(size: 11)).foregroundColor(Theme.fg2)
            Toggle("跟随系统明暗（自动切换到配对的亮/暗款）", isOn: followBinding)
                .toggleStyle(.switch).font(.system(size: 12))
            Picker("", selection: themeBinding) {
                Section("暗色") {
                    ForEach(TerminalTheme.all.filter { !$0.isLight }) { t in
                        Text(t.name).tag(t.id)
                    }
                }
                Section("亮色") {
                    ForEach(TerminalTheme.all.filter { $0.isLight }) { t in
                        Text(t.name).tag(t.id)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)
            themeSwatch
        }
    }

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("字体").font(.system(size: 11)).foregroundColor(Theme.fg2)
            Picker("", selection: fontBinding) {
                ForEach(TerminalTheme.availableFonts(), id: \.id) { f in
                    Text(f.label).tag(f.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)
            Text("字号  \(Int(store.settings.fontSize)) pt")
                .font(.system(size: 11)).foregroundColor(Theme.fg2)
            Slider(value: sizeBinding, in: 9...24, step: 1).frame(maxWidth: 280)
        }
    }

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("光标").font(.system(size: 11)).foregroundColor(Theme.fg2)
            HStack(spacing: 10) {
                Picker("", selection: cursorShapeBinding) {
                    Text("█ 块").tag("block")
                    Text("▏竖线").tag("bar")
                    Text("▁ 下划线").tag("underline")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Toggle("闪烁", isOn: cursorBlinkBinding)
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
        }
    }

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("背景不透明度  \(Int(store.settings.bgOpacity * 100))%")
                .font(.system(size: 11)).foregroundColor(Theme.fg2)
            Slider(value: opacityBinding, in: 0.7...1.0, step: 0.01).frame(maxWidth: 280)
            Text("毛玻璃模糊  \(store.settings.bgBlur)")
                .font(.system(size: 11)).foregroundColor(Theme.fg2)
            Slider(value: blurBinding, in: 0...40, step: 1).frame(maxWidth: 280)
                .disabled(store.settings.bgOpacity >= 0.999)
            if store.settings.bgOpacity >= 0.999 {
                Text("毛玻璃需要不透明度低于 100% 才可见")
                    .font(.system(size: 10)).foregroundColor(Theme.fg3)
            }
        }
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("行高微调  +\(store.settings.lineSpacing, specifier: "%.1f") pt")
                .font(.system(size: 11)).foregroundColor(Theme.fg2)
            Slider(value: lineSpacingBinding, in: 0...4, step: 0.5).frame(maxWidth: 280)
            Text("字距微调  \(store.settings.letterSpacing, specifier: "%.2f") pt（负值收紧，中文加倍）")
                .font(.system(size: 11)).foregroundColor(Theme.fg2)
            Slider(value: letterSpacingBinding, in: -1.0...1.0, step: 0.25).frame(maxWidth: 280)
            Text("终端内边距  \(Int(store.settings.padding)) pt")
                .font(.system(size: 11)).foregroundColor(Theme.fg2)
            Slider(value: paddingBinding, in: 0...20, step: 1).frame(maxWidth: 280)
        }
    }

    private var scrollbackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("回看行数（对新建会话生效；行数越大每会话内存越高）")
                .font(.system(size: 11)).foregroundColor(Theme.fg2)
            Picker("", selection: scrollbackBinding) {
                ForEach([500, 1000, 2000, 5000, 10000], id: \.self) { n in
                    Text("\(n)").tag(n)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
        }
    }

    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("GPU 渲染（Metal · ProMotion 高刷）", isOn: gpuBinding)
                .toggleStyle(.switch)
                .font(.system(size: 12))
            Text("显著增加内存占用（约 +150MB）；默认的 CPU 渲染滚动同样流畅")
                .font(.system(size: 10))
                .foregroundColor(Theme.fg3)
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle("自动检查更新", isOn: bind(\.autoUpdateCheck))
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                Button("立即检查") { Updater.check(interactive: true) }
                    .font(.system(size: 11))
            }
            Text("当前版本 \(Updater.currentVersion) · 发现新版本时通过系统通知提醒")
                .font(.system(size: 10))
                .foregroundColor(Theme.fg3)
        }
    }

    // MARK: - 部件

    /// 当前生效主题的色板预览：主题背景铺底，前景字样 + ANSI 七彩小方块。
    private var themeSwatch: some View {
        let t = TerminalTheme.by(id: store.effectiveThemeId)
        return HStack(spacing: 5) {
            Text("Aa").font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: t.fg))
            ForEach(1..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(hex: t.ansi[i]))
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: t.bg)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
    }

    // MARK: - 绑定（set 即 applySettings：生效 + 持久化）

    private func bind<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0; store.applySettings() }
        )
    }

    private var themeBinding: Binding<String> { bind(\.theme) }
    private var followBinding: Binding<Bool> { bind(\.followSystemTheme) }
    private var fontBinding: Binding<String> { bind(\.fontName) }
    private var sizeBinding: Binding<Double> { bind(\.fontSize) }
    private var cursorShapeBinding: Binding<String> { bind(\.cursorShape) }
    private var cursorBlinkBinding: Binding<Bool> { bind(\.cursorBlink) }
    private var opacityBinding: Binding<Double> { bind(\.bgOpacity) }
    private var lineSpacingBinding: Binding<Double> { bind(\.lineSpacing) }
    private var letterSpacingBinding: Binding<Double> { bind(\.letterSpacing) }
    private var paddingBinding: Binding<Double> { bind(\.padding) }
    private var scrollbackBinding: Binding<Int> { bind(\.scrollback) }
    private var gpuBinding: Binding<Bool> { bind(\.gpuRender) }

    /// blur 是 Int，Slider 要 Double：单独桥一层。
    private var blurBinding: Binding<Double> {
        Binding(
            get: { Double(store.settings.bgBlur) },
            set: { store.settings.bgBlur = Int($0); store.applySettings() }
        )
    }
}
