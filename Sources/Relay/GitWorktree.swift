// git worktree 隔离：为一个任务开仓库的独立工作树 + 新分支，让 agent 在隔离
// 副本上改动，不污染主工作区。纯本地操作（不涉及远端/鉴权）——一键 PR 另议。
//
// 路径约定：worktree 建在仓库根的同级目录 `<repo>-relay-<stamp>`，分支
// `relay/<stamp>`，便于用户在 Finder/编辑器里发现，且在 .git 之外（git 要求）。
// 不自动清理：worktree 里可能有未提交改动，删除由用户用 `git worktree remove`
// 显式决定。
import Foundation

enum GitWorktree {
    /// 廉价同步判断：path 或其某级祖先是否含 .git（普通仓库为目录、子 worktree
    /// 为文件，fileExists 都为真）。用于 UI 决定「独立 worktree」开关是否可用，
    /// 不 fork git，只做 stat。
    static func isInsideRepo(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var cur = (path as NSString).standardizingPath
        let fm = FileManager.default
        while !cur.isEmpty, cur != "/" {
            if fm.fileExists(atPath: cur + "/.git") { return true }
            let parent = (cur as NSString).deletingLastPathComponent
            if parent == cur { break }
            cur = parent
        }
        return false
    }

    /// 解析 path 所在仓库的根（顶层）目录；不在仓库内返回 nil。会 fork git，
    /// 应在后台队列调用。
    static func repoRoot(of path: String) -> String? {
        guard let out = run(["-C", path, "rev-parse", "--show-toplevel"]) else { return nil }
        let root = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    /// 在仓库 root 旁创建一个新 worktree（新分支），返回新 worktree 绝对路径 +
    /// 分支名。命令非零退出 / 目标已存在 → nil。会 fork git，应在后台队列调用。
    static func create(repoRoot root: String, stamp: Int) -> (path: String, branch: String)? {
        let name = (root as NSString).lastPathComponent
        let parent = (root as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return nil }
        let dest = parent + "/\(name)-relay-\(stamp)"
        let branch = "relay/\(stamp)"
        // 目标已存在则不覆盖（极小概率同秒撞名）：让上层回落普通任务。
        if FileManager.default.fileExists(atPath: dest) { return nil }
        guard run(["-C", root, "worktree", "add", dest, "-b", branch]) != nil else { return nil }
        return (dest, branch)
    }

    /// 同步跑 /usr/bin/git（Apple 的 git shim，build.sh 同款）。非零退出返回 nil。
    /// 先读尽 stdout 再 waitUntilExit，避免管道写满死锁；stderr 单独丢弃。
    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()   // 不读，命令出错信息量小不会填满缓冲
        do { try p.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
