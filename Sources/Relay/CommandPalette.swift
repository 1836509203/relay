// 命令面板（⌘P）：把「一堆标签页」变成「工作台」的命门。
// 一个输入框模糊过滤，列表把所有会话按紧急度排序（出错 > 等待 > 思考 >
// 工作 > 完成 > 空闲），回车直达；末尾附常用命令。键盘全程可达：
// ↑/↓ 选择、⏎ 执行、Esc 关闭——经本地 NSEvent 监听实现（兼容 macOS 13，
// onKeyPress 需 14+）。
import AppKit
import SwiftUI

/// 列表项：会话跳转（带状态色点）或一条命令（带 SF 符号）。
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let dotColor: Color?      // 会话：状态色；命令：nil
    let symbol: String?       // 命令：SF 符号；会话：nil
    let run: () -> Void
}

/// 面板状态 + 键盘监听。引用类型，便于 NSEvent 监听闭包捕获并改状态。
final class CommandPaletteModel: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
    private var monitor: Any?

    private var store: SessionStore { .shared }

    // MARK: 生命周期

    func start() {
        query = ""; selection = 0
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            switch e.keyCode {
            case 125: self.move(1); return nil       // ↓
            case 126: self.move(-1); return nil      // ↑
            case 36, 76: self.runSelected(); return nil // ⏎ / 小键盘 Enter
            case 53: self.close(); return nil        // Esc
            default: return e                        // 其余交回输入框
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    func close() { store.showCommandPalette = false }

    // MARK: 数据

    /// 过滤后的列表：会话（按紧急度排序）+ 命令，统一子串匹配。
    func items() -> [PaletteItem] {
        let all = sessionItems() + commandItems()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { "\($0.title) \($0.subtitle)".lowercased().contains(q) }
    }

    private func sessionItems() -> [PaletteItem] {
        let rank: [DisplayPhase: Int] = [.error: 0, .waiting: 1, .thinking: 2, .working: 3, .done: 4, .idle: 5]
        let sorted = store.sessions.sorted { a, b in
            let ra = rank[phaseOf(a).key] ?? 9, rb = rank[phaseOf(b).key] ?? 9
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return sorted.map { s in
            let (phase, label) = phaseOf(s)
            return PaletteItem(
                id: "sess-\(s.id)", title: s.name,
                subtitle: "\(s.group) · \(label)",
                dotColor: Self.color(for: phase), symbol: nil,
                run: { [weak self] in self?.store.show(s.id); self?.close() }
            )
        }
    }

    private func commandItems() -> [PaletteItem] {
        let s = store
        func item(_ id: String, _ title: String, _ sub: String, _ sym: String, _ run: @escaping () -> Void) -> PaletteItem {
            PaletteItem(id: id, title: title, subtitle: sub, dotColor: nil, symbol: sym, run: run)
        }
        return [
            item("cmd-newtask", "新建任务…", "选目录与启动命令", "plus.rectangle.on.rectangle") { [weak self] in self?.close(); s.showNewTaskGuide = true },
            item("cmd-newtab", "新建标签页", "当前任务内", "plus") { [weak self] in s.newTab(); self?.close() },
            item("cmd-reopen", "撤销关闭标签页", "恢复最近关闭", "arrow.uturn.backward") { [weak self] in s.restoreLastClosed(); self?.close() },
            item("cmd-split", "左右分屏", "", "rectangle.split.2x1") { [weak self] in s.splitActive(); self?.close() },
            item("cmd-unsplit", "取消分屏", "", "rectangle") { [weak self] in s.unsplit(); self?.close() },
            item("cmd-search", "搜索终端内容", "", "magnifyingglass") { [weak self] in self?.close(); s.searchVisible = true },
            item("cmd-close", "关闭标签页", "", "xmark") { [weak self] in self?.close(); s.closeActive() },
        ]
    }

    // MARK: 交互

    func move(_ delta: Int) {
        let n = items().count
        guard n > 0 else { return }
        selection = (selection + delta + n) % n
    }

    func runSelected() {
        let rows = items()
        guard rows.indices.contains(selection) else { return }
        rows[selection].run()
    }

    static func color(for phase: DisplayPhase) -> Color {
        switch phase {
        case .error: return Theme.red
        case .waiting: return Theme.termAccent
        case .thinking: return Theme.think
        case .working: return Theme.claude
        case .done: return Theme.done
        case .idle: return Theme.fg3
        }
    }
}

struct CommandPalette: View {
    @StateObject private var model = CommandPaletteModel()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            list
        }
        .frame(width: 560, height: 420)
        .background(Theme.bg1)
        .onAppear { model.start(); focused = true }
        .onDisappear { model.stop() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 12)).foregroundColor(Theme.fg2)
            TextField("跳转到会话，或输入命令…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(Theme.fg0)
                .focused($focused)
                .onChange(of: model.query) { _ in model.selection = 0 }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    let rows = model.items()
                    if rows.isEmpty {
                        Text("无匹配")
                            .font(.system(size: 12)).foregroundColor(Theme.fg3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, item in
                        row(item, selected: idx == model.selection)
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selection = idx; model.runSelected() }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selection) { i in
                withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if let c = item.dotColor {
                Circle().fill(c).frame(width: 8, height: 8)
            } else if let sym = item.symbol {
                Image(systemName: sym).font(.system(size: 12)).foregroundColor(Theme.fg2).frame(width: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).foregroundColor(Theme.fg0)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 10.5)).foregroundColor(Theme.fg3)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(selected ? Theme.termAccent.opacity(0.18) : Color.clear)
    }
}
