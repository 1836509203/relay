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

    // 16 款公认经典：暗色 12（Relay 自家 + Xcode 暗 + iTerm2 默认纯黑 + Dracula/Nord/
    // Solarized/Gruvbox/One Dark/东京夜/Monokai/Everforest/Catppuccin Mocha）+ 亮色 4
    // （Catppuccin Latte/Xcode 亮/Solarized 亮/Gruvbox 亮）。relay-dark 与
    // catppuccin-latte 是默认值，必须保留。
    static let all: [TerminalTheme] = [
        // 暗色
        relayDark, xcodeDark, itermDefault, dracula, nord, solarizedDark,
        gruvboxDark, oneDark, tokyoNight, monokai, everforestDark, catppuccinMocha,
        // 亮色
        catppuccinLatte, xcodeLight, solarizedLight, gruvboxLight,
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

    // Monokai 经典（Sublime）：灰底 + 高饱和亮粉/青绿/黄。
    static let monokai = TerminalTheme(
        id: "monokai", name: "Monokai",
        bg: 0x272822, fg: 0xF8F8F2, caret: 0xF8F8F0,
        ansi: [
            0x272822, 0xF92672, 0xA6E22E, 0xF4BF75,
            0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
            0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75,
            0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5,
        ]
    )

    // Solarized 亮色（Ethan Schoonover 官方）。正文/光标用 base01 #586E75
    // （非 base00），对米底 4.99:1 过 WCAG AA。
    static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized 亮色",
        bg: 0xFDF6E3, fg: 0x586E75, caret: 0x586E75,
        ansi: [
            0x073642, 0xDC322F, 0x859900, 0xB58900,
            0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
            0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
        ]
    )

    // Gruvbox 亮色（morhetz）。ANSI 0-7 取 faded/dark 暗色系（浅底可读），
    // 「黑」压成 #3C3836（原 port 把黑设成底色 → 白底不可见）。
    static let gruvboxLight = TerminalTheme(
        id: "gruvbox-light", name: "Gruvbox 亮色",
        bg: 0xFBF1C7, fg: 0x3C3836, caret: 0x3C3836,
        ansi: [
            0x3C3836, 0x9D0006, 0x79740E, 0xB57614,
            0x076678, 0x8F3F71, 0x427B58, 0x7C6F64,
            0x928374, 0xCC241D, 0x98971A, 0xD79921,
            0x458588, 0xB16286, 0x689D6A, 0x3C3836,
        ]
    )

    // Apple Xcode 官方源码编辑器配色（Xcode/Swift 生态最熟悉的暗/亮，跟随系统时配对）。
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

    // Everforest 暗色（sainnhe）：低饱和暖森林绿，护眼，与 Catppuccin 同属耐看派。
    static let everforestDark = TerminalTheme(
        id: "everforest-dark", name: "Everforest 暗色",
        bg: 0x2D353B, fg: 0xD3C6AA, caret: 0xD3C6AA,
        ansi: [
            0x343F44, 0xE67E80, 0xA7C080, 0xDBBC7F,
            0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
            0x868D80, 0xE67E80, 0xA7C080, 0xDBBC7F,
            0x7FBBB3, 0xD699B6, 0x83C092, 0x9DA9A0,
        ]
    )

    // iTerm2 出厂默认 profile（纯黑 #000000 底 + 浅灰 #C7C7C7 字 + 标志性暗蓝/品红
    // ANSI）。即终端老用户最熟悉的"iTerm2 那种纯黑"。注意 ANSI 0(黑)=底色，黑字落黑底
    // 不可见——这是 iTerm2 默认的原貌，照搬不改。
    static let itermDefault = TerminalTheme(
        id: "iterm-default", name: "iTerm2 默认（纯黑）",
        bg: 0x000000, fg: 0xC7C7C7, caret: 0xC7C7C7,
        ansi: [
            0x000000, 0xC91B00, 0x00C200, 0xC7C400,
            0x0225C7, 0xCA30C7, 0x00C5C7, 0xC7C7C7,
            0x686868, 0xFF6E67, 0x5FFA68, 0xFFFC67,
            0x6871FF, 0xFF77FF, 0x60FDFF, 0xFFFFFF,
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
