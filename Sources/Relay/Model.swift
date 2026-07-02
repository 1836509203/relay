// 数据模型 —— 与 Rust 版 model.rs 同构（会话/类型/状态/设置）。
import Foundation

enum WindowType: String, Codable, CaseIterable {
    case shell, claude, codex, opencode, remotion, ssh

    var isAgent: Bool { self == .claude || self == .codex || self == .opencode }

    /// 类型短标签 / 自动默认会话名。
    var label: String { rawValue }

    /// 侧栏分组标题（Local / Claude Code / Codex / SSH·主机）。
    func group(host: String?) -> String {
        switch self {
        case .shell: return "Local"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .remotion: return "Remotion"
        case .ssh:
            if let h = host, !h.trimmingCharacters(in: .whitespaces).isEmpty {
                let bare = h.split(separator: "@").last.map(String.init) ?? h
                return "SSH · \(bare)"
            }
            return "SSH"
        }
    }
}

enum SidebarTaskGrouping: String, Codable, CaseIterable, Identifiable {
    case type, project

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type: return "类型"
        case .project: return "项目"
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
    static let minimumPadding: Double = 8
    static let defaultFontSize: Double = 14
    static let defaultLineSpacing: Double = 1
    static let defaultLetterSpacing: Double = -0.25
    /// 默认终端字体：Noto Sans Mono CJK SC。其 ASCII "W" 步进约 0.5em，故汉字(占 2 格)=1.0em=
    /// 中文自然字宽、字距紧凑（参照 Codex）；而系统等宽 SF Mono 的 "W" 约 0.6em，汉字 2 格=1.2em
    /// 会有 ~20% 右侧空隙。未安装该字体时 TerminalTheme.font 会优雅回退到 SF Mono。
    static let defaultFontName = "Noto Sans Mono CJK SC"
    private static let legacyDefaultFontSize: Double = 12
    private static let legacyDefaultLineSpacing: Double = 0
    private static let legacyDefaultLetterSpacing: Double = 0
    private static let currentTerminalGeometryVersion = 3

    /// 终端默认排版贴近 Codex 主内容的阅读密度；字格仍保持等宽，只做轻微收紧。
    var fontSize: Double = defaultFontSize
    /// "system" = 系统等宽（SF Mono），否则为字体族名。默认 Noto Sans Mono CJK SC：
    /// 中文字距更紧凑（见 defaultFontName 说明），未安装时优雅回退到 SF Mono。
    var fontName: String = defaultFontName
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
    var followSystemTheme: Bool = true
    var themeLight: String = "catppuccin-latte"
    /// 终端/窗口背景不透明度（0.7-1.0）。<1 时整窗半透明。
    var bgOpacity: Double = 1.0
    /// 窗口背景毛玻璃半径（0=关）。需 bgOpacity<1 才看得到效果。
    var bgBlur: Int = 0
    /// 光标形状 block / bar / underline；blink 控制闪烁。
    var cursorShape: String = "block"
    var cursorBlink: Bool = true
    /// 终端内容与窗口边缘的内边距（pt，Ghostty window-padding）。
    /// 保留一个最小 inset，避免 Claude Code/Codex 等全屏 TUI 从第 0 列贴边绘制。
    var padding: Double = minimumPadding
    /// 行高微调（pt，加到每行格高上，Ghostty adjust-cell-height）。
    var lineSpacing: Double = defaultLineSpacing
    /// 字距微调（pt，加到格宽上，负值收紧；Ghostty adjust-cell-width。
    /// 中文占 2 格，收紧量是英文的两倍——正好抵消 2 格网格的中文空隙）。
    var letterSpacing: Double = defaultLetterSpacing
    /// 终端字格几何迁移版本。旧版曾把中文观感参数写入全局默认值，Claude/Codex
    /// 这类全屏 TUI 会因此拿到变形的行列数；无此字段的设置文件需迁移。
    var terminalGeometryVersion: Int = currentTerminalGeometryVersion
    /// 侧边栏显隐（Safari 式收起/展开，标签条左侧按钮切换）。
    var sidebarVisible: Bool = true
    /// 侧边栏宽度（pt，可拖拽右缘分隔条调整，持久化）。
    var sidebarWidth: Double = 232
    /// 自动检查更新（启动后台 + 每 24h 查 GitHub Releases，有新版发通知）。
    var autoUpdateCheck: Bool = true
    /// Codex 风格外观设置。默认关闭：侧栏与主工作区同取主题实底、聚焦失焦
    /// 观感一致；开启后侧栏在聚焦时走 behind-window 毛玻璃（会与主区实底产生
    /// 明暗差，介意割裂感就保持关闭）。
    var translucentSidebar: Bool = false
    /// 侧栏任务聚合方式：默认按工具类型聚合，让 Codex/Claude/OpenCode 任务分开。
    var taskGrouping: SidebarTaskGrouping = .type
    var uiContrast: Double = 60
    /// 终端主题的局部覆盖。nil 表示沿用当前主题原值，避免切主题后残留旧色。
    var customAccentHex: UInt32?
    var customBackgroundHex: UInt32?
    var customForegroundHex: UInt32?
    /// "system" = macOS 系统 UI 字体，否则为字体族名。
    var uiFontName: String = "system"
    /// system / on / off
    var motionPreference: String = "system"
    var uiFontSize: Double = 14

