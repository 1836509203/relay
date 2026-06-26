// Claude Code transcript 读取：从 ~/.claude/projects/<encoded-cwd>/<session>.jsonl 里
// 抽取「最近一条回复」的纯文本，供「⌘⇧C 复制最近回复」使用。
//
// 为什么不从终端抓：CC 跑在备用屏、自管滚动 + 就地重绘，终端里只有渲染后的字节（换行、
// 装饰、被滚出屏幕的历史都拿不全）。而 CC 自己把整段对话以结构化 JSONL 落盘，直接读它得到
// 的是干净、完整、未截断的原文——这也是「复制长回复」唯一可靠的来源。
//
// 纯逻辑、无 UI，便于单元测试。

import Foundation

enum AgentTranscript {

    // MARK: - 对外入口

    /// 给定工作目录，返回该项目最近活跃的 Claude 会话里最后一条回复的纯文本。
    static func latestClaudeResponse(cwd: String) -> String? {
        let dir = claudeProjectDir(forCwd: cwd)
        guard let transcript = newestTranscript(in: dir) else { return nil }
        return lastAssistantText(fromTranscript: transcript)
    }

    // MARK: - 路径定位

    /// CC 的项目目录编码：把 cwd 里每个非 [A-Za-z0-9] 字符替换成 '-'
    /// （与 Claude Code 自身 `/[^a-zA-Z0-9]/g → '-'` 规则一致；CJK、'/'、'.'、'_' 等皆变 '-'）。
    /// 例：/Users/zhanghao/Project/iterm → -Users-zhanghao-Project-iterm
    static func claudeProjectDir(forCwd cwd: String) -> URL {
        let encoded = String(cwd.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        })
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
    }

    /// 目录里 mtime 最新的 .jsonl —— 即当前/最近活跃的会话 transcript。
    /// 局限：同一 cwd 并发多个 CC 会话时只能取最近写入的那个（v1 取舍，精确映射需 hook 透传 sessionId）。
    static func newestTranscript(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return items
            .filter { $0.pathExtension == "jsonl" }
            .max(by: { modDate($0) < modDate($1) })
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - tail 读取 + 解析

    /// 从 transcript 末尾倒着读取（默认 256KB，找不到回合边界就翻倍扩窗，直到整文件），
    /// 抽取最后一个回合的 assistant 文本。避免把 70MB 的大会话整体载入。
    static func lastAssistantText(fromTranscript url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        if end == 0 { return nil }

        var window: UInt64 = 256 * 1024
        while true {
            let isWhole = window >= end
            let start = isWhole ? 0 : end - window
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.readToEnd() else { return nil }

            var text = String(decoding: data, as: UTF8.self)
            // 非从文件头开始时，丢掉被切断的首行残片。
            if start > 0, let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if let result = extractFinalTurnText(lines: lines, isWholeFile: isWhole) {
                return result
            }
            if isWhole { return nil }
            window *= 4
        }
    }

    private enum LineKind {
        case userPrompt              // 人类真正输入的提问（字符串或含 text 块；tool_result 不算）
        case assistantText(String)   // assistant 消息里的 text 块（已剔除 thinking / tool_use）
        case skip
    }

    /// 从给定行集合里抽取「最后一个回合」的 assistant 文本：从最后一条 assistant 文本往回走，
    /// 沿途收集 assistant 文本，遇到一条真实用户提问即停（回合上界）。
    /// - isWholeFile: 若窗口里没走到用户提问边界且未覆盖整文件，返回 nil 让调用方扩窗。
    static func extractFinalTurnText(lines: [Substring], isWholeFile: Bool) -> String? {
        let kinds = lines.map(classify)

        guard let lastAssistant = kinds.lastIndex(where: {
            if case .assistantText = $0 { return true }; return false
        }) else { return nil }

        var collected: [String] = []   // 倒序收集
        var hitBoundary = false
        var i = lastAssistant
        walk: while i >= 0 {
            switch kinds[i] {
            case .userPrompt:
                hitBoundary = true
                break walk
            case .assistantText(let t):
                collected.append(t)
            case .skip:
                break
            }
            i -= 1
        }

        // 没碰到回合边界、又没读全文件：当前窗口不足以确定回合起点，请求扩窗。
        if !hitBoundary && !isWholeFile { return nil }

        let chrono = collected.reversed().joined(separator: "\n\n")
        return normalize(chrono)
    }

    private static func classify(_ line: Substring) -> LineKind {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return .skip }
        // 子代理（Task）的侧链消息不属于主对话，跳过。
        if obj["isSidechain"] as? Bool == true { return .skip }
        guard let message = obj["message"] as? [String: Any] else { return .skip }
        let content = message["content"]

        switch type {
        case "user":
            if let s = content as? String { return s.isEmpty ? .skip : .userPrompt }
            if let arr = content as? [[String: Any]] {
                let hasText = arr.contains { ($0["type"] as? String) == "text" }
                let hasToolResult = arr.contains { ($0["type"] as? String) == "tool_result" }
                // 人类提问（可能附带图片，但仍带 text 块）才是回合边界；tool_result 是回合内的工具回执。
                if hasText && !hasToolResult { return .userPrompt }
            }
            return .skip

        case "assistant":
            if let arr = content as? [[String: Any]] {
                let texts = arr.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    let t = (block["text"] as? String) ?? ""
                    return t.isEmpty ? nil : t
                }
                if !texts.isEmpty { return .assistantText(texts.joined(separator: "\n")) }
            } else if let s = content as? String, !s.isEmpty {
                return .assistantText(s)
            }
            return .skip

        default:
            return .skip
        }
    }

    /// 去首尾空白，并把 3+ 连续换行收敛为 2，保持段落整洁。
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.contains("\n\n\n") {
            s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return s.isEmpty ? nil : s
    }
}
