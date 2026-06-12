// AI agent 状态启发式 —— 基于「当前屏幕内容」逐帧判定，而非输出字节流。
//
// 为什么不能扫输出流：新版 claude/codex TUI 是差量渲染，状态行只在首帧
// 完整输出，之后每帧只重绘变化的字符（spinner 符号、计时数字）。实测
// claude v2.1 一次完整运行的原始输出里 "esc to interrupt" 出现 0 次
//（该提示已被官方移除），spinner 行只剩 "✳ Frosting… (16s)"。从字节流
// 里抓关键词会在首帧之后失明，把运行中的会话 settle 成 Done。
//
// 屏幕才是真相：spinner 行在屏上 = 运行中，被 TUI 擦掉 = 结束。
// SessionStore 每秒取一次可见行调用 scan(_:)，hook 事件仍是权威信号。
import Foundation

enum Detector {
    /// 忙碌信号从屏幕上消失多久后判定 agent 完成（秒）。
    static let settleSeconds: TimeInterval = 2.5

    struct Signal {
        var busy = false
        var waiting = false
        var thinking = false
    }

    /// spinner 行首符号：claude v2 的 ✶✻✽✳✢· 轮转 + braille 转轮。
    /// 故意不含 ●/○ 等圆形——claude 回答正文的 bullet 用 ●，会误判；
    /// codex 的运行行（● Working … esc to interrupt）由关键词规则覆盖。
    private static let spinnerHeads: Set<Character> = [
        "✶", "✻", "✽", "✳", "✢", "·", "∗", "✦", "✧", "*",
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ]

    /// 审批/确认提示特征。
    private static let waitingPats = [
        "do you want", "❯ 1.", "1. yes", "(y/n)", "[y/n]",
        "approve", "allow this", "proceed?", "press enter to continue",
    ]

    /// 思考态文案（旧版 claude；新版 spinner 文案是随机词，命中即标，不强求）。
    private static let thinkingWords = [
        "thinking", "pondering", "musing", "ruminating", "cogitating", "reasoning",
    ]

    /// 扫一帧屏幕（可见行，右侧空白已剥）。
    static func scan(_ lines: [String]) -> Signal {
        var sig = Signal()
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let low = line.lowercased()
            if !sig.waiting, waitingPats.contains(where: { low.contains($0) }) {
                sig.waiting = true
            }
            if !sig.busy, isSpinnerLine(line, low: low) {
                sig.busy = true
                if thinkingWords.contains(where: { low.contains($0) }) { sig.thinking = true }
            }
            if sig.busy && sig.waiting { break }
        }
        return sig
    }

    /// 运行中状态行：含 "esc to interrupt"（codex / 旧版 claude），或
    /// spinner 符号开头、省略号紧跟首词的行（claude v2.1+ 的
    /// "✳ Frosting… (16s)" 格式——省略号必在前 32 字符内，行尾才带
    /// 省略号的正文 bullet 不命中）。
    private static func isSpinnerLine(_ line: String, low: String) -> Bool {
        if low.contains("esc to interrupt") || low.contains("interrupt)") { return true }
        guard let head = line.first, spinnerHeads.contains(head) else { return false }
        return line.prefix(32).contains("…")
    }
}
