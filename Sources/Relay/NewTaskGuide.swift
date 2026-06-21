// 新建任务引导（⌘⇧N）：选起始目录 + 可选首命令（claude / codex / 自定义），
// 一步把任务起在对的地方、对的 agent 上。⌘N 仍是「即时在当前目录起 shell」，
// 本 sheet 是显式的「精心新建」入口，二者并存。
import AppKit
import SwiftUI

struct NewTaskGuide: View {
    @ObservedObject var store = SessionStore.shared

    @State private var dir: String = ""
    @State private var starterKind: StarterKind = .none
    @State private var customCommand: String = ""
    /// 在仓库的独立 git worktree（新分支）里起任务，隔离 agent 改动。仅当目录在
    /// git 仓库内可勾。
    @State private var useWorktree = false

    /// 首命令预设。rawValue 即默认填入的命令（自定义除外）。
    enum StarterKind: String, CaseIterable, Identifiable {
        case none = ""
        case claude = "claude"
        case codex = "codex"
        case custom = "__custom__"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "纯 Shell"
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .custom: return "自定义命令"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建任务")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.fg0)

            templatesSection
            directorySection
            starterSection
            worktreeSection

            HStack(spacing: 10) {
                Button("存为模板") { saveAsTemplate() }
                    .font(.system(size: 11))
                    .disabled(dir.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("取消") { store.showNewTaskGuide = false }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dirUsable)
            }
            if !dirUsable {
                Text("起始目录不存在，请选择或填一个有效目录。")
                    .font(.system(size: 10)).foregroundColor(Theme.red)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.bg1)
        .onAppear {
            if dir.isEmpty { dir = store.defaultNewTaskDir() }
            // 套用设置里的默认启动方式（仅当表单仍是初始的纯 Shell 时）。
            if starterKind == .none,
               let k = StarterKind(rawValue: store.settings.defaultNewTaskStarter), k != .none {
                starterKind = k
            }
        }
    }

    /// 已存模板：点击套用到下面的表单（目录+启动），可删除。无模板时不显示。
    @ViewBuilder private var templatesSection: some View {
        if !store.settings.taskTemplates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("模板").font(.system(size: 11)).foregroundColor(Theme.fg2)
                ForEach(store.settings.taskTemplates) { t in
                    HStack(spacing: 8) {
                        Button { fillFrom(t) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "square.on.square").font(.system(size: 10))
                                Text(t.name).lineLimit(1)
                            }
                            .font(.system(size: 11))
                            .foregroundColor(Theme.fg0)
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 6)
                        Button { store.deleteTemplate(t.id) } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(Theme.fg3)
                        .help("删除此模板")
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.line.opacity(0.25)))
                }
            }
        }
    }

    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("起始目录").font(.system(size: 11)).foregroundColor(Theme.fg2)
            HStack(spacing: 8) {
                TextField("起始目录", text: $dir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("选择…") { chooseDirectory() }
                    .font(.system(size: 11))
            }
        }
    }

    private var starterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("启动").font(.system(size: 11)).foregroundColor(Theme.fg2)
            Picker("", selection: $starterKind) {
                ForEach(StarterKind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if starterKind == .custom {
                TextField("要执行的命令，如 npm run dev", text: $customCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
            Text(hint)
                .font(.system(size: 10)).foregroundColor(Theme.fg3)
        }
    }

    /// 独立 git worktree 开关：目录在仓库内才可勾。勾上则任务起在仓库根同级的
    /// 新 worktree（新分支 relay/<时间戳>），agent 改动与主工作区隔离。
    private var worktreeSection: some View {
        let isRepo = GitWorktree.isInsideRepo(dir)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $useWorktree) {
                Text("独立 git worktree（隔离分支）").font(.system(size: 11)).foregroundColor(Theme.fg2)
            }
            .toggleStyle(.checkbox)
            .disabled(!isRepo)
            Text(isRepo
                 ? "在仓库根旁新建 worktree + 分支 relay/…，任务起在那里；不自动删除，完事用 git worktree remove。"
                 : "所选目录不在 git 仓库内，无法隔离。")
                .font(.system(size: 10)).foregroundColor(Theme.fg3)
        }
        .onChange(of: dir) { _ in if !GitWorktree.isInsideRepo(dir) { useWorktree = false } }
    }

    private var hint: String {
        switch starterKind {
        case .none: return "在所选目录打开一个普通 shell。"
        case .claude: return "打开 shell 并在提示符就绪后执行 claude。"
        case .codex: return "打开 shell 并在提示符就绪后执行 codex。"
        case .custom: return "打开 shell 并在提示符就绪后执行上面的命令。"
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: dir.isEmpty ? store.defaultNewTaskDir() : dir)
        if panel.runModal() == .OK, let url = panel.url {
            dir = url.path
        }
    }

    /// 起始目录是否为可用目录（存在且是目录）。无效则禁用「创建」+ 红字提示，
    /// 杜绝「目录不可用 → 静默回落 home → 首命令在错误目录执行」。
    private var dirUsable: Bool {
        store.isUsableTaskDir(dir.trimmingCharacters(in: .whitespaces))
    }

    /// 当前表单对应的首命令（不含回车）；纯 shell / 空自定义 → nil。
    private func currentStarter() -> String? {
        switch starterKind {
        case .none: return nil
        case .custom:
            let c = customCommand.trimmingCharacters(in: .whitespaces)
            return c.isEmpty ? nil : c
        case .claude, .codex: return starterKind.rawValue
        }
    }

    private func create() {
        if useWorktree {
            store.newGuidedTaskInWorktree(dir: dir, starter: currentStarter())
        } else {
            store.newGuidedTask(cwd: dir, starter: currentStarter())
        }
        store.showNewTaskGuide = false
    }

    /// 套用模板：回填目录与启动方式（custom 还原命令文本）。
    private func fillFrom(_ t: TaskTemplate) {
        dir = t.cwd ?? store.defaultNewTaskDir()
        let s = (t.starter ?? "").trimmingCharacters(in: .whitespaces)
        switch s {
        case "": starterKind = .none
        case "claude": starterKind = .claude
        case "codex": starterKind = .codex
        default: starterKind = .custom; customCommand = s
        }
    }

    /// 把当前表单存为模板，名字按「启动 · 目录名」自动生成。
    private func saveAsTemplate() {
        let base = (dir as NSString).lastPathComponent
        let label = starterKind == .custom ? "命令" : starterKind.label
        let name = "\(label) · \(base.isEmpty ? "目录" : base)"
        store.saveTemplate(name: name, cwd: dir.isEmpty ? nil : dir, starter: currentStarter())
    }
}
