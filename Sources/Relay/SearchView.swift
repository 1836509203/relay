// ⌘F 终端内容搜索：跳转/高亮走 SwiftTerm 内置 SearchEngine
//（findNext/findPrevious 自带结果选中高亮 + 滚动定位）；匹配总数
// 内置引擎不暴露，仍用 getScrollInvariantLine 自己扫一遍计数。
import SwiftUI
import SwiftTerm

struct SearchBar: View {
    @ObservedObject var store = SessionStore.shared
    @State private var query = ""
    @State private var matchCount = 0
    @State private var current = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Theme.fg2)
            TextField("搜索终端内容", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.fg0)
                .focused($focused)
                .onSubmit { jump(1) }
                .onChange(of: query) { _ in research() }
            Text(matchCount == 0 ? (query.isEmpty ? "" : "无匹配") : "\(current + 1)/\(matchCount)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundColor(Theme.fg2)
                .frame(minWidth: 52, alignment: .trailing)
            Button { jump(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundColor(Theme.fg2)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(matchCount == 0)
            Button { jump(1) } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundColor(Theme.fg2)
                .keyboardShortcut("g", modifiers: .command)
                .disabled(matchCount == 0)
            Button { closeBar() } label: { Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)) }
                .buttonStyle(.plain).foregroundColor(Theme.fg2)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.bg2)
        .onAppear { focused = true }
        .onExitCommand { closeBar() }
    }

    private func closeBar() {
        store.searchVisible = false
        if let v = store.activeView {
            v.clearSearch() // 清掉结果高亮
            v.window?.makeFirstResponder(v)
        }
    }

    /// query 变化：重数匹配总行数 + 定位到最后一个匹配（最新输出附近，
    /// 从底部往上找第一个 = 最后一处，更符合回看直觉）。
    /// 总数扫描用 getScrollInvariantLine —— getLine 只覆盖可见视口；
    /// 行号是会话起算的绝对值，必须用 scrollInvariantRowRange（长会话
    /// linesTop 巨大，从 0 数起永远撞不到数据段）。
    private func research() {
        matchCount = 0
        current = 0
        guard let v = store.activeView else { return }
        v.clearSearch()
        let q = query.lowercased()
        guard !q.isEmpty else { return }
        let t = v.getTerminal()
        for row in t.scrollInvariantRowRange {
            guard let line = t.getScrollInvariantLine(row: row) else { continue }
            let text = line.translateToString(
                trimRight: true, skipNullCellsFollowingWide: true, characterProvider: plainCell)
            if text.lowercased().contains(q) {
                matchCount += 1
            }
        }
        if matchCount > 0, v.findPrevious(query) {
            current = matchCount - 1
        }
    }

    /// 上一处/下一处：内置引擎从当前选中处继续找，到头自动回绕；
    /// current 仅用于计数显示，与引擎同步按同方向回绕递增。
    private func jump(_ delta: Int) {
        guard matchCount > 0, let v = store.activeView else { return }
        let found = delta > 0 ? v.findNext(query) : v.findPrevious(query)
        guard found else { return }
        current = (current + delta + matchCount) % matchCount
    }
}
