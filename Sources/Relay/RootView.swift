// 主界面外壳：侧栏 + 标题条（当前会话徽标+名）+ 终端区。
// 状态变化提醒走系统通知中心，不在窗口内弹浮层（遮挡终端内容）。
import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var store = SessionStore.shared
    @ObservedObject var update = UpdateModel.shared
    /// 侧栏拖拽调宽：记拖动起始宽度（onChanged 按 translation 累加），松手清空。
    @State private var resizeStartWidth: Double?
    private static let sidebarMin: Double = 170
    private static let sidebarMax: Double = 460

    var body: some View {
        // 整窗只垫一层底色 = 当前生效主题的背景色 × bgOpacity。
        // 侧栏/标签条/终端区一律不再单独上色（图45 诉求：透明毛玻璃下
        // 整窗色调完全一致；多区域各垫一层必然色相不齐，叠乘还会吃掉透明度）。
        let termTheme = TerminalTheme.by(id: store.effectiveThemeId)
        let alpha = store.settings.bgOpacity
        HStack(spacing: 0) {
            if store.settings.sidebarVisible {
                SidebarView(store: store)
                    .transition(.move(edge: .leading))
                sidebarResizer
            }
            VStack(spacing: 0) {
                // 顶部更新条：发现新版/下载进度/校验/安装/失败的可见入口（占布局，不遮终端）。
                if update.isVisible {
                    UpdateBanner(model: update)
                }
                TabStrip(store: store)
                if store.searchVisible {
                    SearchBar()
                }
                // 图57：单标签时标签条与终端完全融合（无分隔线）；
                // 多标签时只隐隐约约显示一条提示分界。
                if store.activeTabs.count > 1 {
                    Rectangle().fill(Theme.line.opacity(0.35)).frame(height: 1)
                }
                terminalArea
                    .padding(CGFloat(store.settings.padding))
            }
        }
        .background(Color(hex: termTheme.bg).opacity(alpha).ignoresSafeArea())
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.18), value: store.settings.sidebarVisible)
        .animation(.easeInOut(duration: 0.2), value: update.isVisible)
        // 不强制 colorScheme：壳层明暗由窗口 appearance 驱动（applyWindowChrome），
        // Theme 动态色与 SwiftUI 语义色一起切。
    }

    /// 侧栏右缘可拖拽分隔条：1px 视觉线 + 加宽透明命中区（便于抓取），hover
    /// 显示左右调整光标，拖动实时改宽并钳制到 [min,max]，松手落盘。
    private var sidebarResizer: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                let start = resizeStartWidth ?? store.settings.sidebarWidth
                                if resizeStartWidth == nil { resizeStartWidth = start }
                                store.settings.sidebarWidth = min(
                                    Self.sidebarMax, max(Self.sidebarMin, start + v.translation.width))
                            }
                            .onEnded { _ in
                                resizeStartWidth = nil
                                store.persistSettings()
                            }
                    )
            }
    }

    @ViewBuilder private var terminalArea: some View {
        let panes = store.panes.filter { id in store.sessions.contains(where: { $0.id == id }) }
        if panes.isEmpty {
            VStack(spacing: 10) {
                EmblemView(kind: .shell, phase: .idle, size: 34)
                Text("没有打开的任务")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.fg2)
                Button("新建任务  ⌘N") { _ = store.newTask() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if panes.count == 1 {
            TerminalPane(sessionId: panes[0], fontSize: store.settings.fontSize)
                .id(panes[0]) // 切会话时重新挂载对应常驻视图
        } else if store.splitVertical {
            // 上下分屏：VSplitView 可拖分隔条；聚焦 pane 加 1px 描边提示。
            VSplitView {
                ForEach(panes, id: \.self) { id in
                    TerminalPane(sessionId: id, fontSize: store.settings.fontSize)
                        .id(id)
                        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                        .border(id == store.activeId ? Theme.termAccent.opacity(0.35) : Color.clear, width: 1)
                }
            }
        } else {
            // 左右分屏：HSplitView 可拖分隔条；聚焦 pane 加 1px 描边提示。
            HSplitView {
                ForEach(panes, id: \.self) { id in
                    TerminalPane(sessionId: id, fontSize: store.settings.fontSize)
                        .id(id)
                        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                        .border(id == store.activeId ? Theme.termAccent.opacity(0.35) : Color.clear, width: 1)
                }
            }
        }
    }

}
