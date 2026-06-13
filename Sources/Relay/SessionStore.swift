// 会话中枢：CRUD / 状态机 / scrollback 持久化 / ticker / 通知。
// 单进程单线程模型：除 ps 快照与磁盘 IO 外全部在主线程，无锁。
import AppKit
import Combine
import Darwin
import SwiftTerm
import UserNotifications

final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published var sessions: [Session] = []
    /// 聚焦会话：侧栏高亮、标题条与 ⌘W/⌘K 等快捷键的作用对象。
    @Published var activeId: String?
    /// 终端区布局：1-2 个会话 id（2 个 = 左右分屏）。
    @Published var panes: [String] = []
    @Published var settings = AppSettings()
    /// ⌘F 搜索条显隐。
    @Published var searchVisible = false
    /// 完成/出错但用户还没回看的会话（侧栏任务行亮点提示，回看即清）。不持久化。
    @Published var unread: Set<String> = []
    /// 按住 ⌘ 时侧栏任务行显示 ⌘1-9 快捷角标（松开即隐）。
    @Published var cmdHeld = false
    /// 系统当前是否暗色（followSystemTheme 用；AppDelegate 监听变化刷新）。
    @Published var systemIsDark = true

    /// 当前生效的终端主题 id：跟随系统时自动配对到当前明暗的对应款，
    /// 否则用 theme 原值。
    var effectiveThemeId: String {
        guard settings.followSystemTheme else { return settings.theme }
        return TerminalTheme.counterpart(of: settings.theme, wantLight: !systemIsDark)
    }

    /// 壳层（侧栏/标签条/设置页）明暗 = 生效终端主题的明暗。
    var shellIsLight: Bool { TerminalTheme.by(id: effectiveThemeId).isLight }

    /// 系统明暗变化入口（AppDelegate 分布式通知回调）。
    func noteSystemAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != systemIsDark else { return }
        systemIsDark = dark
        applySettings()
    }

    func noteCmdHeld(_ held: Bool) {
        if cmdHeld != held { cmdHeld = held }
    }

    /// 每会话检测运行态（不持久化）。必须是引用类型：feed 热路径就地变更。
    /// 值类型“从字典拷出→改→写回”会让 scrollback 在字典与局部各持一份引用，
    /// 每次 append 都触发整缓冲（最大 512KB）COW 复制 —— 200 万行基准实测
    /// 16 秒全烧在这一处 memcpy 上。
    private final class DetState {
        var lastBusy: Date?
        var dirty = false
        var hookSeen = false
        /// 本次运行的进程树是否真的确认过 agent 进程（reclassify 置位）。
        /// 重启恢复的会话 kind 是持久化的旧值，屏上是回放的历史 —— 若仅凭
        /// kind 就扫屏，历史里的 spinner 行会把死会话判成"运行中"（实测
        /// 重启 3 秒即假 running）；停在确认菜单的历史还会假报"需要确认"。
        var kindConfirmed = false
        /// 最近一次 PTY 输出时间 + 沉寂后是否已做过整屏重绘。
        /// agent TUI 收尾时的高频行重写偶发留下半擦除残影（buffer 实测是
        /// 干净的、脏行重绘遗漏）；输出停 2 秒后刷一帧兜底，零持续成本。
        var lastFeed: Date?
        var quietRefreshed = true
        /// 进程已退出：阻止退出瞬间残留的 PTY 输出经 feed 把状态点回 Running。
        var exited = false
        /// 本次进程启动时刻：判定"startProcess 根本没起来就秒退"（坏 $SHELL）。
        var startedAt: Date?
    }

    private var det: [String: DetState] = [:]
    /// 会话 id → 常驻终端视图（创建后保活，切换 tab 不销毁，历史天然保留）。
    private var views: [String: RelayTerminalView] = [:]
    /// 会话 id → 最近读到的子 shell 工作目录（onTick 用 proc_pidinfo 采样，
    /// 不入 @Published 避免每秒触发 SwiftUI 重渲染；落盘时并入 Session.cwd）。
    private var liveCwd: [String: String] = [:]
    /// liveCwd 采样发生变化、尚未落盘：onTick 节流落盘（缩小崩溃/强杀丢失最新
    /// cwd 的窗口，否则采样到的目录只在显式 persistSessions 时才并入磁盘）。
    private var cwdDirty = false
    /// 启动时从磁盘恢复出来的会话 id（区分「恢复」与「本次新建」）：仅对恢复的
    /// agent 会话在重开时预填 resume 命令，首次实体化后即移除。
    private var restoredIds: Set<String> = []
    private var ticker: Timer?
    private var tick: UInt64 = 0
    private var idCounter = 0
    private var notifCounter = 0
    private let scrollbackCap = 256 * 1024
    private(set) var hookServer: HookServer?
    private let ioQueue = DispatchQueue(label: "relay.io", qos: .utility)

    private init() {
        loadPersisted()
        hookServer = HookServer { [weak self] sid, event in
            DispatchQueue.main.async { self?.applyHook(sid, event: event) }
        }
        requestNotificationPermission()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        // 允许系统合并定时器唤醒（降闲置唤醒/能耗；settle 精度 1s±0.3s 足够）。
        ticker?.tolerance = 0.3
    }

    // MARK: - 任务 / 标签页（两级结构：侧栏条目 = 任务，顶部 tab = 任务内标签页）

    /// 会话归属的任务 id（任务根自身 = 自己的 id）。
    func taskId(of id: String) -> String {
        sessions.first(where: { $0.id == id })?.parentId ?? id
    }

    /// 侧栏条目：所有任务根，保持创建顺序。
    var tasks: [Session] { sessions.filter { $0.parentId == nil } }

    /// 某任务的全部标签页（根 + 子，创建顺序）。
    func tabs(ofTask tid: String) -> [Session] {
        sessions.filter { $0.id == tid || $0.parentId == tid }
    }

    // MARK: - 任务重排（侧栏拖拽）

    /// 把任务 sourceId 移到 targetId 之前。仅改变 sessions 数组里任务根的
    /// 相对顺序（子标签页跟随各自任务根，组内/标签页顺序不变；侧栏 groups
    /// 按 group 聚合，跨组拖拽不会拆散分组，只影响显示先后）。拖动过程频繁
    /// 触发，只做内存重排刷新 UI；落盘留给 commitTaskOrder（拖放结束一次）。
    func moveTask(_ sourceId: String, before targetId: String) {
        guard sourceId != targetId else { return }
        var order = tasks.map { $0.id }
        guard let from = order.firstIndex(of: sourceId) else { return }
        order.remove(at: from)
        guard let to = order.firstIndex(of: targetId) else { return }
        order.insert(sourceId, at: to)
        rebuildSessions(byTaskOrder: order)
    }

    /// 按任务顺序重建 sessions：每个任务根后紧跟其子标签页（各自相对顺序
    /// 不变）。不在 order 内的会话（理论不存在）补到末尾，绝不丢会话。
    private func rebuildSessions(byTaskOrder order: [String]) {
        var rebuilt: [Session] = []
        rebuilt.reserveCapacity(sessions.count)
        for tid in order {
            for s in sessions where s.id == tid || s.parentId == tid {
                rebuilt.append(s)
            }
        }
        if rebuilt.count != sessions.count {
            let kept = Set(rebuilt.map { $0.id })
            rebuilt.append(contentsOf: sessions.filter { !kept.contains($0.id) })
        }
        sessions = rebuilt
    }

    /// 拖放结束：把当前任务顺序落盘。
    func commitTaskOrder() { persistSessions() }

    /// 当前聚焦标签页所在任务的标签页列表（TabStrip 数据源）。
    var activeTabs: [Session] {
        guard let a = activeId else { return [] }
        return tabs(ofTask: taskId(of: a))
    }

    /// 每任务记住最后聚焦的标签页，侧栏切任务时回到上次位置（不持久化）。
    private var lastTabByTask: [String: String] = [:]

    // MARK: - 会话生命周期

    private func makeSession(parentId: String?) -> Session {
        idCounter += 1
        let id = "s\(Int(Date().timeIntervalSince1970 * 1000))-\(idCounter)"
        var s = Session(
            id: id, kind: .shell, name: WindowType.shell.label,
            group: WindowType.shell.group(host: nil), host: nil,
            createdAt: Date().timeIntervalSince1970
        )
        s.status = .idle
        s.parentId = parentId
        // 新建标签页/分屏（隶属已有任务）：继承当前聚焦标签的工作目录，新标签
        // 与同任务其他标签起在同一项目目录而非 home。新建独立任务（parentId
        // == nil）不继承，保持从 home 起步。
        if parentId != nil { s.cwd = activeCwd() }
        sessions.append(s)
        return s
    }

    /// 当前聚焦会话的工作目录（实时采样优先，回落上次落盘值；目录须仍存在）。
    private func activeCwd() -> String? {
        guard let sid = activeId else { return nil }
        if let live = liveCwd[sid], isUsableDir(live) { return live }
        if let saved = sessions.first(where: { $0.id == sid })?.cwd, isUsableDir(saved) { return saved }
        return nil
    }

    /// 新建任务（侧栏新条目，自带第一个标签页）。
    @discardableResult
    func newTask() -> Session {
        let s = makeSession(parentId: nil)
        show(s.id)
        persistSessions()
        return s
    }

    /// 当前任务内新建标签页（⌘T / TabStrip 的 +）。没有任务时等价于新建任务。
    @discardableResult
    func newTab() -> Session {
        guard let a = activeId else { return newTask() }
        let s = makeSession(parentId: taskId(of: a))
        show(s.id)
        persistSessions()
        return s
    }

    /// 关闭单个标签页（TabStrip 的 × / ⌘W）。
    /// 关任务根时把第一个子标签页提升为新根，任务不消失；没有子页则整任务关闭。
    func close(_ id: String) {
        // 关闭后焦点应回到的任务：提升出的新根 > 所属任务（关子页时）> 兜底最后一个任务。
        var survivorTid: String?
        let tid = taskId(of: id)
        if tid != id { survivorTid = tid }
        let children = sessions.indices.filter { sessions[$0].parentId == id }
        if let first = children.first {
            let newRoot = sessions[first].id
            for i in children { sessions[i].parentId = sessions[i].id == newRoot ? nil : newRoot }
            survivorTid = newRoot
        }
        destroy(id)
        lastTabByTask.removeValue(forKey: id)
        refocusAfterClose(preferTask: survivorTid)
        persistSessions()
    }

    /// 关闭整个任务及其全部标签页（侧栏的 ×）。
    func closeTask(_ tid: String) {
        for t in tabs(ofTask: tid) { destroy(t.id) }
        lastTabByTask.removeValue(forKey: tid)
        refocusAfterClose(preferTask: nil)
        persistSessions()
    }

    /// 关闭前确认（⌘W / 标签 × / 任务 × 的统一入口）。关闭是破坏性操作：
    /// 进程被终止、回看历史删除且不可恢复，所以一律先弹确认。
    func confirmClose(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        confirmDestructive(
            title: "关闭标签页「\(s.name)」？",
            info: "标签页内的进程将被终止，回看历史将被删除。"
        ) { [weak self] in self?.close(id) }
    }

    func confirmCloseTask(_ tid: String) {
        guard let root = sessions.first(where: { $0.id == tid }) else { return }
        let n = tabs(ofTask: tid).count
        confirmDestructive(
            title: "关闭任务「\(root.name)」？",
            info: n > 1
                ? "任务下的 \(n) 个标签页将一并关闭，进程终止、回看历史删除。"
                : "任务内的进程将被终止，回看历史将被删除。"
        ) { [weak self] in self?.closeTask(tid) }
    }

    private func confirmDestructive(title: String, info: String, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "取消") // 标题为「取消」自动绑定 Esc
        if let w = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: w) { resp in
                if resp == .alertFirstButtonReturn { onConfirm() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            onConfirm()
        }
    }

    /// 释放单个会话的所有资源（视图/进程/检测态/磁盘历史），不处理层级与焦点。
    private func destroy(_ id: String) {
        if let v = views.removeValue(forKey: id) {
            v.process?.terminate()
            v.removeFromSuperview()
        }
        det.removeValue(forKey: id)
        sessions.removeAll { $0.id == id }
        unread.remove(id)
        try? FileManager.default.removeItem(at: DataDir.scrollbackFile(id))
        panes.removeAll { $0 == id }
    }

    /// 聚焦会话被关掉后重新落焦：分屏另一侧还在就聚焦它；
    /// 否则去目标任务（记忆的标签页优先），最后兜底最后一个任务。
    private func refocusAfterClose(preferTask: String?) {
        if let a = activeId, sessions.contains(where: { $0.id == a }) { return }
        if let p = panes.first {
            activeId = p
            return
        }
        activeId = nil
        guard let t = preferTask ?? tasks.last?.id else { return }
        let candidates = tabs(ofTask: t)
        let remembered = lastTabByTask[t]
        if let target = candidates.first(where: { $0.id == remembered })?.id ?? candidates.first?.id {
            show(target)
        }
    }

    /// 任务行是否有未回看的完成/出错标签页（侧栏亮点）。
    func hasUnread(taskOf tid: String) -> Bool {
        tabs(ofTask: tid).contains { unread.contains($0.id) }
    }

    /// 用户回看了某任务：清掉整个任务的未读亮点（亮点挂在任务行上）。
    private func clearUnread(task tid: String) {
        let ids = Set(tabs(ofTask: tid).map(\.id))
        if !unread.isDisjoint(with: ids) { unread.subtract(ids) }
    }

    /// 在聚焦 pane 显示某标签页（TabStrip 点击/新建后调用）。
    /// 该会话已在另一 pane 时只移焦点，不动布局。
    func show(_ id: String) {
        clearUnread(task: taskId(of: id))
        lastTabByTask[taskId(of: id)] = id
        if panes.contains(id) {
            activeId = id
            focusActiveTerminal()
            return
        }
        let focusIdx = panes.firstIndex(of: activeId ?? "") ?? 0
        if panes.isEmpty {
            panes = [id]
        } else {
            panes[min(focusIdx, panes.count - 1)] = id
        }
        activeId = id
        focusActiveTerminal()
    }

    /// 把键盘焦点交还当前会话的终端视图。会话已挂载且 pane 不变时
    /// TerminalContainer.host() 直接 return、viewDidMoveToWindow 也不触发
    /// —— 点过侧栏/工具条后焦点留在别处，回到会话页面就打不进字。
    /// 延迟一拍等 SwiftUI 完成本轮重布局；视图未入窗时为 no-op（重新
    /// 挂载路径由 viewDidMoveToWindow 兜底认领焦点）。
    func focusActiveTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = self.activeId, let v = self.views[id],
                  let w = v.window else { return }
            if w.firstResponder !== v { w.makeFirstResponder(v) }
        }
    }

    /// 侧栏点击任务：回到该任务上次聚焦的标签页（没记忆则根标签页）。
    func showTask(_ tid: String) {
        let candidates = tabs(ofTask: tid)
        guard !candidates.isEmpty else { return }
        let remembered = lastTabByTask[tid]
        show(candidates.first(where: { $0.id == remembered })?.id ?? candidates[0].id)
    }

    /// 分屏方向：right 左右分屏（HSplitView），down 上下分屏（VSplitView）；
    /// 新 pane 一律加在聚焦 pane 之后。
    enum SplitDirection { case right, down }

    /// 当前分屏轴向（true = 上下分屏）。单 pane 时无意义。
    @Published var splitVertical = false

    /// ⌘D / 工具条分屏：开新会话（归属当前任务）。已分屏时不再分（MVP 最多两个 pane）。
    func splitActive(_ dir: SplitDirection = .right) {
        guard panes.count < 2 else { return }
        let s = makeSession(parentId: activeId.map { taskId(of: $0) })
        splitVertical = dir == .down
        panes.append(s.id)
        activeId = s.id
        lastTabByTask[taskId(of: s.id)] = s.id
        persistSessions()
    }

    /// ⌘⇧D 取消分屏：只留聚焦 pane（另一侧会话保活，可从侧栏再打开）。
    func unsplit() {
        guard panes.count > 1, let a = activeId, panes.contains(a) else {
            if let f = panes.first { panes = [f] }
            return
        }
        panes = [a]
    }

    /// 终端视图拿到键盘焦点（点击分屏 pane）→ 活动会话跟随。
    func noteFocused(id: String) {
        if activeId != id, sessions.contains(where: { $0.id == id }) {
            activeId = id
            lastTabByTask[taskId(of: id)] = id
            clearUnread(task: taskId(of: id))
        }
    }

    /// 终端铃声：非聚焦会话走系统通知（聚焦会话已有系统提示音，不再打扰）。
    func noteBell(id: String) {
        guard id != activeId, let s = sessions.first(where: { $0.id == id }) else { return }
        postSystemNotification(title: "\(s.name) 响铃", body: "\(s.group) · 终端 BEL", taskId: taskId(of: id))
    }

    // MARK: - 菜单/快捷键动作

    var activeView: RelayTerminalView? { activeId.flatMap { views[$0] } }

    /// RELAY_DEBUG 排障入口用：只读暴露常驻视图表（relay.dump 转储 cols/rows）。
    var debugViews: [String: RelayTerminalView] { views }

    func closeActive() {
        if let id = activeId { confirmClose(id) }
    }

    /// 切到当前任务的上/下一个标签页（⌘⇧[ / ⌘⇧]，循环）。
    func cycle(_ delta: Int) {
        let tabs = activeTabs
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex(where: { $0.id == activeId }) ?? 0
        show(tabs[(i + delta + tabs.count) % tabs.count].id)
    }

    /// ⌘1-9 直达侧栏第 n 个任务（按住 ⌘ 时任务行显示对应角标）。
    func selectTask(index: Int) {
        guard tasks.indices.contains(index) else { return }
        showTask(tasks[index].id)
    }

    /// 终端字号缩放（⌘+/⌘-/⌘0 回默认值，与 AppSettings 默认保持同源）。
    func zoom(_ delta: Double) {
        settings.fontSize = delta == 0 ? AppSettings().fontSize : min(28, max(9, settings.fontSize + delta))
        applySettings()
    }

    /// 把当前设置（主题/字体族/字号）应用到全部常驻终端视图并持久化。
    func applySettings() {
        let theme = TerminalTheme.by(id: effectiveThemeId)
        // 行高/字距补丁是静态量，必须先设好 —— 随后 apply 里的 font setter
        // 会触发 computeFontDimensions 重算（setter 无相等守卫）。
        RelayTerminalView.cellHeightAdjustment = CGFloat(settings.lineSpacing)
        RelayTerminalView.cellWidthAdjustment = CGFloat(settings.letterSpacing)
        for v in views.values {
            theme.apply(to: v, fontSize: settings.fontSize, fontName: settings.fontName,
                        bgAlpha: settings.bgOpacity)
            // 设字体重置了 options；不 reset（保留画面），容量随下次重建生效。
            v.ensureScrollback()
            v.syncRenderer(wantMetal: settings.gpuRender)
            v.applyCursorStyle(shape: settings.cursorShape, blink: settings.cursorBlink)
            v.fullRefresh()
        }
        (NSApp.delegate as? AppDelegate)?.applyWindowChrome(
            opacity: settings.bgOpacity, blur: settings.bgBlur)
        let snapshot = settings
        ioQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: DataDir.settingsFile, options: .atomic)
            }
        }
    }

    func rename(_ id: String, to name: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        sessions[i].name = t
        persistSessions()
    }

    /// 取（或创建）会话的常驻终端视图。首次创建时起 shell 并回放磁盘历史。
    /// 会话已不存在时返回 nil —— 关闭会话后 SwiftUI 残留的一次刷新会带旧 id
    /// 进来，若照常创建会拉起一个永不可见的孤儿 shell（进程/内存/磁盘三漏；
    /// 实测关 5 个会话 5 个全复活，退出时还把已删的快照文件写回磁盘）。
    func terminalView(for id: String) -> RelayTerminalView? {
        if let v = views[id] { return v }
        guard sessions.contains(where: { $0.id == id }) else { return nil }
        let v = RelayTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        v.sessionId = id
        // agent TUI 每个同步块结束都全屏标脏，行级顶点缓存（默认模式）此时
        // 全部失效反成开销；perFrameAggregated 每帧聚合一个 buffer，官方
        // 推荐给"每帧重绘大半屏"的全屏 TUI 负载。
        v.metalBufferingMode = .perFrameAggregated
        RelayTerminalView.cellHeightAdjustment = CGFloat(settings.lineSpacing)
        RelayTerminalView.cellWidthAdjustment = CGFloat(settings.letterSpacing)
        TerminalTheme.by(id: effectiveThemeId)
            .apply(to: v, fontSize: settings.fontSize, fontName: settings.fontName,
                   bgAlpha: settings.bgOpacity)
        // 必须在主题（含字体）应用之后：设字体会整体重置 options。
        // 此时还没喂任何数据，reset 重建 buffer 让容量立即生效，零副作用。
        v.ensureScrollback(reset: true)
        v.applyCursorStyle(shape: settings.cursorShape, blink: settings.cursorBlink)
        views[id] = v

        // 回放上次的历史（纯文本快照，不进入检测累计）。纯文本在任何窗口
        // 尺寸下回放都干净；原始字节流带光标定位/屏幕模式，跨尺寸回放必然
        // 混排错乱。
        let ds = DetState()
        if let hist = try? Data(contentsOf: DataDir.scrollbackFile(id)), !hist.isEmpty {
            let text = String(decoding: hist, as: UTF8.self)
            if !text.isEmpty {
                let body = text.replacingOccurrences(of: "\n", with: "\r\n")
                v.feed(text: body + "\r\n\u{1b}[2m── 以上为历史会话 ──\u{1b}[0m\r\n")
            }
        }
        det[id] = ds

        var env = ProcessInfo.processInfo.environment
        // 剔除宿主终端注入的变量：如 cmux 的 PROMPT_COMMAND 指向仅宿主里
        // 存在的 shell 函数，子 shell 每个提示符都会报 command not found。
        for k in ["PROMPT_COMMAND", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
                  "ITERM_SESSION_ID", "ITERM_PROFILE", "TMUX", "TMUX_PANE", "STY",
                  "INSIDE_EMACS", "VSCODE_INJECTION", "WEZTERM_PANE", "KITTY_WINDOW_ID"] {
            env.removeValue(forKey: k)
        }
        env = env.filter { !$0.key.lowercased().hasPrefix("_cmux") && !$0.key.lowercased().hasPrefix("cmux") }
        env["TERM_PROGRAM"] = "Relay"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["CLICOLOR"] = "1"
        if env["LANG"] == nil { env["LANG"] = "zh_CN.UTF-8" }
        env["RELAY_SESSION"] = id
        if let hs = hookServer, let url = hs.baseURL {
            env["RELAY_HOOK_URL"] = "\(url)/hook?s=\(id)"
            env["RELAY_HOOK_TOKEN"] = hs.token
        }
        let shell = env["SHELL"] ?? "/bin/zsh"
        ds.startedAt = Date()
        // 工作目录恢复：本会话落盘/实时 cwd 优先；缺失则借同任务其他标签页的
        // 可用目录（同项目下各标签目录一致）；最后才回落 home。
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let session = sessions.first(where: { $0.id == id })
        let startDir = resolveStartDir(for: id) ?? home
        v.startProcess(
            executable: shell, args: ["-l"],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: nil, currentDirectory: startDir
        )
        // 恢复出来的 agent 会话：在提示符上预填 resume 命令（不回车，用户按
        // Enter 即恢复）。仅对从磁盘恢复的会话触发一次；新建的 claude/codex
        // 不预填。延迟一拍等 shell -l 打出提示符，避免预填字被启动输出顶乱。
        if restoredIds.remove(id) != nil,
           let kind = session?.kind, let cmd = resumeCommand(for: kind) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak v] in
                v?.send(txt: cmd)
            }
        }
        return v
    }

    /// 路径存在且是目录（恢复 cwd 前校验，目录被删/改名则回落 home）。
    private func isUsableDir(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 恢复 shell 的起始目录：本会话落盘 cwd / 实时采样优先；缺失则借同任务
    /// 其他标签页的可用目录（同项目下各标签目录一致）；都没有返回 nil（调用
    /// 方回落 home）。修复「采样未及落盘 + 崩溃 → 恢复起在 home」的缺口。
    private func resolveStartDir(for id: String) -> String? {
        if let c = sessions.first(where: { $0.id == id })?.cwd, isUsableDir(c) { return c }
        if let c = liveCwd[id], isUsableDir(c) { return c }
        for t in tabs(ofTask: taskId(of: id)) where t.id != id {
            if let c = liveCwd[t.id], isUsableDir(c) { return c }
            if let c = t.cwd, isUsableDir(c) { return c }
        }
        return nil
    }

    /// 恢复 agent 会话时预填的 resume 命令（不含回车）。
    private func resumeCommand(for kind: WindowType) -> String? {
        switch kind {
        case .claude: return "claude --continue"
        case .codex: return "codex resume --last"
        default: return nil
        }
    }

    /// 读子 shell 当前工作目录（proc_pidinfo / PROC_PIDVNODEPATHINFO，无需 shell
    /// 配合 OSC 7）。对自己拥有的子进程无需特殊权限。
    private func processCwd(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sz) == sz else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - 输出喂入（RelayTerminalView.dataReceived，主线程）

    /// 热路径：agent TUI 每秒重绘几十次、高吞吐时每秒数千块。这里只记
    /// 时间戳/脏标记，不碰字节内容 —— 持久化走 flush 时的整缓冲文本快照，
    /// 状态检测在 onTick 里按秒扫屏幕（见 Detector 头注释）。
    func feed(id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard let ds = det[id] else { return }
        // 进程已退出：退出与最后一批 PTY 输出几乎同时到达，残留输出不应把
        // 刚结束的会话从 Done 点回 Running（侧栏状态抖动）。
        if ds.exited { return }

        ds.dirty = true
        ds.lastFeed = Date()
        ds.quietRefreshed = false

        // 普通 shell：有输出即 Working，沉寂后由 onTick 收回 Idle。
        let s = sessions[i]
        if !ds.hookSeen, !s.kind.isAgent {
            ds.lastBusy = Date()
            if s.status == .idle || s.status == .done {
                applyStatus(id, .running, nil)
            }
        }
    }

    /// shell 进程退出（delegate 回调）。
    func onExit(id: String, code: Int32?) {
        let ds = det[id]
        ds?.dirty = false
        ds?.lastBusy = nil
        ds?.exited = true // 退出后残留输出不再点亮状态（见 feed）
        if let v = views[id] {
            saveScrollback(id, snapshotData(of: v))
        }
        let failed = (code ?? 1) != 0
        // 进程在视图创建后极短时间内异常退出 = startProcess 没真正起来
        //（如 $SHELL 指向坏路径）。清掉死视图与检测态，让下次点开重建，
        // 否则 terminalView(for:) 永远返回这个黑屏死视图、会话彻底坏死。
        // 正常用过的 shell（存活超过阈值）即便非零退出也保留，用户可能想
        // 看最后的输出。历史快照仍在磁盘，重建时会回放。
        if failed, let started = ds?.startedAt, Date().timeIntervalSince(started) < 1.5 {
            views[id]?.removeFromSuperview()
            views.removeValue(forKey: id)
            det.removeValue(forKey: id)
        }
        let st: SessionStatus = (code ?? 0) == 0 ? .done : .error
        applyStatus(id, st, nil)
    }

    // MARK: - hook 权威状态（来自 HookServer）

    private func applyHook(_ sid: String, event: String) {
        guard sessions.contains(where: { $0.id == sid }) else { return }
        let ds = det[sid] ?? DetState()
        det[sid] = ds
        ds.hookSeen = true
        let mapped: (SessionStatus, Phase?)?
        switch event {
        case "working": ds.lastBusy = Date(); mapped = (.running, .working)
        case "thinking": ds.lastBusy = Date(); mapped = (.running, .thinking)
        case "waiting", "notify": mapped = (.waiting, nil)
        case "done", "idle", "stop": mapped = (.done, nil)
        case "start", "end": mapped = (.idle, nil)
        default: mapped = nil
        }
        if let (st, ph) = mapped { applyStatus(sid, st, ph) }
    }

    // MARK: - ticker：结算 / 类型识别 / 增量落盘

    private func onTick() {
        tick += 1
        let now = Date()
        // agent 状态：每秒扫一帧当前屏幕（差量渲染的 TUI 在输出流里抓不到
        // 关键词，屏幕内容才是真相 —— 见 Detector 头注释）。
        // 仅扫「最近 5 秒有输出 或 正在运行」的会话，闲置会话零成本。
        for (id, ds) in det {
            guard let s = sessions.first(where: { $0.id == id }),
                  s.kind.isAgent, ds.kindConfirmed, !ds.hookSeen, let v = views[id] else { continue }
            let recentOutput = ds.lastFeed.map { now.timeIntervalSince($0) < 5 } ?? false
            guard recentOutput || s.status == .running else { continue }
            // 用户滚离底部时视口是历史内容，冻结判定，避免把运行中误判为完成。
            if v.canScroll && v.scrollPosition < 0.99 { continue }
            let sig = Detector.scan(v.visibleLines())
            if sig.waiting {
                applyStatus(id, .waiting, nil)
            } else if sig.busy {
                det[id]?.lastBusy = now
                applyStatus(id, .running, sig.thinking ? .thinking : .working)
            } else if s.status == .waiting {
                // 菜单已撤（用户确认或取消）：转入运行态，spinner 没接上就由
                // settle 在 2.5 秒后收尾成 Done，避免状态卡在「等待确认」。
                det[id]?.lastBusy = now
                applyStatus(id, .running, .working)
            }
        }
        // 输出沉寂 settle：agent → Done（任务完成）；普通 shell → Idle
        // （回到提示符不是"完成"，不该一直挂 Working，也不发通知）。
        // hook 权威的会话等 hook，不做启发式收尾。
        for (id, ds) in det {
            guard let s = sessions.first(where: { $0.id == id }),
                  !ds.hookSeen, s.status == .running,
                  let lb = ds.lastBusy, now.timeIntervalSince(lb) > Detector.settleSeconds
            else { continue }
            det[id]?.lastBusy = nil
            applyStatus(id, s.kind.isAgent ? .done : .idle, nil)
        }
        // 输出沉寂 2 秒后整屏重绘一帧：清掉 agent TUI 收尾偶发的渲染残影。
        for (id, ds) in det where !ds.quietRefreshed {
            guard let lf = ds.lastFeed, Date().timeIntervalSince(lf) > 2 else { continue }
            det[id]?.quietRefreshed = true
            views[id]?.fullRefresh()
        }
        // 采样各活动会话的工作目录（退出时并入 Session.cwd 落盘，重开恢复）。
        // proc_pidinfo 读自己子进程很便宜，无需 shell 发 OSC 7。
        for (id, v) in views {
            guard v.process?.running == true,
                  let dir = processCwd(pid: v.process?.shellPid ?? 0) else { continue }
            if liveCwd[id] != dir { liveCwd[id] = dir; cwdDirty = true }
        }
        // ps 全表 fork+exec 不便宜：5s 一次足以跟上 claude/ssh 的启停。
        if tick % 5 == 0 { reclassifyTypes() }
        if tick % 5 == 2 { flushDirtyScrollback() }
        // 采样到的工作目录有变更：节流落盘（≤5s），避免崩溃/强杀丢失最新 cwd。
        if tick % 5 == 3, cwdDirty { cwdDirty = false; persistSessions() }
    }

    /// 进程树类型识别（ps 在后台队列跑，主线程应用结果）。
    private func reclassifyTypes() {
        let live: [(String, pid_t)] = views.compactMap { id, v in
            let pid = v.process?.shellPid ?? 0
            return pid > 0 ? (id, pid) : nil
        }
        guard !live.isEmpty else { return }
        ioQueue.async { [weak self] in
            let table = ProcTable.snapshot()
            let results = live.map { ($0.0, table.classify(root: $0.1), table.sshHost(root: $0.1)) }
            DispatchQueue.main.async { self?.applyReclassify(results) }
        }
    }

    private func applyReclassify(_ results: [(String, WindowType, String?)]) {
        var changed = false
        for (id, kind, host) in results {
            guard let i = sessions.firstIndex(where: { $0.id == id }) else { continue }
            // 与 kind 是否变化无关的检测态维护：
            // kindConfirmed —— 本次运行的进程树真看到 agent 才允许扫屏
            //（恢复会话 kind 是旧值、屏上是回放历史，不确认就扫必出假状态）；
            // hookSeen —— 树上不是 claude 就复位，否则 claude 退出后该会话
            // 此后跑 codex/普通命令的状态检测全部失效（feed/onTick 都被挡）。
            if let ds = det[id] {
                ds.kindConfirmed = kind.isAgent
                if kind != .claude { ds.hookSeen = false }
            }
            guard sessions[i].kind != kind else { continue }
            let wasAgent = sessions[i].kind.isAgent
            sessions[i].kind = kind
            sessions[i].host = kind == .ssh ? host : nil
            sessions[i].group = kind.group(host: sessions[i].host)
            // 名字还是任意默认名（shell/claude/...）就跟随新类型；只比对上一个
            // kind 的 label 会在快速启停（claude 起→退→再起）的中间态漏改，
            // 出现 kind=claude 但名字还叫 shell 的脱节。用户自定义名不动。
            // 降级（agent 进程退出/重启恢复回 shell）保留原名 —— codex 任务
            // 重启后不该在侧栏变成"shell"失去身份。
            let isDowngrade = wasAgent && !kind.isAgent
            if !isDowngrade, Set(WindowType.allCases.map(\.label)).contains(sessions[i].name) {
                sessions[i].name = kind.label
            }
            // agent 退出降级后扫屏停了，残留的"等待确认"没人收尾，就地归 idle
            //（running 由 settle 收，waiting 原来会永久卡住）。
            if isDowngrade, sessions[i].status == .waiting {
                applyStatus(id, .idle, nil)
            }
            changed = true
        }
        if changed { persistSessions() }
    }

    private func flushDirtyScrollback() {
        for (id, ds) in det where ds.dirty {
            ds.dirty = false
            guard let v = views[id] else { continue }
            saveScrollback(id, snapshotData(of: v))
        }
    }

    // MARK: - 状态应用 + 通知

    private func applyStatus(_ id: String, _ status: SessionStatus, _ phase: Phase?) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let prev = sessions[i].status
        guard prev != status || sessions[i].phase != phase else { return }
        sessions[i].status = status
        sessions[i].phase = phase
        persistSessions()
        // 非聚焦会话完成/出错 → 侧栏未读亮点（聚焦中的会话用户正看着，不标）。
        let finished = (status == .done && (prev == .running || prev == .waiting)) || status == .error
        if finished, id != activeId { unread.insert(id) }
        maybeNotify(sessions[i], prev: prev, now: status)
    }

    private func maybeNotify(_ s: Session, prev: SessionStatus, now: SessionStatus) {
        let pair: (String, String)?
        switch now {
        case .done where prev == .running || prev == .waiting:
            pair = ("\(s.name) 已完成", "\(s.group) · 任务结束")
        case .waiting where prev != .waiting:
            pair = ("\(s.name) 需要确认", "\(s.group) · 等待你的操作")
        case .error:
            pair = ("\(s.name) 出错", s.group)
        default:
            pair = nil
        }
        guard let (title, sub) = pair else { return }
        postSystemNotification(title: title, body: sub, taskId: taskId(of: s.id))
    }

    /// 系统通知中心（应用内不再弹浮层角标）。
    /// 裸二进制（无 bundle id）下 UNUserNotificationCenter 会崩，须守护。
    /// taskId 写入 userInfo，供点击通知时跳回对应任务（见 AppDelegate 代理）。
    private func postSystemNotification(title: String, body: String, taskId: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        notifCounter += 1
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let taskId { content.userInfo = ["task": taskId] }
        let req = UNNotificationRequest(identifier: "n\(notifCounter)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - 持久化

    private func loadPersisted() {
        if let data = try? Data(contentsOf: DataDir.settingsFile),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        }
        guard let data = try? Data(contentsOf: DataDir.sessionsFile),
              var list = try? JSONDecoder().decode([Session].self, from: data) else { return }
        // 重启后进程都没了：状态归 idle，点开时重启 shell 并回放历史。
        for i in list.indices {
            list[i].status = .idle
            list[i].phase = nil
        }
        sessions = list
        restoredIds = Set(list.map { $0.id }) // 这批是恢复的，agent 会话重开预填 resume
        for s in list where s.cwd != nil { liveCwd[s.id] = s.cwd } // 落盘前先沿用上次目录
        activeId = list.last?.id
        if let a = activeId { panes = [a] }
        persistSessions() // 归位后的状态立即落盘，避免磁盘上残留旧 running 状态
    }

    /// 落盘前把最近采样到的工作目录并入会话快照（liveCwd 不入 @Published）。
    private func sessionsForPersist() -> [Session] {
        sessions.map { s in
            guard let dir = liveCwd[s.id] else { return s }
            var c = s
            c.cwd = dir
            return c
        }
    }

    func persistSessions() {
        let snapshot = sessionsForPersist()
        ioQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: DataDir.sessionsFile, options: .atomic)
            }
        }
    }

    private func saveScrollback(_ id: String, _ data: Data) {
        ioQueue.async {
            try? data.write(to: DataDir.scrollbackFile(id), options: .atomic)
        }
    }

    /// 终端文本快照 → 持久化字节（超限截尾，按行边界对齐）。主线程调用。
    private func snapshotData(of v: RelayTerminalView) -> Data {
        var data = Data(v.snapshotText().utf8)
        if data.count > scrollbackCap {
            data.removeFirst(data.count - scrollbackCap)
            if let nl = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex...nl)
            }
        }
        return data
    }

    /// 退出前同步落盘全部会话缓冲（applicationWillTerminate 调用）。
    func persistAllScrollback() {
        for (id, v) in views {
            // 退出前最后采样一次工作目录，确保落盘的是最新位置。
            if v.process?.running == true, let dir = processCwd(pid: v.process?.shellPid ?? 0) {
                liveCwd[id] = dir
            }
            try? snapshotData(of: v).write(to: DataDir.scrollbackFile(id), options: .atomic)
        }
        if let data = try? JSONEncoder().encode(sessionsForPersist()) {
            try? data.write(to: DataDir.sessionsFile, options: .atomic)
        }
    }
}
