// SwiftTerm 终端视图桥接：原生渲染（CoreText），无 WebView。
// RelayTerminalView 在数据回调处旁路一份给检测器；TerminalPane 把
// SessionStore 里的常驻视图实例挂进 SwiftUI 层级（切 tab 不销毁，历史保留）。
import AppKit
import SwiftUI
import SwiftTerm
import Darwin

/// 缓冲格子 → 纯文本字符。TUI 用光标跳跃绘制时跳过的格子是 NUL（code 0），
/// getCharacter() 原样返回 U+0000 —— 写进快照回放会被解析器丢弃（单词粘连），
/// 进检测/搜索会让含空格的关键词匹配失败。统一映射为空格。
let plainCell: (CharData) -> Character = { $0.isNull ? " " : $0.getCharacter() }

final class RelayTerminalView: LocalProcessTerminalView {
    var sessionId = ""

    /// 用户是否已在本视图敲过键（autoResume 用：用户抢先接管就放弃自动续接，
    /// 避免把 resume 命令拼进用户敲了一半的命令行）。
    private(set) var userHasTyped = false

    override func keyDown(with event: NSEvent) {
        userHasTyped = true
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any) {
        userHasTyped = true // 粘贴命令同样算用户接管
        super.paste(sender)
    }

    /// 渲染路径与设置对齐（Metal ⇄ CoreGraphics，可随时切换，buffer 无损）。
    /// 只有挂在窗口里的视图才持有 Metal —— 每套管线/drawable/字形图集
    /// ~160MB，N 个后台会话不该各占一份；detach 时立即释放（setUseMetal(false)
    /// 会移除 MTKView 并置空 renderer），重新挂载时再按设置重建。
    func syncRenderer(wantMetal: Bool) {
        let target = wantMetal && window != nil
        guard target != isUsingMetalRenderer else { return }
        do { try setUseMetal(target) } catch {
            FileHandle.standardError.write(Data("[metal] fallback CG: \(error)\n".utf8))
        }
    }

    /// 光标样式（形状 + 闪烁）。setCursorStyle 走 delegate 链同时更新
    /// CG 的 caretView 与 Metal 渲染器（两条路径都支持 bar/underline/block）。
    func applyCursorStyle(shape: String, blink: Bool) {
        let style: CursorStyle
        switch (shape, blink) {
        case ("bar", true): style = .blinkBar
        case ("bar", false): style = .steadyBar
        case ("underline", true): style = .blinkUnderline
        case ("underline", false): style = .steadyUnderline
        case (_, true): style = .blinkBlock
        default: style = .steadyBlock
        }
        getTerminal().setCursorStyle(style)
    }

