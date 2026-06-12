// 应用生命周期：主窗口（SwiftUI 外壳 + SwiftTerm 终端）、菜单、退出清理。
import AppKit
import SwiftUI
import SwiftTerm

// 窗口背景毛玻璃：iTerm2/Ghostty 同款 CGS 私有 API（App Store 不可上，
// 本应用 adhoc 签名分发无碍）。radius 0 = 关闭。
@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> UInt32
@discardableResult
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
private func CGSSetWindowBackgroundBlurRadius(
    _ connection: UInt32, _ window: UInt32, _ radius: UInt32) -> Int32

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    /// 窗口级透明与毛玻璃（applySettings 每次调用）。透明度 <1 才放开
    /// isOpaque/clear 背景 —— 不透明时保持系统默认，避免无谓的合成开销。
    /// 同时按生效终端主题的明暗设窗口 appearance：Theme 的动态色、SwiftUI
    /// 语义色与设置窗口随之整体切换（日间侧栏半透明白的关键一环）。
    func applyWindowChrome(opacity: Double, blur: Int) {
        let appearance = NSAppearance(
            named: SessionStore.shared.shellIsLight ? .aqua : .darkAqua)
        settingsWindow?.appearance = appearance
        guard let w = window, w.windowNumber > 0 else { return }
        w.appearance = appearance
        let translucent = opacity < 0.999
        w.isOpaque = !translucent
        w.backgroundColor = translucent ? .clear : .windowBackgroundColor
        CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(), UInt32(w.windowNumber),
            translucent ? UInt32(max(0, min(64, blur))) : 0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 运行时直设 Dock/切换器图标：ad-hoc 签名 + 手工组包的 app，
        // iconservices 常按 bundle id 命中旧缓存（通用图标），不等系统刷新。
        if let icns = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: icns) {
            NSApp.applicationIconImage = icon
        }

        // 系统明暗必须先于任何视图创建同步好 —— 终端视图在首次布局时
        // 按 effectiveThemeId 取主题，默认值 dark 会让日间启动拿到暗主题。
        SessionStore.shared.systemIsDark =
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let content = NSHostingView(rootView: RootView())
        // 默认 sizingOptions 会按 SwiftUI 内容的理想尺寸收缩窗口
        //（空态内容很小 → 窗口被压成 ~110px）。窗口尺寸由我们自己管。
        content.sizingOptions = []
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 760, height: 480)
        // 不随关闭释放：State Restoration / 误关窗口后还能 reopen。
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        // appearance 不在此硬编码：下方 applySettings → applyWindowChrome
        // 按生效主题明暗设置。
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        // 启动即按设置应用窗口外观（透明/毛玻璃；明暗已在最前面同步）。
        SessionStore.shared.applySettings()
        // 系统明暗切换 → 重选 light/dark 主题（followSystemTheme 开启时）。
        // 通知可能先于 effectiveAppearance 更新到达，延后一拍再读。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async { SessionStore.shared.noteSystemAppearance() }
        }

        // 分屏 pane 焦点跟踪：点击哪个终端，活动会话（侧栏高亮/标题条/⌘W 对象）
        // 就跟到哪个。becomeFirstResponder 被 SwiftTerm 以 non-open 覆写，
        // 跨模块无法再 override，改用本地事件监听。
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { e in
            if let w = e.window, let hit = w.contentView?.hitTest(e.locationInWindow) {
                var v: NSView? = hit
                while let cur = v {
                    if let tv = cur as? RelayTerminalView {
                        SessionStore.shared.noteFocused(id: tv.sessionId)
                        break
                    }
                    v = cur.superview
                }
            }
            return e
        }

        // 按住 ⌘：侧栏任务行显示 ⌘1-9 快捷角标（cmux 式快速切换提示）。
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            SessionStore.shared.noteCmdHeld(e.modifierFlags.contains(.command))
            return e
        }

        // 基准/排障入口：仅 RELAY_DEBUG=1 直接执行二进制时注册（open 启动的
        // 正式实例拿不到该环境变量，等于发布版无此入口）。
        //   notifyutil 投递 relay.sendText.<pid>(userInfo text=) 向当前会话键入。
        //   通知名带 PID 后缀：多个调试实例并存时定向注入，不会误伤其他实例。
        if ProcessInfo.processInfo.environment["RELAY_DEBUG"] == "1" {
            let pid = ProcessInfo.processInfo.processIdentifier
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("relay.sendText.\(pid)"), object: nil, queue: .main
            ) { note in
                if let t = note.userInfo?["text"] as? String {
                    SessionStore.shared.activeView?.send(txt: t)
                }
            }
            //   notifyutil 投递 relay.dump.<pid>：各会话 cols/rows/frame 落到 stderr。
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("relay.dump.\(pid)"), object: nil, queue: .main
            ) { _ in
                for (id, v) in SessionStore.shared.debugViews {
                    let t = v.getTerminal()
                    FileHandle.standardError.write(Data(
                        "[dump] \(id) cols=\(t.cols) rows=\(t.rows) frame=\(v.frame) font=\(v.font.pointSize)\n".utf8))
                }
                Self.debugDumpLayers()
            }
            //   relay.dumpTree.<pid>：窗口/视图/CALayer 三级透明合成快照（排查
            //   半透明背景被哪一层涂黑）。
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("relay.dumpTree.\(pid)"), object: nil, queue: .main
            ) { _ in
                Self.debugDumpLayers()
            }
            //   relay.setGpu.<pid>(userInfo on=0/1)：模拟设置页运行时切换渲染器。
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("relay.setGpu.\(pid)"), object: nil, queue: .main
            ) { note in
                if let on = note.userInfo?["on"] as? String {
                    SessionStore.shared.settings.gpuRender = on == "1"
                    SessionStore.shared.applySettings()
                }
            }
        }
    }

    /// 调试转储：窗口属性 + 视图树 + CALayer 树的透明合成快照（stderr）。
    /// 只走 RELAY_DEBUG 通知入口，发布路径不可达。
    private static func debugDumpLayers() {
        let store = SessionStore.shared
        var out = "[tree] eff=\(store.effectiveThemeId) sysDark=\(store.systemIsDark) " +
                  "bgOpacity=\(store.settings.bgOpacity) padding=\(store.settings.padding) " +
                  "gpu=\(store.settings.gpuRender)\n"
        func rgba(_ c: NSColor?) -> String {
            guard let d = c?.usingColorSpace(.deviceRGB) else { return "nil" }
            return String(format: "(%.2f,%.2f,%.2f,%.2f)",
                          d.redComponent, d.greenComponent, d.blueComponent, d.alphaComponent)
        }
        func cg(_ c: CGColor?) -> String {
            guard let c = c, let comps = c.components else { return "nil" }
            return "(" + comps.map { String(format: "%.2f", $0) }.joined(separator: ",") + ")"
        }
        if let w = (NSApp.delegate as? AppDelegate)?.window {
            out += "[tree] window isOpaque=\(w.isOpaque) bg=\(rgba(w.backgroundColor)) " +
                   "appearance=\(w.appearance?.name.rawValue ?? "nil")\n"
            func walkView(_ v: NSView, _ d: Int) {
                let pad = String(repeating: "  ", count: d)
                var line = "\(pad)V \(type(of: v)) \(Int(v.frame.width))x\(Int(v.frame.height))"
                if let tv = v as? RelayTerminalView {
                    line += " nativeBG=\(rgba(tv.nativeBackgroundColor))"
                }
                if let l = v.layer {
                    line += " L=\(type(of: l)) op=\(l.isOpaque ? 1 : 0) lbg=\(cg(l.backgroundColor))"
                }
                out += line + "\n"
                for s in v.subviews { walkView(s, d + 1) }
            }
            if let cv = w.contentView { walkView(cv, 1) }
            func walkLayer(_ l: CALayer, _ d: Int) {
                guard d < 12 else { return }
                let pad = String(repeating: "  ", count: d)
                out += "\(pad)L \(type(of: l)) \(Int(l.bounds.width))x\(Int(l.bounds.height))" +
                       " op=\(l.isOpaque ? 1 : 0) alpha=\(String(format: "%.2f", l.opacity))" +
                       " bg=\(cg(l.backgroundColor))\n"
                for s in l.sublayers ?? [] { walkLayer(s, d + 1) }
            }
            if let rl = w.contentView?.layer { walkLayer(rl, 1) }
        }
        FileHandle.standardError.write(Data(out.utf8))
    }

    // 终端应用惯例：关窗不退出（launch 时 State Restoration 可能瞬时关窗，
    // 若返回 true 会被连带 terminate —— 实测 open 启动 2 秒即静默退出）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.shared.persistAllScrollback()
    }

    /// 主菜单：原生终端常用命令与快捷键全量支持。
    /// 编辑类走 responder chain（SwiftTerm TerminalView 自带 copy:/paste:/selectAll:），
    /// 会话/视图类直达 SessionStore。
    private func buildMenu() {
        let main = NSMenu()

        func menu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            build(m)
            item.submenu = m
            main.addItem(item)
        }
        func add(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String,
                 _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = target
            m.addItem(it)
        }

        menu("Relay") { m in
            add(m, "关于 Relay", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
            m.addItem(.separator())
            add(m, "偏好设置…", #selector(self.openSettings(_:)), ",", target: self)
            m.addItem(.separator())
            add(m, "隐藏 Relay", #selector(NSApplication.hide(_:)), "h")
            m.addItem(.separator())
            add(m, "退出 Relay", #selector(NSApplication.terminate(_:)), "q")
        }
        menu("Shell") { m in
            add(m, "新建任务", #selector(self.newTask(_:)), "n", target: self)
            add(m, "新建标签页", #selector(self.newTab(_:)), "t", target: self)
            add(m, "关闭标签页", #selector(self.closeSession(_:)), "w", target: self)
            m.addItem(.separator())
            add(m, "左右分屏", #selector(self.splitPane(_:)), "d", target: self)
            add(m, "取消分屏", #selector(self.unsplitPane(_:)), "d", [.command, .shift], target: self)
            m.addItem(.separator())
            add(m, "清屏", #selector(self.clearScreen(_:)), "k", target: self)
        }
        menu("编辑") { m in
            add(m, "拷贝", #selector(NSText.copy(_:)), "c")
            add(m, "粘贴", #selector(NSText.paste(_:)), "v")
            add(m, "全选", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            add(m, "搜索终端内容", #selector(self.toggleSearch(_:)), "f", target: self)
        }
        menu("显示") { m in
            add(m, "放大字体", #selector(self.zoomIn(_:)), "+", target: self)
            add(m, "缩小字体", #selector(self.zoomOut(_:)), "-", target: self)
            add(m, "默认字号", #selector(self.zoomReset(_:)), "0", target: self)
        }
        menu("窗口") { m in
            add(m, "最小化", #selector(NSWindow.miniaturize(_:)), "m")
            m.addItem(.separator())
            add(m, "上一个标签页", #selector(self.prevSession(_:)), "[", [.command, .shift], target: self)
            add(m, "下一个标签页", #selector(self.nextSession(_:)), "]", [.command, .shift], target: self)
            m.addItem(.separator())
            for n in 1...9 {
                add(m, "任务 \(n)", #selector(self.selectTask(_:)), "\(n)", target: self)
            }
        }

        NSApp.mainMenu = main
    }

    // MARK: - 菜单动作

    @objc private func newTask(_ sender: Any?) { _ = SessionStore.shared.newTask() }
    @objc private func newTab(_ sender: Any?) { _ = SessionStore.shared.newTab() }
    @objc private func closeSession(_ sender: Any?) { SessionStore.shared.closeActive() }
    @objc private func splitPane(_ sender: Any?) { SessionStore.shared.splitActive() }
    @objc private func unsplitPane(_ sender: Any?) { SessionStore.shared.unsplit() }
    @objc private func toggleSearch(_ sender: Any?) { SessionStore.shared.searchVisible.toggle() }

    private var settingsWindow: NSWindow?

    @objc private func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 470),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            w.title = "Relay 设置"
            w.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: SettingsView())
            w.contentView = hosting
            // 设置项随版本增减，窗口高度跟内容走。
            w.setContentSize(hosting.fittingSize)
            w.appearance = window?.appearance
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func prevSession(_ sender: Any?) { SessionStore.shared.cycle(-1) }
    @objc private func nextSession(_ sender: Any?) { SessionStore.shared.cycle(1) }
    @objc private func zoomIn(_ sender: Any?) { SessionStore.shared.zoom(1) }
    @objc private func zoomOut(_ sender: Any?) { SessionStore.shared.zoom(-1) }
    @objc private func zoomReset(_ sender: Any?) { SessionStore.shared.zoom(0) }

    @objc private func selectTask(_ sender: Any?) {
        if let item = sender as? NSMenuItem, let n = Int(item.keyEquivalent) {
            SessionStore.shared.selectTask(index: n - 1)
        }
    }

    /// ⌘K：清屏 + 清回看（同 iTerm2 语义），随后发 Ctrl+L 让 shell 重绘提示符。
    @objc private func clearScreen(_ sender: Any?) {
        guard let v = SessionStore.shared.activeView else { return }
        v.getTerminal().resetToInitialState()
        v.send(txt: "\u{0C}")
    }
}
