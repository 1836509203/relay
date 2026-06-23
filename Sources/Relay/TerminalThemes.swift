// 终端配色主题（ANSI 16 色 + 前景/背景/光标）。
// 本文件 import SwiftTerm（其 `Color` 与 SwiftUI.Color 撞名，故界面色板
// 留在 Theme.swift，这里只放终端侧配色与应用逻辑）。
import AppKit
import SwiftTerm

struct TerminalTheme: Identifiable {
    let id: String
    let name: String
    let bg: UInt32
    let fg: UInt32
    let caret: UInt32
    /// ANSI 0-15
    let ansi: [UInt32]

    // 列表顺序＝设置页菜单顺序（再按 isLight 分组成「暗色/亮色」两节）。
    // 先 Relay 自家与苹果原生（Xcode / Apple 终端经典 / 石墨 / 深海），
    // 再社区精品（夜枭 / 东京夜 / 玫瑰松 / Ayu / Dracula…），最后亮色组。
    static let all: [TerminalTheme] = [
        // 暗色
        relayDark, xcodeDark, applePro, spacegray, ocean,
        nightOwl, tokyoNight, rosePine, ayuMirage,
        dracula, nord, oneDark, gruvboxDark, solarizedDark, catppuccinMocha,
        // 亮色
        light, xcodeLight, appleBasic, novel,
        tokyoNightDay, rosePineDawn, ayuLight, catppuccinLatte,
    ]

    static let relayDark = TerminalTheme(
        id: "relay-dark", name: "Relay 暗色",
        bg: 0x14171D, fg: 0xE8E6E1, caret: 0xD9A857,
        ansi: [
            0x1B1F27, 0xC96A6A, 0x9CB97E, 0xD9A857,
            0x6FA8DC, 0xA99BD9, 0x7FB8B0, 0xC2C0B6,
            0x5C6273, 0xE08C8C, 0xB5D193, 0xE8C078,
            0x8FC1ED, 0xC3B7E8, 0x9AD3CB, 0xE8E6E1,
        ]
    )

    static let light = TerminalTheme(
        id: "light", name: "明亮",
        bg: 0xFAFAF7, fg: 0x1F2328, caret: 0xB07D2B,
        ansi: [
            0x24292F, 0xCF222E, 0x116329, 0x9A6700,
            0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
            0x57606A, 0xA40E26, 0x044F1E, 0x633C01,
            0x0550AE, 0x622CBC, 0x12616A, 0x24292F,
        ]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized 暗色",
        bg: 0x002B36, fg: 0x839496, caret: 0xB58900,
        ansi: [
            0x073642, 0xDC322F, 0x859900, 0xB58900,
            0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
            0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
        ]
    )

