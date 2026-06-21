// 主题：Relay 壳层色板（侧栏/标签条/设置页）。暗色与 Web 版 relay-dark 同源；
// 亮色为 Catppuccin Latte 邻近的中性灰。每个色都是「暗/亮双值动态色」——
// 按所在窗口的 appearance 解析（窗口 appearance 由 applyWindowChrome 根据
// 生效终端主题的明暗设置），切日间模式壳层自动变白。
// 注意：不 import SwiftTerm —— 它自带一个 `Color` 类型，会与 SwiftUI.Color
// 撞名导致下方 extension 解析错位（RelayTerminalView 同模块可见，成员照常访问）。
import AppKit
import SwiftUI

enum Theme {
    /// 暗/亮双值动态色。CALayer 等需要 CGColor 的地方在取 .cgColor 时按
    /// 当前绘制外观解析为静态色（EmblemView 在外观变化时整树重建）。
    private static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            let isDark = app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex6: isDark ? dark : light)
        })
    }

    // 界面色板
    static let bg0 = dyn(0x0E1014, 0xECEEF4)     // 最深背景（侧栏）
    static let bg1 = dyn(0x14171D, 0xF5F6FA)     // 主背景
    static let bg2 = dyn(0x1B1F27, 0xE2E5EC)     // 卡片/行 hover
    static let fg0 = dyn(0xE8E6E1, 0x2A2D3A)     // 主文字
    static let fg2 = dyn(0x8E94A3, 0x5C5F77)     // 次级文字
    // 亮色值 0x9CA0AF 在浅背景上仅 ~2.4:1（低于 WCAG AA）；加深到 0x787C8C
    // ≈3.8:1：可读性达「弱文字」可接受档，又仍明显弱于 fg2(0x5C5F77) 保层级。
    static let fg3 = dyn(0x5C6273, 0x787C8C)     // 占位/弱文字
    static let line = dyn(0x262B36, 0xD6DAE3)    // 分隔线
    /// 高亮底（⌘ 角标 pill / 关闭钮 hover）：暗用白、亮用黑，配 opacity 用。
    static let pill = dyn(0xFFFFFF, 0x000000)

    // 状态色（与 emblems.tsx 一致；亮色下加深保对比度）
    static let claude = Color(hex: 0xD77B60)
    static let think = dyn(0xA99BD9, 0x7E6FC0)
    static let codex = Color(hex: 0x6C58EF)
    static let term = dyn(0xC2C0B6, 0x6E7480)
    static let termAccent = dyn(0xD9A857, 0xB07D2B)
    static let ssh = dyn(0x7FA8C9, 0x4A7BA6)
    static let done = dyn(0x9CB97E, 0x5E8745)
    static let amber = dyn(0xD9A857, 0xB07D2B)
    static let red = dyn(0xC96A6A, 0xB94A4A)

    static func phaseColor(_ p: DisplayPhase) -> Color {
        switch p {
        case .thinking: return think
        case .working: return dyn(0x6FA8DC, 0x3D7DBA)
        case .waiting: return amber
        case .done: return done
        case .idle: return fg2
        case .error: return red
        }
    }

}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1
        )
    }
}

extension NSColor {
    convenience init(hex6: UInt32) {
        self.init(
            srgbRed: CGFloat((hex6 >> 16) & 0xFF) / 255,
            green: CGFloat((hex6 >> 8) & 0xFF) / 255,
            blue: CGFloat(hex6 & 0xFF) / 255,
            alpha: 1
        )
    }
}