    /// 恢复回看行数设置。SwiftTerm 设字体会走 setupOptions，用
    /// TerminalOptions(cols:rows:) 整体替换 options —— scrollback 等字段
    /// 全部回到默认 500。任何设置 font 的路径之后都必须调用本方法。
    /// reset=true 会重建 buffer 使容量立即生效（清屏，仅限喂数据前）。
    func ensureScrollback(reset: Bool = false) {
        let t = getTerminal()
        let scrollback = SessionStore.shared.settings.scrollback
        if reset {
            t.options.scrollback = scrollback
            t.resetToInitialState()
        } else {
            t.changeScrollback(scrollback)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        processDelegate = ProcessEvents.shared
        // 接受从 Finder 拖入的文件：drop 时插入 shell 转义后的绝对路径（见下方
        // performDragOperation）。与粘贴文件走同一套 shellEscapePath 转义。
        registerForDraggedTypes([.fileURL])
        // ⌘-click 屏幕上的裸文件路径 → 直接打开（目录进文件夹 / 文件用默认 App，见 handleOpenLocalPath）。
        onRequestOpenLocalPath = { [weak self] in self?.handleOpenLocalPath($0) }
        // ⌘-hover 时，能解析为真实文件的裸路径才高亮成链接（下划线 + 手型光标），
        // 让「⌘-点击打开」这一手势可被发现。与打开走同一套解析，能高亮即能点开。
        onResolveLocalPath = { [weak self] in self?.resolveLocalPath($0) != nil }
        usePageKeysForAlternateScrollFallback = { [weak self] in
            guard let self else { return false }
            return SessionStore.shared.sessions.first(where: { $0.id == self.sessionId })?.kind.isAgent == true
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - 文件拖入 → 插入绝对路径

    /// 拖入内容含文件才接收（显示「拷贝」光标），否则不拦截。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    /// 落下：读全部文件 URL，插入 shell 转义后的绝对路径（多文件空格分隔），
    /// 直送 PTY（不加括号粘贴标记，更接近手输路径的预期）。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            return false
        }
        let joined = urls.map { Self.shellEscapePath($0.path) }.joined(separator: " ")
        send(txt: joined)
        window?.makeFirstResponder(self)
        return true
    }

    /// 终端铃声（BEL）：系统提示音 + 非聚焦会话冒泡通知。
    override func bell(source: Terminal) {
        NSSound.beep()
        SessionStore.shared.noteBell(id: sessionId)
    }

    // MARK: - ⌘-click 文件路径 → 访达定位

    /// SwiftTerm 回调来的屏幕明文 token → 解析为绝对路径并在访达中选中。
    /// 覆盖：~ 路径、绝对路径、以及能用实时 cwd 拼出的相对路径；必须真实存在
    /// 才动作，不存在则轻提示（beep）。含空格的路径不在覆盖内。
    private func handleOpenLocalPath(_ raw: String) {
        guard let path = resolveLocalPath(raw) else {
            NSSound.beep()   // 路径不存在/解析不出：给反馈，避免「点了没动静」。
            return
        }
        // 直接打开：目录 → 在访达中进入该文件夹；文件 → 用默认 App 打开。
        // （区别于 activateFileViewerSelecting 的「只在父目录里选中高亮」。）
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 屏幕明文 token → 「确实存在」的绝对路径；解析不出或不存在返回 nil。
    /// ⌘-悬停高亮（onResolveLocalPath）与 ⌘-点击打开（handleOpenLocalPath）共用此口，
    /// 保证「能高亮的」与「点了能开的」完全一致。
    private func resolveLocalPath(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // 去成对包裹符与行尾标点（行尾的 。，；：)]}」 等多是排版，不属于路径）。
        while let f = s.first, "\"'`([{<「『（".contains(f) { s.removeFirst() }
        while let l = s.last, "\"'`)]}>」』），,.;:".contains(l) { s.removeLast() }
        // 去行号后缀（file.swift:42 / file.swift:42:10）→ 定位文件本身。
        s = s.replacingOccurrences(of: #":[0-9]+(?::[0-9]+)?$"#, with: "", options: .regularExpression)
        guard !s.isEmpty else { return nil }

        let absolute: String
        if s == "~" || s.hasPrefix("~/") {
            absolute = (s as NSString).expandingTildeInPath
        } else if s.hasPrefix("/") {
            absolute = s
        } else if let cwd = currentCwd() {
            absolute = (cwd as NSString).appendingPathComponent(s)
        } else {
            return nil
        }
        let path = (absolute as NSString).standardizingPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// 子 shell 实时工作目录（proc_pidinfo，读自己拥有的子进程无需特殊权限）；
    /// 把相对路径拼成绝对路径用。与 SessionStore 的 cwd 采样同源。
    private func currentCwd() -> String? {
        guard let pid = process?.shellPid, pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sz) == sz else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    // RELAY_IO_STATS=1 时的吞吐插桩账本（仅 debug 排障用，热路径零开销门控）。
    static let ioStatsOn = ProcessInfo.processInfo.environment["RELAY_IO_STATS"] == "1"
    static var statChunks = 0
    static var statBytes = 0
    static var statFeedNs: UInt64 = 0
    static var statLedgerNs: UInt64 = 0
    static var statLastPrint: UInt64 = 0

    /// PTY 输出回调（主队列）：先走父类渲染，再喂检测器。
    override func dataReceived(slice: ArraySlice<UInt8>) {
        guard Self.ioStatsOn else {
            super.dataReceived(slice: slice)
            SessionStore.shared.feed(id: sessionId)
            return
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        super.dataReceived(slice: slice)
        let t1 = DispatchTime.now().uptimeNanoseconds
        SessionStore.shared.feed(id: sessionId)
        let t2 = DispatchTime.now().uptimeNanoseconds
        Self.statChunks += 1
        Self.statBytes += slice.count
        Self.statFeedNs += t1 - t0
        Self.statLedgerNs += t2 - t1
        if t2 - Self.statLastPrint > 2_000_000_000 {
            Self.statLastPrint = t2
            FileHandle.standardError.write(Data(
                "[iostat] chunks=\(Self.statChunks) bytes=\(Self.statBytes) feed=\(Self.statFeedNs / 1_000_000)ms ledger=\(Self.statLedgerNs / 1_000_000)ms\n".utf8))
        }
    }

    /// 当前视口的全部行文本（右侧空白已剥）。状态检测每秒扫一帧用。
    /// getLine(row:) 相对 yDisp（视口）——用户滚离底部时读到的是历史，
    /// 调用方需用 scrollPosition 守护。
    func visibleLines() -> [String] {
        let t = getTerminal()
        var out: [String] = []
        out.reserveCapacity(t.rows)
        for r in 0..<t.rows {
            if let line = t.getLine(row: r) {
                out.append(line.translateToString(
                    trimRight: true, skipNullCellsFollowingWide: true, characterProvider: plainCell))
            }
        }
        return out
    }

    /// 整缓冲（回看+屏幕）纯文本快照：行尾空白与尾部空行剥除。
    /// TUI 处于 alternate buffer 时该缓冲无回看，得到的即当前画面帧。
    /// 持久化用：纯文本重启回放不会带出光标定位/屏幕模式残留 —— 原始
    /// 字节流在不同窗口尺寸下回放必然错乱（混排/残影/行内空隙）。
    func snapshotText() -> String {
        let t = getTerminal()
        var rows: [String] = []
        for r in t.scrollInvariantRowRange {
            if let line = t.getScrollInvariantLine(row: r) {
                rows.append(line.translateToString(
                    trimRight: true, skipNullCellsFollowingWide: true, characterProvider: plainCell))
            }
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows.joined(separator: "\n")
    }

    /// 强制全量重绘（标脏可见区 + 重画）。
    func fullRefresh() {
        let t = getTerminal()
        t.refresh(startRow: 0, endRow: t.rows)
        needsDisplay = true
    }

    /// 切会话重新挂载后：滚到最新输出 + 强制全量重绘 + 认领键盘焦点。
    /// detach 期间继续输出时 yDisp 停在旧位置且在屏内容不重绘，
    /// 直接显示会停在历史中间并混入残影行。
    /// 移出窗口（window == nil）时 syncRenderer 会顺带释放 Metal 资源，
    /// 并清掉 IME 组合残留 —— 残留会让 hasMarkedText() 持续为 true，
    /// 重新挂载后输入法拦截所有按键（"切回来无法输入"的另一种形态）。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncRenderer(wantMetal: SessionStore.shared.settings.gpuRender)
        guard window != nil else {
            unmarkText()
            return
        }
        scroll(toPosition: 1.0) // 普通 buffer 滚到底；alternate buffer 无回看为 no-op
        fullRefresh()
        // host() 的异步 makeFirstResponder 在视图尚未入窗时是 no-op；
        // 这里在真正入窗的时机兜底认领，保证切回会话即可打字。
        window?.makeFirstResponder(self)
        pinViewportAfterLayout()
    }

    /// 首次挂载期间会有多次瞬态 resize：初始 800×600 → 真实尺寸，叠加
    /// UpdateBanner 出现的 0.2s 动画。其中某次若把终端压到极矮（可视行数 <
    /// 已输出行数），内容贴底会让 SwiftTerm 的 yBase 抬起；随后增高时
    /// Buffer.resize 的「向上滚」分支便把视口停在缓冲顶部的空行上 —— 表现为
    /// 内容上方约一屏 1/6 的留白，且只在首次打开出现。对策：入窗后分两个时机
    /// 再贴回底部，把空行推出视口。下一 runloop（本轮布局已定）+ 0.3s（覆盖
    /// banner 动画）。普通 buffer 贴底即内容不足一屏时的顶部对齐；alternate
    /// buffer（全屏 TUI）无回看 scroll 为 no-op；已贴底时也是 no-op，零副作用。
    private func pinViewportAfterLayout() {
        let pin: () -> Void = { [weak self] in
            guard let self, self.window != nil else { return }
            self.scroll(toPosition: 1.0)
            self.fullRefresh()
        }
        DispatchQueue.main.async(execute: pin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: pin)
    }
}

/// 进程事件接收器。单独的对象而非 view 自身 —— delegate 协议方法
/// 与 LocalProcessTerminalView 自带的同名 public 方法签名冲突，无法在子类实现。
final class ProcessEvents: LocalProcessTerminalViewDelegate {
    static let shared = ProcessEvents()

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let v = source as? RelayTerminalView else { return }
        SessionStore.shared.onExit(id: v.sessionId, code: exitCode)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// AppKit 容器：终端视图作为子视图以 autoresizingMask 始终铺满容器。
/// SwiftUI 只负责给容器定尺寸；终端的 frame→cols/rows→PTY winsize 同步链
/// 全部走 AppKit 标准路径。直接把缓存的终端实例交给 NSViewRepresentable
/// 时 SwiftUI 的 sizing 不可靠（实测新挂载的终端停留在创建时的 800×600）。
final class TerminalContainer: NSView {
    weak var hosted: RelayTerminalView?

    func host(_ v: RelayTerminalView) {
        guard hosted !== v else { return }
        hosted?.removeFromSuperview()
        hosted = v
        addSubview(v)
        syncFrame()
        DispatchQueue.main.async { [weak v] in
            if let v { v.window?.makeFirstResponder(v) }
        }
    }

    /// 子终端尺寸只跟有效 bounds 同步。SwiftUI makeNSView 阶段容器 bounds
    /// 还是 zero，这时设 frame 会让终端 resize 到 rows=1 —— SwiftTerm 的
    /// Buffer.resize 会按 1 行裁剪回看缓冲（实测三次截断调用栈全在此）。
    /// 不用 autoresizingMask：zero→真实尺寸的差值缩放同样不可靠。
    private func syncFrame() {
        guard let v = hosted, bounds.width > 1, bounds.height > 1 else { return }
        if v.frame != bounds { v.frame = bounds }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        syncFrame()
    }
}

/// 把常驻的 RelayTerminalView 挂进 SwiftUI。终端实例在 SessionStore registry
/// 里保活 —— 切会话只换挂载，buffer 原样保留。
struct TerminalPane: NSViewRepresentable {
    let sessionId: String
    let fontSize: Double

    func makeNSView(context: Context) -> TerminalContainer {
        let c = TerminalContainer()
        if let v = SessionStore.shared.terminalView(for: sessionId) { c.host(v) }
        return c
    }

    func updateNSView(_ c: TerminalContainer, context: Context) {
        // nil = 会话已关闭（残留刷新），什么都不做，容器随后被 SwiftUI 拆除。
        if let v = SessionStore.shared.terminalView(for: sessionId) { c.host(v) }
        if let v = c.hosted {
            // 必须与设置里的 fontName 同源解析 —— 这里曾硬编码
            // monospacedSystemFont，把 applySettings 应用的字体每次刷新
            // 都打回 SF Mono（CJK 字体设置形同虚设，中文字距无法修复）。
            let f = TerminalTheme.font(
                name: SessionStore.shared.settings.fontName, size: CGFloat(fontSize))
            if v.font != f {
                v.font = f
                v.ensureScrollback() // font setter 会把 options 重置回默认
            }
        }
    }
}
