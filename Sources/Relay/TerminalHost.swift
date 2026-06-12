// SwiftTerm 终端视图桥接：原生渲染（CoreText），无 WebView。
// RelayTerminalView 在数据回调处旁路一份给检测器；TerminalPane 把
// SessionStore 里的常驻视图实例挂进 SwiftUI 层级（切 tab 不销毁，历史保留）。
import AppKit
import SwiftUI
import SwiftTerm

/// 缓冲格子 → 纯文本字符。TUI 用光标跳跃绘制时跳过的格子是 NUL（code 0），
/// getCharacter() 原样返回 U+0000 —— 写进快照回放会被解析器丢弃（单词粘连），
/// 进检测/搜索会让含空格的关键词匹配失败。统一映射为空格。
let plainCell: (CharData) -> Character = { $0.isNull ? " " : $0.getCharacter() }

final class RelayTerminalView: LocalProcessTerminalView {
    var sessionId = ""

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
        t.options.scrollback = SessionStore.shared.settings.scrollback
        if reset { t.resetToInitialState() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        processDelegate = ProcessEvents.shared
        // 接受从 Finder 拖入的文件：drop 时插入 shell 转义后的绝对路径（见下方
        // performDragOperation）。与粘贴文件走同一套 shellEscapePath 转义。
        registerForDraggedTypes([.fileURL])
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
