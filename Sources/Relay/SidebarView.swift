// 左侧任务栏：每行一个任务（任务 = 一组标签页，TabStrip 显示当前任务的标签页）。
// 行内徽标/状态取「最值得注意」的标签页聚合（representativeTab）。
//
// 不用 LazyVStack：会话跨分组移动（shell → claude 识别后换组）时，Lazy 容器
// 会复用旧分组里的 row 视图导致图标/状态卡在旧值（TabStrip 用普通 HStack 无此
// 问题，实测对照定位）。任务数量级几十，Lazy 本无收益。
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @State private var query = ""
    @State private var renamingId: String?

    private var filteredTasks: [Session] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.tasks }
        return store.tasks.filter { root in
            store.tabs(ofTask: root.id).contains {
                "\($0.name) \($0.group) \($0.kind.label) \($0.host ?? "")".lowercased().contains(q)
            }
        }
    }

    /// 按住 ⌘ 时任务的快捷角标序号（⌘1-9，按 store.tasks 创建顺序，与
    /// selectTask(index:) 的口径一致——搜索过滤不影响编号）。
    private func cmdIndex(of root: Session) -> Int? {
        guard store.cmdHeld,
              let i = store.tasks.firstIndex(where: { $0.id == root.id }), i < 9 else { return nil }
        return i + 1
    }

    private var groups: [(String, [Session])] {
        var order: [String] = []
        var map: [String: [Session]] = [:]
        for s in filteredTasks {
            if map[s.group] == nil { order.append(s.group) }
            map[s.group, default: []].append(s)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 给系统交通灯留出空间
            Spacer().frame(height: 38)

            searchField
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.0) { group, items in
                        Text(group)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(Theme.fg2)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                        ForEach(items) { root in
                            TaskRow(
                                store: store,
                                root: root,
                                tabs: store.tabs(ofTask: root.id),
                                isActive: store.activeId.map { store.taskId(of: $0) == root.id } ?? false,
                                hasUnread: store.hasUnread(taskOf: root.id),
                                cmdIndex: cmdIndex(of: root),
                                isRenaming: renamingId == root.id,
                                beginRename: { renamingId = root.id },
                                endRename: { renamingId = nil }
                            )
                        }
                    }
                    if filteredTasks.isEmpty {
                        Text(store.tasks.isEmpty ? "还没有任务。\n点下方按钮新建。" : "未找到匹配「\(query)」的任务。")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.fg2)
                            .padding(.top, 32)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.bottom, 8)
            }

            newButton
        }
        .frame(width: 232)
        // 不自己垫色：整窗唯一一层半透明底在 RootView（图45：色调完全一致）。
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundColor(Theme.fg2)
            TextField("搜索任务", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.fg0)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(Theme.fg2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pill.opacity(0.08)))
        .padding(.horizontal, 12)
    }

    private var newButton: some View {
        Button {
            _ = store.newTask()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text("新建任务").font(.system(size: 12.5, weight: .medium))
            }
            .foregroundColor(Theme.fg0)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            // 半透明底上不用实心 bg2 色块（对比太高），与活动标签同款淡色。
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.pill.opacity(0.08)))
        }
        .buttonStyle(.plain) // ⌘N 由主菜单提供，这里不重复绑定（避免双触发）
        .padding(10)
    }
}

/// 任务行（独立 struct：所有渲染字段都是存储属性，SwiftUI diff 必然跟到最新值）。
private struct TaskRow: View {
    let store: SessionStore
    let root: Session
    let tabs: [Session]
    let isActive: Bool
    let hasUnread: Bool
    let cmdIndex: Int?
    let isRenaming: Bool
    let beginRename: () -> Void
    let endRename: () -> Void

    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let rep = representativeTab(of: tabs) ?? root
        let ph = phaseOf(rep)
        HStack(spacing: 9) {
            EmblemView(kind: rep.kind, phase: ph.key, size: 19)
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    renameField
                } else {
                    Text(root.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(isActive ? Theme.fg0 : Theme.fg0.opacity(0.85))
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(ph.label)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.phaseColor(ph.key))
                    if tabs.count > 1 {
                        Text("· \(tabs.count) 标签页")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.fg2)
                    }
                }
            }
            Spacer(minLength: 0)
            if let n = cmdIndex {
                // 按住 ⌘：显示快捷角标（替代尾部控件，松开恢复）。
                Text("⌘\(n)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.fg0.opacity(0.9))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.pill.opacity(0.12)))
            } else {
                // 完成/出错未回看：亮点提示（点开任务即清，applyStatus 里标记）。
                if hasUnread {
                    Circle()
                        .fill(Theme.termAccent)
                        .frame(width: 6, height: 6)
                        .shadow(color: Theme.termAccent.opacity(0.7), radius: 3)
                }
                CloseButton(size: 8.5, baseOpacity: isActive ? 0.8 : 0.35) {
                    store.confirmCloseTask(root.id)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            // 与活动标签同款淡色（pill 自适应：暗色下白、亮色下黑），
            // 实心 bg2 在半透明底上对比太高。
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Theme.pill.opacity(0.10) : Color.clear)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        // 双击重命名；单击用 simultaneousGesture：普通 .gesture 会等
        // ~250ms 双击判定窗口结束才触发，点任务切换显得卡顿（图58）。
        // simultaneous 让单击立即切换；双击时第一击先切到本行（无害），
        // 第二击进入重命名。
        .gesture(TapGesture(count: 2).onEnded { startRename() })
        .simultaneousGesture(TapGesture().onEnded { store.showTask(root.id) })
        .contextMenu {
            Button("重命名") { startRename() }
            Button("新建标签页") { store.showTask(root.id); _ = store.newTab() }
            Button("关闭任务", role: .destructive) { store.confirmCloseTask(root.id) }
        }
    }

    private var renameField: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(Theme.fg0)
            .focused($renameFocused)
            .onSubmit { commit() }
            .onExitCommand { endRename() } // Esc 取消
            .onChange(of: renameFocused) { focused in
                if !focused { commit() } // 点别处 = 提交（用户预期：输入的字不该丢）
            }
    }

    private func startRename() {
        draft = root.name
        beginRename()
        // 等 TextField 挂载后再抢焦点，否则焦点仍在终端、输入会打进 shell。
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commit() {
        store.rename(root.id, to: draft)
        endRename()
    }
}
