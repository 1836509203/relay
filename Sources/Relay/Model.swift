// 数据模型 —— 与 Rust 版 model.rs 同构（会话/类型/状态/设置）。
import Foundation

enum WindowType: String, Codable, CaseIterable {
    case shell, claude, codex, ssh

    var isAgent: Bool { self == .claude || self == .codex }

    /// 类型短标签 / 自动默认会话名。
    var label: String { rawValue }

    /// 侧栏分组标题（Local / Claude Code / Codex / SSH·主机）。
    func group(host: String?) -> String {
        switch self {
        case .shell: return "Local"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .ssh:
            if let h = host, !h.trimmingCharacters(in: .whitespaces).isEmpty {
                let bare = h.split(separator: "@").last.map(String.init) ?? h
                return "SSH · \(bare)"
            }
            return "SSH"
        }
    }
}

enum SessionStatus: String, Codable {
    case running, waiting, done, error, idle
}

enum Phase: String, Codable {
    case thinking, working
}

struct Session: Identifiable, Codable, Equatable {
    var id: String
    var kind: WindowType
    var name: String
    var group: String
    var host: String?
    var status: SessionStatus = .idle
    var phase: Phase?
    var createdAt: Double
    /// 两级结构：nil = 任务（侧栏条目/首个标签页）；非 nil = 该任务下的附加标签页。
    /// Optional 字段旧版 sessions.json 缺 key 时自动解码为 nil，无需手写容错。
    var parentId: String?
    /// 上次的工作目录（proc_pidinfo 读子 shell cwd 落盘）；重开时在此目录启动
    /// shell。旧版 sessions.json 缺此 key → nil → 回落 home。
    var cwd: String?
}

/// 侧栏显示用的派生阶段。
enum DisplayPhase: String {
    case thinking, working, waiting, done, idle, error
}

func phaseOf(_ s: Session) -> (key: DisplayPhase, label: String) {
    switch s.status {
    case .waiting: return (.waiting, "Waiting")
    case .running:
        if s.kind.isAgent, s.phase == .thinking { return (.thinking, "Thinking") }
        return (.working, "Working")
    case .done: return (.done, "Done")
    case .error: return (.error, "Failed")
    case .idle: return (.idle, "Idle")
    }
}

/// 侧栏任务行的聚合显示：取「最值得用户注意」的标签页代表整个任务。
/// 优先级 = 出错 > 等输入 > 思考 > 工作 > 完成 > 空闲；同级时 agent 标签页优先
/// （第一个标签页跑 claude、第二个开 shell 看日志时，任务应显示 claude 的状态）。
func representativeTab(of tabs: [Session]) -> Session? {
    let rank: [DisplayPhase: Int] = [.error: 0, .waiting: 1, .thinking: 2, .working: 3, .done: 4, .idle: 5]
    return tabs.min { a, b in
        let ra = rank[phaseOf(a).key] ?? 9, rb = rank[phaseOf(b).key] ?? 9
        if ra != rb { return ra < rb }
        if a.kind.isAgent != b.kind.isAgent { return a.kind.isAgent }
        return a.createdAt < b.createdAt
    }
}

