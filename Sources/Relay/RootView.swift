// 主界面外壳：侧栏 + 顶部工具条 + 终端区。
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
        let mainBackground = mainWorkspaceBackground
        let sidebarAnimation = Animation.easeInOut(duration: store.reduceMotionEnabled ? 0 : 0.18)
        let settingsAnimation = Animation.easeInOut(duration: store.reduceMotionEnabled ? 0 : 0.16)
        let updateAnimation = Animation.easeInOut(duration: store.reduceMotionEnabled ? 0 : 0.2)
        Group {
            if store.settingsVisible {
                SettingsView(onClose: {
                    store.closeSettings()
                })
                .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    if store.settings.sidebarVisible {
                        SidebarView(store: store)
                            .transition(.move(edge: .leading))
                        sidebarResizer
                    }
                    VStack(spacing: 0) {
                        TabStrip(store: store)
                        if update.isVisible {
                            UpdateBanner(model: update)
                        }
                        if store.searchVisible {
                            SearchBar()
                        }
                        mainContent
                    }
                    .background(mainBackground)
                }
            }
        }
        .background {
            rootWindowBackground(mainBackground)
                .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .animation(sidebarAnimation, value: store.settings.sidebarVisible)
        .animation(settingsAnimation, value: store.settingsVisible)
        .animation(updateAnimation, value: update.isVisible)
        .animation(settingsAnimation, value: store.settings.motionPreference)
    }

    /// 侧栏右缘可拖拽分隔条：1px 视觉线 + 加宽透明命中区（便于抓取），hover
    /// 显示左右调整光标，拖动实时改宽并钳制到 [min,max]，松手落盘。
    private var sidebarResizer: some View {
        Rectangle()
            .fill(Theme.chromeLine)
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

    private var mainWorkspaceBackground: Color {
        Color(hex: store.effectiveTheme.bg)
            .opacity(store.settings.bgOpacity)
    }

    @ViewBuilder private func rootWindowBackground(_ mainBackground: Color) -> some View {
        if store.settings.sidebarVisible && store.settings.translucentSidebar {
            Color.clear
        } else {
            mainBackground
        }
    }

    private var mainContent: some View {
        let padding = CGFloat(store.settings.padding)
        return terminalArea
            .padding(EdgeInsets(top: max(4, padding - 2), leading: padding, bottom: padding, trailing: padding))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var terminalArea: some View {
        let panes = store.panes.filter { id in store.sessions.contains(where: { $0.id == id }) }
        if panes.isEmpty {
            VStack(spacing: 10) {
                EmblemView(kind: .shell, phase: .idle, size: 34)
                Text("没有打开的任务")
                    .font(Theme.uiFont(size: 13))
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
