// 诊断中心：轻量事件日志（环形缓冲）+ 崩溃标记 + ⌘⇧I 面板。
// 目的：告别清一色 try? 静默吞 —— 关键失败（启动失败、异常退出、hook 未就绪）
// 留痕可见，并对最严重的一类弹系统通知。SIGKILL/OOM 无法在进程内捕获，
// 改用「运行标记」事后判定：启动时残留即上次异常退出。
import Foundation
import SwiftUI
import UserNotifications

final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()

    enum Level: String { case info, warn, error }

    struct Entry: Identifiable {
        let id: Int
        let time: Date
        let level: Level
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    private var counter = 0
    private static let cap = 200

    /// 进程运行标记：启动写入、洁净退出删除。下次启动若仍在 = 上次没走到
    /// applicationWillTerminate（崩溃 / 被强杀 / 内存不足）。
    private var markerURL: URL { DataDir.url.appendingPathComponent("running.marker") }

    private init() {}

    // MARK: - 记录

    func log(_ level: Level, _ message: String) {
        let entry = { [weak self] in
            guard let self else { return }
            self.counter += 1
            self.entries.append(Entry(id: self.counter, time: Date(), level: level, message: message))
            if self.entries.count > Self.cap { self.entries.removeFirst(self.entries.count - Self.cap) }
        }
        if Thread.isMainThread { entry() } else { DispatchQueue.main.async(execute: entry) }
        if level == .error || level == .warn {
            FileHandle.standardError.write(Data("[diag] \(level.rawValue): \(message)\n".utf8))
        }
    }

    // MARK: - 崩溃标记

    /// 应用启动时调用：先判定上次是否异常退出，再（重新）落下运行标记。
    func onLaunch() {
        let fm = FileManager.default
        if fm.fileExists(atPath: markerURL.path) {
            log(.warn, "上次异常退出（崩溃 / 被强杀 / 内存不足）。回看历史已恢复到最近一次自动保存（每 5 秒），最后几秒的输出可能缺失。")
            notifyCrash()
        }
        try? Data("running".utf8).write(to: markerURL, options: .atomic)
        log(.info, "Relay \(Updater.currentVersion) 启动")
    }

    /// 洁净退出（applicationWillTerminate）：移除标记。
    func onCleanExit() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    private func notifyCrash() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Relay 上次异常退出"
        content.body = "已恢复到最近一次自动保存的会话历史。"
        let req = UNNotificationRequest(
            identifier: "diag-crash", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - 面板信息

    /// 诊断面板顶部的运行环境概览（键值对）。
    func appInfo() -> [(String, String)] {
        let store = SessionStore.shared
        let hook = store.hookServer
        let hookStatus = (hook?.port ?? 0) > 0 ? "就绪 :\(hook!.port)" : "未就绪（退化为启发式状态检测）"
        let tasks = store.sessions.filter { $0.parentId == nil }.count
        return [
            ("版本", Updater.currentVersion),
            ("数据目录", DataDir.url.path),
            ("Hook 服务", hookStatus),
            ("任务 / 标签页", "\(tasks) / \(store.sessions.count)"),
            ("GPU 渲染", store.settings.gpuRender ? "开（Metal）" : "关（CPU）"),
            ("减弱动效", NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "开" : "关"),
        ]
    }

    /// 「复制全部」用：环境概览 + 全部事件的纯文本。
    func exportText() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        var lines = appInfo().map { "\($0.0): \($0.1)" }
        lines.append("")
        lines.append(contentsOf: entries.map { "[\(fmt.string(from: $0.time))] \($0.level.rawValue.uppercased()) \($0.message)" })
        return lines.joined(separator: "\n")
    }
}

// MARK: - 面板视图

struct DiagnosticsView: View {
    @ObservedObject var diag = Diagnostics.shared

    private let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("诊断")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.fg0)

            infoGrid
            Divider()
            eventList
            actions
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .background(Theme.bg1)
    }

    private var infoGrid: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(diag.appInfo(), id: \.0) { row in
                HStack(alignment: .top, spacing: 10) {
                    Text(row.0)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.fg2)
                        .frame(width: 96, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.fg0)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("事件日志")
                .font(.system(size: 11)).foregroundColor(Theme.fg2)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if diag.entries.isEmpty {
                        Text("暂无事件")
                            .font(.system(size: 11)).foregroundColor(Theme.fg3)
                    }
                    ForEach(diag.entries.reversed()) { e in
                        HStack(alignment: .top, spacing: 8) {
                            Text(timeFmt.string(from: e.time))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.fg3)
                            Circle().fill(color(for: e.level)).frame(width: 6, height: 6)
                                .padding(.top, 4)
                            Text(e.message)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.fg0)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("复制全部") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(diag.exportText(), forType: .string)
            }
            .font(.system(size: 11))
            Button("打开数据目录") {
                NSWorkspace.shared.open(DataDir.url)
            }
            .font(.system(size: 11))
            Spacer()
        }
    }

    private func color(for level: Diagnostics.Level) -> Color {
        switch level {
        case .info: return Theme.fg3
        case .warn: return Theme.termAccent
        case .error: return Theme.red
        }
    }
}
