// 进程树类型识别 —— Rust 版 proc.rs 的 Swift 移植。
//
// 一次 `ps` 快照拿到 (pid, ppid, command)，从会话 shell PID 向下遍历后代，
// 看实际在跑的是 claude / codex / ssh 还是普通 shell。比解析终端文本可靠：
// 反映「此刻真正运行的进程」，程序退出自动回落，也不会被文件名里出现
// claude 字样之类误判。
import Foundation

struct ProcTable {
    private let cmd: [pid_t: String]
    private let children: [pid_t: [pid_t]]

    /// 抓取当前进程表。`ps` 失败时返回空表（调用方跳过本轮，不崩）。
    static func snapshot() -> ProcTable {
        var cmd: [pid_t: String] = [:]
        var children: [pid_t: [pid_t]] = [:]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") {
                if let (pid, ppid, command) = parseLine(String(line)) {
                    cmd[pid] = command
                    children[ppid, default: []].append(pid)
                }
            }
        } catch {
            // ps 不可用：返回空表。
        }
        return ProcTable(cmd: cmd, children: children)
    }

    /// 判定某 shell 进程树的有效类型：agent（claude/codex/opencode）
    /// > remotion > ssh > shell。
    func classify(root: pid_t) -> WindowType {
        var stack = [root]
        var seen = Set<pid_t>()
        var foundRemotion = false
        var foundSSH = false

        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if let c = cmd[pid] {
                switch ProcTable.cmdType(c) {
                case .claude: return .claude
                case .codex: return .codex
                case .opencode: return .opencode
                case .remotion: foundRemotion = true
                case .ssh: foundSSH = true
                default: break
                }
            }
            if let ch = children[pid] { stack.append(contentsOf: ch) }
        }
        if foundRemotion { return .remotion }
        return foundSSH ? .ssh : .shell
    }

    /// 取进程树里第一个 ssh 进程的远端目标（best-effort）。
    func sshHost(root: pid_t) -> String? {
        var stack = [root]
        var seen = Set<pid_t>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if let c = cmd[pid], ProcTable.cmdType(c) == .ssh, let h = ProcTable.parseSSHHost(c) {
                return h
            }
            if let ch = children[pid] { stack.append(contentsOf: ch) }
        }
        return nil
    }

    /// 解析 `ps` 的一行："<pid> <ppid> <command...>"。
    static func parseLine(_ line: String) -> (pid_t, pid_t, String)? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3,
              let pid = pid_t(parts[0]),
              let ppid = pid_t(parts[1])
        else { return nil }
        let command = parts[2].trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        return (pid, ppid, command)
    }

    /// 由一行命令推断类型（仅看可执行名 + node/bun 包装兜底）。
    static func cmdType(_ cmd: String) -> WindowType? {
        let tokens = cmd.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first else { return nil }
        let base = first.split(separator: "/").last.map { $0.lowercased() } ?? ""
        switch base {
        case "claude": return .claude
        case "codex": return .codex
        case "opencode", "opencode-ai": return .opencode
        case "remotion": return .remotion
        case "ssh", "mosh", "mosh-client", "autossh", "sshpass", "et": return .ssh
        default: break
        }
        // npm/npx/pnpm/yarn/bunx 这类包管理器入口，真正 CLI 常在参数里。
        if ["npm", "npx", "pnpm", "pnpx", "yarn", "yarnpkg", "bunx"].contains(base) {
            if let type = packageCommandType(tokens.dropFirst().map(String.init)) {
                return type
            }
        }
        // node/bun/deno 包装的 CLI：优先看脚本路径的「路径段」，
        // 避免 `node server.js --claude-mode` 之类参数误判。
        if ["node", "node.js", "bun", "deno"].contains(base) {
            if let script = tokens.dropFirst().first(where: { !$0.hasPrefix("-") && $0 != "run" }) {
                let lc = script.lowercased()
                if lc.split(separator: "/").contains(where: { $0.contains("claude") }) { return .claude }
                if lc.split(separator: "/").contains(where: { $0.contains("codex") }) { return .codex }
                if lc.split(separator: "/").contains(where: { $0.contains("opencode") }) { return .opencode }
                if lc.split(separator: "/").contains(where: { $0.contains("remotion") }) { return .remotion }
            }
            if let type = packageCommandType(tokens.dropFirst().map(String.init)) {
                return type
            }
        }
        return nil
    }

    private static func packageCommandType(_ args: [String]) -> WindowType? {
        let normalized = args
            .filter { !$0.hasPrefix("-") && $0 != "exec" && $0 != "dlx" && $0 != "x" && $0 != "run" }
            .map { $0.lowercased() }
        for arg in normalized {
            let segments = arg.split(separator: "/")
            if segments.contains(where: { $0 == "claude" || $0.contains("claude-code") }) { return .claude }
            if segments.contains(where: { $0 == "codex" || $0.contains("openai-codex") }) { return .codex }
            if segments.contains(where: { $0 == "opencode" || $0 == "opencode-ai" }) { return .opencode }
            if segments.contains(where: { $0 == "remotion" || $0.hasPrefix("@remotion") }) { return .remotion }
        }
        return nil
    }

    /// 从 ssh 命令行解析远端（user@host 或 host），跳过常见带值短选项。
    static func parseSSHHost(_ cmd: String) -> String? {
        let flagWithArg: Set<String> = [
            "-p", "-i", "-o", "-l", "-F", "-L", "-R", "-D", "-W", "-e", "-b", "-c", "-m",
            "-O", "-Q", "-J", "-w", "-S",
        ]
        let tokens = cmd.split(separator: " ", omittingEmptySubsequences: true).dropFirst()
        var skipNext = false
        for t in tokens {
            if skipNext { skipNext = false; continue }
            let s = String(t)
            if s.hasPrefix("-") {
                if flagWithArg.contains(s) { skipNext = true }
                continue
            }
            return s
        }
        return nil
    }
}