struct AppSettings: Codable {
    /// 默认 12：claude 等 agent TUI 的状态条按终端列数自适应（≥~115 列才
    /// 合并成一行），13pt 在常规窗口宽度下列数卡在阈值边缘。
    var fontSize: Double = 12
    /// "system" = 系统等宽（SF Mono），否则为字体族名。
    var fontName: String = "system"
    var theme: String = "relay-dark"
    /// 回看行数。内存敏感：SwiftTerm 每行整行预分配（~3KB/行@110列），
    /// 5000 行写满约 +15MB/会话。默认 2000 在回看与内存间取平衡。
    var scrollback: Int = 2000
    /// Metal GPU 渲染（字形图集 + 逐 cell quad，重绘跟随 ProMotion 120Hz）。
    /// 默认开启：agent TUI 每秒发十几个同步输出块（CSI 2026），SwiftTerm
    /// 每块结束全屏标脏（endSynchronizedOutput → refresh 0..rows），CG 路径
    /// 是每秒十几次全屏 CoreText 重排版（卡顿/闪烁/CPU 的共同根源），Metal
    /// 路径全屏重绘便宜一个量级。代价 footprint +~160MB，内存敏感场景可关。
    var gpuRender: Bool = true
    /// 跟随系统明暗：开启后暗色用 theme、亮色用 themeLight（Ghostty 的
    /// theme = light:…,dark:… 语义）。关闭时只看 theme。
    var followSystemTheme: Bool = false
    var themeLight: String = "catppuccin-latte"
    /// 终端/窗口背景不透明度（0.7-1.0）。<1 时整窗半透明。
    var bgOpacity: Double = 1.0
    /// 窗口背景毛玻璃半径（0=关）。需 bgOpacity<1 才看得到效果。
    var bgBlur: Int = 0
    /// 光标形状 block / bar / underline；blink 控制闪烁。
    var cursorShape: String = "block"
    var cursorBlink: Bool = true
    /// 终端内容与窗口边缘的内边距（pt，Ghostty window-padding）。
    var padding: Double = 0
    /// 行高微调（pt，加到每行格高上，Ghostty adjust-cell-height）。
    var lineSpacing: Double = 0
    /// 字距微调（pt，加到格宽上，负值收紧；Ghostty adjust-cell-width。
    /// 中文占 2 格，收紧量是英文的两倍——正好抵消 2 格网格的中文空隙）。
    var letterSpacing: Double = 0
    /// 侧边栏显隐（Safari 式收起/展开，标签条左侧按钮切换）。
    var sidebarVisible: Bool = true
    /// 侧边栏宽度（pt，可拖拽右缘分隔条调整，持久化）。
    var sidebarWidth: Double = 232
    /// 自动检查更新（启动后台 + 每 24h 查 GitHub Releases，有新版发通知）。
    var autoUpdateCheck: Bool = true

    // 旧版本设置文件缺字段时取默认值。
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? 12
        fontName = (try? c.decode(String.self, forKey: .fontName)) ?? "system"
        theme = (try? c.decode(String.self, forKey: .theme)) ?? "relay-dark"
        scrollback = (try? c.decode(Int.self, forKey: .scrollback)) ?? 2000
        gpuRender = (try? c.decode(Bool.self, forKey: .gpuRender)) ?? true
        followSystemTheme = (try? c.decode(Bool.self, forKey: .followSystemTheme)) ?? false
        themeLight = (try? c.decode(String.self, forKey: .themeLight)) ?? "catppuccin-latte"
        bgOpacity = (try? c.decode(Double.self, forKey: .bgOpacity)) ?? 1.0
        bgBlur = (try? c.decode(Int.self, forKey: .bgBlur)) ?? 0
        cursorShape = (try? c.decode(String.self, forKey: .cursorShape)) ?? "block"
        cursorBlink = (try? c.decode(Bool.self, forKey: .cursorBlink)) ?? true
        padding = (try? c.decode(Double.self, forKey: .padding)) ?? 0
        lineSpacing = (try? c.decode(Double.self, forKey: .lineSpacing)) ?? 0
        letterSpacing = (try? c.decode(Double.self, forKey: .letterSpacing)) ?? 0
        sidebarVisible = (try? c.decode(Bool.self, forKey: .sidebarVisible)) ?? true
        sidebarWidth = (try? c.decode(Double.self, forKey: .sidebarWidth)) ?? 232
        autoUpdateCheck = (try? c.decode(Bool.self, forKey: .autoUpdateCheck)) ?? true
    }
}

/// 应用数据目录：~/Library/Application Support/RelayNative。
/// RELAY_DATA_DIR 环境变量可覆盖（排障用：隔离实例不污染正式数据）。
enum DataDir {
    static let url: URL = {
        if let override = ProcessInfo.processInfo.environment["RELAY_DATA_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RelayNative", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func scrollbackFile(_ id: String) -> URL {
        // id 由本应用生成（s<毫秒>-<序号>），不含路径字符。
        url.appendingPathComponent("scrollback-\(id).bin")
    }

    static var sessionsFile: URL { url.appendingPathComponent("sessions.json") }
    static var settingsFile: URL { url.appendingPathComponent("settings.json") }
}
