// ⌘F 终端内容搜索：跳转/高亮走 SwiftTerm 内置 SearchEngine
//（findNext/findPrevious 自带结果选中高亮 + 滚动定位，且接受 SearchOptions
// 控制大小写/正则/全词）；匹配总数内置引擎不暴露，仍用 getScrollInvariantLine
// 自己扫一遍计数——计数口径与引擎对齐（同一套 SearchOptions 编译的谓词）。
import SwiftUI
import SwiftTerm

struct SearchBar: View {
    @ObservedObject var store = SessionStore.shared
    @State private var query = ""
    @State private var matchCount = 0
    @State private var current = 0
    @State private var caseSensitive = false
    @State private var useRegex = false
    @State private var wholeWord = false
    @State private var invalidRegex = false
    @FocusState private var focused: Bool

    /// 当前开关编译出的引擎检索选项。
    private var options: SearchOptions {
        SearchOptions(caseSensitive: caseSensitive, regex: useRegex, wholeWord: wholeWord)
    }

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

            // 检索开关：大小写 / 正则 / 全词。改动即重搜。
            toggle("Aa", on: $caseSensitive, help: "区分大小写")
            toggle(".*", on: $useRegex, help: "正则表达式")
            toggle("W", on: $wholeWord, help: "全字匹配")

            Text(countLabel)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundColor(invalidRegex ? Theme.red : Theme.fg2)
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

    /// 紧凑的检索开关按钮：开启时高亮 + 衬底，关闭时弱化。
    private func toggle(_ label: String, on: Binding<Bool>, help: String) -> some View {
        Button { on.wrappedValue.toggle(); research() } label: {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(on.wrappedValue ? Theme.bg0 : Theme.fg3)
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(on.wrappedValue ? Theme.termAccent : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var countLabel: String {
        if invalidRegex { return "正则无效" }
        if matchCount == 0 { return query.isEmpty ? "" : "无匹配" }
        return "\(current + 1)/\(matchCount)"
    }

    private func closeBar() {
        store.searchVisible = false
        if let v = store.activeView {
            v.clearSearch() // 清掉结果高亮
            v.window?.makeFirstResponder(v)
        }
    }

    /// query / 开关变化：重数匹配总行数 + 定位到最后一个匹配（最新输出附近，
    /// 从底部往上找第一个 = 最后一处，更符合回看直觉）。
    /// 总数扫描用 getScrollInvariantLine —— getLine 只覆盖可见视口；
    /// 行号是会话起算的绝对值，必须用 scrollInvariantRowRange（长会话
    /// linesTop 巨大，从 0 数起永远撞不到数据段）。
    private func research() {
        matchCount = 0
        current = 0
        invalidRegex = false
        guard let v = store.activeView else { return }
        v.clearSearch()
        guard !query.isEmpty else { return }
        guard let predicate = makePredicate() else {
            invalidRegex = true   // 正则非法：不检索，红字提示
            return
        }
        let t = v.getTerminal()
        for row in t.scrollInvariantRowRange {
            guard let line = t.getScrollInvariantLine(row: row) else { continue }
            let text = line.translateToString(
                trimRight: true, skipNullCellsFollowingWide: true, characterProvider: plainCell)
            if predicate(text) { matchCount += 1 }
        }
        if matchCount > 0, v.findPrevious(query, options: options) {
            current = matchCount - 1
        }
    }

    /// 上一处/下一处：内置引擎从当前选中处继续找，到头自动回绕；
    /// current 仅用于计数显示，与引擎同步按同方向回绕递增。
    private func jump(_ delta: Int) {
        guard matchCount > 0, let v = store.activeView else { return }
        let found = delta > 0 ? v.findNext(query, options: options) : v.findPrevious(query, options: options)
        guard found else { return }
        current = (current + delta + matchCount) % matchCount
    }

    /// 把当前开关编译成「逐行是否命中」的谓词，使自数计数与引擎口径一致。
    /// 正则非法返回 nil（调用方据此提示）。非正则/全词时用 contains 快路径。
    private func makePredicate() -> ((String) -> Bool)? {
        if useRegex || wholeWord {
            var pattern = useRegex ? query : NSRegularExpression.escapedPattern(for: query)
            if wholeWord { pattern = "\\b" + pattern + "\\b" }
            var ro: NSRegularExpression.Options = []
            if !caseSensitive { ro.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: pattern, options: ro) else { return nil }
            return { s in
                re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            }
        }
        if caseSensitive { return { $0.contains(query) } }
        let lc = query.lowercased()
        return { $0.lowercased().contains(lc) }
    }
}