    // Catppuccin 官方终端色板（https://catppuccin.com/palette）。
    static let catppuccinMocha = TerminalTheme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha",
        bg: 0x1E1E2E, fg: 0xCDD6F4, caret: 0xF5E0DC,
        ansi: [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
            0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
            0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
            0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
        ]
    )

    static let catppuccinLatte = TerminalTheme(
        id: "catppuccin-latte", name: "Catppuccin Latte",
        bg: 0xEFF1F5, fg: 0x4C4F69, caret: 0xDC8A78,
        ansi: [
            0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D,
            0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
            0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D,
            0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC,
        ]
    )

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula",
        bg: 0x282A36, fg: 0xF8F8F2, caret: 0xF8F8F2,
        ansi: [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
            0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
            0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
        ]
    )

    static let nord = TerminalTheme(
        id: "nord", name: "Nord",
        bg: 0x2E3440, fg: 0xD8DEE9, caret: 0xD8DEE9,
        ansi: [
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
            0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
            0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
        ]
    )

    static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark",
        bg: 0x282C34, fg: 0xABB2BF, caret: 0x528BFF,
        ansi: [
            0x3F4451, 0xE06C75, 0x98C379, 0xE5C07B,
            0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
            0x4F5666, 0xE06C75, 0x98C379, 0xE5C07B,
            0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFEFE,
        ]
    )

    static let gruvboxDark = TerminalTheme(
        id: "gruvbox-dark", name: "Gruvbox 暗色",
        bg: 0x282828, fg: 0xEBDBB2, caret: 0xEBDBB2,
        ansi: [
            0x3C3836, 0xCC241D, 0x98971A, 0xD79921,
            0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F,
            0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
        ]
    )

    // MARK: - 苹果原生风

    // Xcode 官方源码编辑器主题（Apple 开发者最熟悉的暗/亮配色）。
    static let xcodeDark = TerminalTheme(
        id: "xcode-dark", name: "Xcode 暗色",
        bg: 0x292A30, fg: 0xDFDFE0, caret: 0xDFDFE0,
        ansi: [
            0x414453, 0xFF8170, 0x78C2B3, 0xD9C97C,
            0x4EB0CC, 0xFF7AB2, 0xB281EB, 0xDFDFE0,
            0x7F8C98, 0xFF8170, 0xACF2E4, 0xFFA14F,
            0x6BDFFF, 0xFF7AB2, 0xDABAFF, 0xDFDFE0,
        ]
    )

    static let xcodeLight = TerminalTheme(
        id: "xcode-light", name: "Xcode 亮色",
        bg: 0xFFFFFF, fg: 0x262626, caret: 0x262626,
        // 原 port 把「黑」设成浅蓝(#B4D8FD)，白底当文字会看不见 → 覆盖为深色。
        ansi: [
            0x262626, 0xD12F1B, 0x3E8087, 0x78492A,
            0x0F68A0, 0xAD3DA4, 0x804FB8, 0x262626,
            0x8A99A6, 0xD12F1B, 0x23575C, 0x78492A,
            0x0B4F79, 0xAD3DA4, 0x4B21B0, 0x262626,
        ]
    )

    // Apple 终端 .app 经典描述文件「Pro」（黑底）。光标从原版 #4D4D4D
    // 提亮到浅灰，黑底上才看得见。
    static let applePro = TerminalTheme(
        id: "apple-pro", name: "Apple 经典",
        bg: 0x000000, fg: 0xF2F2F2, caret: 0xC7C7C7,
        ansi: [
            0x000000, 0x990000, 0x00A600, 0x999900,
            0x2009DB, 0xB200B2, 0x00A6B2, 0xBFBFBF,
            0x666666, 0xE50000, 0x00D900, 0xE5E500,
            0x0000FF, 0xE500E5, 0x00E5E5, 0xE5E5E5,
        ]
    )

    // Apple 终端 .app 经典「Basic」（白底）。
    static let appleBasic = TerminalTheme(
        id: "apple-basic", name: "Apple 基础",
        bg: 0xFFFFFF, fg: 0x000000, caret: 0x7F7F7F,
        ansi: [
            0x000000, 0x990000, 0x00A600, 0x999900,
            0x0000B2, 0xB200B2, 0x00A6B2, 0xBFBFBF,
            0x666666, 0xE50000, 0x00D900, 0xBFBF00,
            0x0000FF, 0xE500E5, 0x00D8D8, 0xE5E5E5,
        ]
    )

    // Apple 终端 .app 经典「Ocean」（深蓝底）。光标提亮到白色。
    static let ocean = TerminalTheme(
        id: "ocean", name: "深海",
        bg: 0x224FBC, fg: 0xFFFFFF, caret: 0xFFFFFF,
        ansi: [
            0x000000, 0xE64C4C, 0x00A600, 0x999900,
            0x0000B2, 0xD826D8, 0x00A6B2, 0xBFBFBF,
            0x808080, 0xFF1A1A, 0x00D900, 0xE5E500,
            0x7373FF, 0xE500E5, 0x00E5E5, 0xE5E5E5,
        ]
    )

    // Apple 终端 .app 经典「Novel」（米色护眼纸张，适合长时间阅读）。
    static let novel = TerminalTheme(
        id: "novel", name: "小说",
        bg: 0xDFDBC3, fg: 0x3B2322, caret: 0x73635A,
        ansi: [
            0x000000, 0xCC0000, 0x009600, 0xD06B00,
            0x0000CC, 0xCC00CC, 0x0087CC, 0xA6A6A6,
            0x808080, 0xCC0000, 0x009600, 0xD06B00,
            0x0000CC, 0xCC00CC, 0x0087CC, 0xFFFFFF,
        ]
    )

    // macOS 太空灰质感的中性暗色（Spacegray）。
    static let spacegray = TerminalTheme(
        id: "spacegray", name: "石墨",
        bg: 0x20242D, fg: 0xB3B8C3, caret: 0xB3B8C3,
        ansi: [
            0x000000, 0xB04B57, 0x87B379, 0xE5C179,
            0x7D8FA4, 0xA47996, 0x85A7A5, 0xB3B8C3,
            0x4C4C4C, 0xB04B57, 0x87B379, 0xE5C179,
            0x7D8FA4, 0xA47996, 0x85A7A5, 0xFFFFFF,
        ]
    )

    // MARK: - 社区精品（macOS 上同样耐看）

    // Night Owl：深海军蓝底 + 紫光标。
    static let nightOwl = TerminalTheme(
        id: "night-owl", name: "夜枭",
        bg: 0x011627, fg: 0xD6DEEB, caret: 0x7E57C2,
        ansi: [
            0x011627, 0xEF5350, 0x22DA6E, 0xADDB67,
            0x82AAFF, 0xC792EA, 0x21C7A8, 0xFFFFFF,
            0x575656, 0xEF5350, 0x22DA6E, 0xFFEB95,
            0x82AAFF, 0xC792EA, 0x7FDBCA, 0xFFFFFF,
        ]
    )

    static let tokyoNight = TerminalTheme(
        id: "tokyo-night", name: "东京夜",
        bg: 0x1A1B26, fg: 0xC0CAF5, caret: 0xC0CAF5,
        ansi: [
            0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68,
            0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68,
            0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
        ]
    )

    static let tokyoNightDay = TerminalTheme(
        id: "tokyo-night-day", name: "东京日",
        // 底色较原版 #E1E2E7 提亮半档：原版正文蓝对底仅 4.52（贴 AA 线、偏灰），
        // 抬底后整组对比同步上升，保留招牌蓝字。
        bg: 0xEAEBF0, fg: 0x3760BF, caret: 0x3760BF,
        // 原 port 的「黑」(#E9E9ED) 浅到白底看不见 → 覆盖为东京日的深蓝灰。
        ansi: [
            0x343B58, 0xF52A65, 0x587539, 0x8C6C3E,
            0x2E7DE9, 0x9854F1, 0x007197, 0x6172B0,
            0xA1A6C5, 0xF52A65, 0x587539, 0x8C6C3E,
            0x2E7DE9, 0x9854F1, 0x007197, 0x3760BF,
        ]
    )

    static let rosePine = TerminalTheme(
        id: "rose-pine", name: "玫瑰松",
        bg: 0x191724, fg: 0xE0DEF4, caret: 0xE0DEF4,
        ansi: [
            0x26233A, 0xEB6F92, 0x31748F, 0xF6C177,
            0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
            0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177,
            0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
        ]
    )

    static let rosePineDawn = TerminalTheme(
        id: "rose-pine-dawn", name: "玫瑰松·黎明",
        bg: 0xFAF4ED, fg: 0x575279, caret: 0x575279,
        // 原 port 的「黑」(#F2E9E1) 几乎与底色同 → 覆盖为正文深色。
        ansi: [
            0x575279, 0xB4637A, 0x286983, 0xEA9D34,
            0x56949F, 0x907AA9, 0xD7827E, 0x575279,
            0x9893A5, 0xB4637A, 0x286983, 0xEA9D34,
            0x56949F, 0x907AA9, 0xD7827E, 0x575279,
        ]
    )

    static let ayuMirage = TerminalTheme(
        id: "ayu-mirage", name: "Ayu 薄雾",
        bg: 0x1F2430, fg: 0xCCCAC2, caret: 0xFFCC66,
        ansi: [
            0x171B24, 0xED8274, 0x87D96C, 0xFACC6E,
            0x6DCBFA, 0xDABAFA, 0x90E1C6, 0xC7C7C7,
            0x686868, 0xF28779, 0xD5FF80, 0xFFD173,
            0x73D0FF, 0xDFBFFF, 0x95E6CB, 0xFFFFFF,
        ]
    )

    static let ayuLight = TerminalTheme(
        id: "ayu-light", name: "Ayu 亮色",
        // 光标从原版亮橙 #FFAA33（近白底对比仅 1.8，难定位）压深一档，
        // 保留 Ayu 暖橙身份的同时白底可见。
        bg: 0xF8F9FA, fg: 0x5C6166, caret: 0xE6900A,
        ansi: [
            0x000000, 0xEA6C6D, 0x6CBF43, 0xECA944,
            0x3199E1, 0x9E75C7, 0x46BA94, 0xBABABA,
            0x686868, 0xF07171, 0x86B300, 0xF2AE49,
            0x399EE6, 0xA37ACC, 0x4CBF99, 0xD1D1D1,
        ]
    )

    static func by(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? relayDark
    }

    /// 背景是否亮色（壳层窗口 appearance / 动态色跟它走）。Rec.709 亮度。
    var isLight: Bool {
        let r = Double((bg >> 16) & 0xFF), g = Double((bg >> 8) & 0xFF), b = Double(bg & 0xFF)
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 > 0.5
    }

    /// 明暗配对：跟随系统时，用户只选一个主题，系统切到另一侧外观时
    /// 自动换到配对款（官方亮暗对优先，无配对的暗色日间统一用 Latte）。
    static func counterpart(of id: String, wantLight: Bool) -> String {
        let t = by(id: id)
        if t.isLight == wantLight { return t.id }
        switch id {
        case "catppuccin-mocha": return "catppuccin-latte"
        case "catppuccin-latte": return "catppuccin-mocha"
        case "relay-dark": return "light"
        case "light": return "relay-dark"
        case "xcode-dark": return "xcode-light"
        case "xcode-light": return "xcode-dark"
        case "apple-pro": return "apple-basic"
        case "apple-basic": return "apple-pro"
        case "tokyo-night": return "tokyo-night-day"
        case "tokyo-night-day": return "tokyo-night"
        case "rose-pine": return "rose-pine-dawn"
        case "rose-pine-dawn": return "rose-pine"
        case "ayu-mirage": return "ayu-light"
        case "ayu-light": return "ayu-mirage"
        case "ocean": return "novel"          // 深蓝夜 ↔ 米色纸张：苹果氛围一对
        case "novel": return "ocean"
        case "spacegray": return "catppuccin-latte"   // 冷灰暗 → 冷灰白，调性更贴（单向，无亮色对）
        case "night-owl": return "tokyo-night-day"    // 深海军蓝 → 冷灰蓝亮色（单向）
        // 无显式配对时：暗色款日间回退 Catppuccin Latte，亮色款夜间回退 relay-dark。
        // 单向配对不会丢失用户选择 —— effectiveThemeId 始终从稳定的 settings.theme
        // 纯函数推导，系统切回主题原生那一侧时上方 isLight==wantLight 直接原样返回。
        default: return wantLight ? "catppuccin-latte" : "relay-dark"
        }
    }

    /// 应用配色与字体到一个终端视图。bgAlpha<1 = 半透明模式：终端自身
    /// 背景画成全透明（CG 不填充；Metal clearColor alpha 0 + vendored 的
    /// layer.isOpaque=false 补丁），唯一的半透明底由 RootView 终端区垫层
    /// 提供 —— 终端若自己再画一层 0.9 会与垫层叠成 ~0.99，透明度滑条
    /// 对终端区形同虚设（实测三层叠乘问题）。
    func apply(to v: RelayTerminalView, fontSize: Double, fontName: String, bgAlpha: Double = 1) {
        v.font = Self.font(name: fontName, size: CGFloat(fontSize))
        v.nativeBackgroundColor = Self.nsColor(bg, alpha: bgAlpha < 0.999 ? 0 : 1)
        v.nativeForegroundColor = Self.nsColor(fg)
        v.caretColor = Self.nsColor(caret)
        v.installColors(ansi.map { Self.stColor($0) })
    }

    /// 等宽字体解析；找不到回退系统等宽。
    static func font(name: String, size: CGFloat) -> NSFont {
        if name == "system" { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont(name: name, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 设置页的字体候选：系统等宽 + 常见已安装等宽字体（动态探测）。
    static func availableFonts() -> [(id: String, label: String)] {
        var out: [(String, String)] = [("system", "系统等宽 (SF Mono)")]
        for cand in ["Menlo", "Monaco",
                     "JetBrainsMono Nerd Font", "JetBrains Mono",
                     "Hack Nerd Font", "Hack", "MesloLGS NF", "Fira Code", "Cascadia Code",
                     "Source Code Pro", "IBM Plex Mono", "Iosevka", "Maple Mono",
                     "Maple Mono NF CN", "Noto Sans Mono CJK SC", "Sarasa Mono SC",
                     "Sarasa Term SC", "LXGW WenKai Mono"] {
            if NSFont(name: cand, size: 12) != nil { out.append((cand, cand)) }
        }
        return out
    }

    private static func nsColor(_ hex: UInt32, alpha: Double = 1) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: CGFloat(alpha)
        )
    }

    private static func stColor(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((hex >> 16) & 0xFF) * 257,
            green: UInt16((hex >> 8) & 0xFF) * 257,
            blue: UInt16(hex & 0xFF) * 257
        )
    }
}
