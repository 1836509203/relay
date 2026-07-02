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
    /// 注意 --continue 沿用原文件追加（实测不新建），按文件创建时间界定
    /// 「当前进程的会话」必误杀；进程边界用轮次 timestamp 过滤（见调用方）。
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

// MARK: - 对话轮次（左缘时间轴刻度条的数据源）

/// 一轮对话：用户提问 + assistant 回答摘要。回答进行中时 reply 为空。
struct ConversationTurn: Identifiable, Equatable {
    let prompt: String
    let reply: String
    let timestamp: Date?
    /// 内容派生的稳定 id：读取窗口大小变化时轮次序号会漂，时间戳（毫秒级）
    /// + 提问前缀跨刷新稳定。
    var id: String { "\(timestamp?.timeIntervalSince1970 ?? 0)|\(prompt.prefix(32))" }
}

extension AgentTranscript {

    /// 给定工作目录，列出候选会话文件（mtime 降序前 limit 个）。哪个才是
    /// 「这个终端里跑着的 CC」不能按文件时间猜（同 cwd 可并发多个会话、
    /// --continue 沿用旧文件），由调用方拿屏幕内容匹配后绑定。
    static func candidateTranscripts(forCwd cwd: String, limit: Int = 4) -> [URL] {
        let dir = claudeProjectDir(forCwd: cwd)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "jsonl" }
            .sorted(by: { modDate($0) > modDate($1) })
            .prefix(limit)
            .map { $0 }
    }

    /// 读 transcript 尾部原始文本（不解析），供屏幕内容归属匹配用。
    static func tailText(of url: URL, maxBytes: UInt64 = 2 * 1024 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return "" }
        let start = end > maxBytes ? end - maxBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 从 transcript 尾部窗口解析轮次。工具输出重的会话一轮可占数 MB，2MB 起步、
    /// 轮次不够就翻倍扩窗，封顶 16MB（再早的轮次放弃——刻度条只展示近端）。
    static func recentTurns(
        fromTranscript url: URL, limit: Int, startedAt: Date? = nil
    ) -> [ConversationTurn] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return [] }
        var window: UInt64 = 2 * 1024 * 1024
        let cap: UInt64 = 16 * 1024 * 1024
        while true {
            let isWhole = window >= end
            let start = isWhole ? 0 : end - window
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.readToEnd() else { return [] }
            var text = String(decoding: data, as: UTF8.self)
            if start > 0, let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let turns = parseTurns(
                lines: lines, limit: limit, droppedHead: start > 0, startedAt: startedAt)
            if turns.count >= limit || isWhole || window >= cap { return turns }
            window *= 2
        }
    }

    private enum TurnEvent {
        case prompt(String, Date?)
        case reply(String)
        case compactBoundary(Date?)
    }

    /// userPrompt 开新轮，随后的 assistantText 累进该轮回答摘要（摘要够长即止）。
    /// 上下文压缩（compact）边界的截断规则看它发生在 agent 本次启动前还是后：
    /// 启动时 CC 只重绘最近边界之后的内容（更早的滚不到，必须截掉）；但启动后
    /// 进行中的 compact 不清屏，边界之前的轮次仍在屏上可浏览可跳达，不截。
    /// startedAt=nil 或边界无时间戳时保守截断（宁少显示不给跳不到的刻度）。
    static func parseTurns(
        lines: [Substring], limit: Int, droppedHead: Bool, startedAt: Date? = nil
    ) -> [ConversationTurn] {
        var acc: [(prompt: String, reply: String, ts: Date?)] = []
        // 窗口从中间截断时，第一个提问之前的行属于上一轮的残段，丢弃。
        var sawBoundary = !droppedHead
        for line in lines {
            guard let event = turnEvent(line) else { continue }
            switch event {
            case .prompt(let p, let ts):
                sawBoundary = true
                acc.append((prompt: p, reply: "", ts: ts))
            case .reply(let r):
                guard sawBoundary, !acc.isEmpty, acc[acc.count - 1].reply.count < 400 else { continue }
                let prev = acc[acc.count - 1].reply
                acc[acc.count - 1].reply = prev.isEmpty ? r : prev + "\n" + r
            case .compactBoundary(let ts):
                sawBoundary = true
                let cutsOff: Bool
                if let startedAt, let ts { cutsOff = ts < startedAt } else { cutsOff = true }
                if cutsOff { acc.removeAll() }
            }
        }
        return acc.suffix(limit).map { t in
            ConversationTurn(
                prompt: snip(t.prompt, 160), reply: snip(t.reply, 400), timestamp: t.ts)
        }
    }

    /// 单行 → 轮次事件。与 classify 同规则，但带出文本与时间戳；额外过滤
    /// 斜杠命令回显 / 注入元信息 / 中断标记这三类非真实提问。
    private static func turnEvent(_ line: Substring) -> TurnEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        if obj["isCompactSummary"] as? Bool == true {
            return .compactBoundary(parseTimestamp(obj["timestamp"] as? String))
        }
        if obj["isSidechain"] as? Bool == true { return nil }
        if obj["isMeta"] as? Bool == true { return nil }
        guard let message = obj["message"] as? [String: Any] else { return nil }
        let content = message["content"]

        switch type {
        case "user":
            var text: String?
            if let s = content as? String {
                text = s
            } else if let arr = content as? [[String: Any]] {
                let hasToolResult = arr.contains { ($0["type"] as? String) == "tool_result" }
                if !hasToolResult {
                    let parts = arr.compactMap { block -> String? in
                        guard (block["type"] as? String) == "text" else { return nil }
                        return block["text"] as? String
                    }
                    if !parts.isEmpty { text = parts.joined(separator: "\n") }
                }
            }
            guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
            else { return nil }
            if t.hasPrefix("This session is being continued") {
                return .compactBoundary(parseTimestamp(obj["timestamp"] as? String))
            }
            if t.hasPrefix("<command-") || t.hasPrefix("<local-command")
                || t.hasPrefix("[Request interrupted") { return nil }
            t = t.replacingOccurrences(of: "\n", with: " ")
            return .prompt(t, parseTimestamp(obj["timestamp"] as? String))

        case "assistant":
            if let arr = content as? [[String: Any]] {
                let texts = arr.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    let t = (block["text"] as? String) ?? ""
                    return t.isEmpty ? nil : t
                }
                if !texts.isEmpty { return .reply(texts.joined(separator: "\n")) }
            } else if let s = content as? String, !s.isEmpty {
                return .reply(s)
            }
            return nil

        default:
            return nil
        }
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoParser.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func snip(_ s: String, _ max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.prefix(max)) + "…"
    }
}