    // 旧版本设置文件缺字段时取默认值。
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? Self.defaultFontSize
        fontName = (try? c.decode(String.self, forKey: .fontName)) ?? Self.defaultFontName
        theme = (try? c.decode(String.self, forKey: .theme)) ?? "relay-dark"
        scrollback = (try? c.decode(Int.self, forKey: .scrollback)) ?? 2000
        gpuRender = (try? c.decode(Bool.self, forKey: .gpuRender)) ?? true
        followSystemTheme = (try? c.decode(Bool.self, forKey: .followSystemTheme)) ?? true
        themeLight = (try? c.decode(String.self, forKey: .themeLight)) ?? "catppuccin-latte"
        bgOpacity = (try? c.decode(Double.self, forKey: .bgOpacity)) ?? 1.0
        bgBlur = (try? c.decode(Int.self, forKey: .bgBlur)) ?? 0
        cursorShape = (try? c.decode(String.self, forKey: .cursorShape)) ?? "block"
        cursorBlink = (try? c.decode(Bool.self, forKey: .cursorBlink)) ?? true
        padding = max(Self.minimumPadding, (try? c.decode(Double.self, forKey: .padding)) ?? Self.minimumPadding)
        lineSpacing = (try? c.decode(Double.self, forKey: .lineSpacing)) ?? Self.defaultLineSpacing
        letterSpacing = (try? c.decode(Double.self, forKey: .letterSpacing)) ?? Self.defaultLetterSpacing
        terminalGeometryVersion = (try? c.decode(Int.self, forKey: .terminalGeometryVersion)) ?? 1
        sidebarVisible = (try? c.decode(Bool.self, forKey: .sidebarVisible)) ?? true
        sidebarWidth = (try? c.decode(Double.self, forKey: .sidebarWidth)) ?? 232
        autoUpdateCheck = (try? c.decode(Bool.self, forKey: .autoUpdateCheck)) ?? true
        translucentSidebar = (try? c.decode(Bool.self, forKey: .translucentSidebar)) ?? false
        taskGrouping = (try? c.decode(SidebarTaskGrouping.self, forKey: .taskGrouping)) ?? .type
        uiContrast = (try? c.decode(Double.self, forKey: .uiContrast)) ?? 60
        customAccentHex = try? c.decode(UInt32.self, forKey: .customAccentHex)
        customBackgroundHex = try? c.decode(UInt32.self, forKey: .customBackgroundHex)
        customForegroundHex = try? c.decode(UInt32.self, forKey: .customForegroundHex)
        uiFontName = (try? c.decode(String.self, forKey: .uiFontName)) ?? "system"
        motionPreference = (try? c.decode(String.self, forKey: .motionPreference)) ?? "system"
        uiFontSize = (try? c.decode(Double.self, forKey: .uiFontSize)) ?? 14

        migrateTerminalGeometryIfNeeded()
    }

    private mutating func migrateTerminalGeometryIfNeeded() {
        if terminalGeometryVersion >= Self.currentTerminalGeometryVersion {
            padding = max(Self.minimumPadding, padding)
            return
        }

        if terminalGeometryVersion < 2 {
            // v1 设置把中文观感用的行距/字距带进了全局终端字格。对普通输出只是
            // "看起来松一点"，但 Claude/Codex/vim 这类全屏程序会按变形后的行列数
            // 重新布局，结果就是内屏比例和 iTerm2 不一致。
            if lineSpacing != 0 || letterSpacing != 0 || padding < Self.minimumPadding {
                if fontSize <= 13 {
                    fontSize = Self.legacyDefaultFontSize
                }
                lineSpacing = Self.legacyDefaultLineSpacing
                letterSpacing = Self.legacyDefaultLetterSpacing
                padding = Self.minimumPadding
            }
        }

        // v3 将仍停留在旧默认排版的用户迁到 Codex 风格的阅读密度；已手动调过
        // 字号/行距/字距的配置保持原样。
        if terminalGeometryVersion < 3 {
            let usingLegacyDefaults = approx(fontSize, Self.legacyDefaultFontSize)
                && approx(lineSpacing, Self.legacyDefaultLineSpacing)
                && approx(letterSpacing, Self.legacyDefaultLetterSpacing)
            if usingLegacyDefaults {
                fontSize = Self.defaultFontSize
                lineSpacing = Self.defaultLineSpacing
                letterSpacing = Self.defaultLetterSpacing
            }
        }

        padding = max(Self.minimumPadding, padding)
        terminalGeometryVersion = Self.currentTerminalGeometryVersion
    }

    private func approx(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.001
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
