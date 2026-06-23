// 顶部标签条（参考 cmux 形态）：只显示「当前任务」的标签页，每个任务有
// 自己独立的一组 tab；⌘T / + 在当前任务内新建标签页，切任务时整条更换。
// 点击切换、hover 显示关闭、活动 tab 底部亮线。
import SwiftUI

struct TabStrip: View {
    @ObservedObject var store: SessionStore
    @State private var hoveredId: String?

    var body: some View {
        HStack(spacing: 6) {
            // Safari 式侧栏开关。侧栏收起时标签条顶到窗口左缘，
            // 红绿灯悬浮其上：留出避让位。
            toolButton("sidebar.left", help: "显示/隐藏侧边栏") {
                store.settings.sidebarVisible.toggle()
                store.applySettings()
            }
            .padding(.leading, store.settings.sidebarVisible ? 8 : 78)

            tabArea

            toolButton("plus", help: "新建标签页 ⌘T") { _ = store.newTab() }

            Rectangle().fill(Theme.line).frame(width: 1, height: 16)

            let canSplit = store.panes.count < 2
            toolButton("rectangle.split.2x1", help: "左右分屏 ⌘D", enabled: canSplit) {
                store.splitActive(.right)
            }
            toolButton("rectangle.split.1x2", help: "上下分屏", enabled: canSplit) {
                store.splitActive(.down)
            }
            .padding(.trailing, 12)
        }
        .frame(height: 38)
        // 不自己垫色：整窗唯一一层半透明底在 RootView（图45：色调完全一致）。
    }

    /// Safari 式标签区：单标签融入标题栏（居中、无标签盒），多标签均分整行宽度。
    @ViewBuilder private var tabArea: some View {
        let tabs = store.activeTabs
        if tabs.count <= 1 {
            if let s = tabs.first {
                singleTab(s).frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
        } else {
            // Safari 式：标签融在窗口底色上，相邻标签之间只有一道极细分隔。
            HStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { i, s in
                    if i > 0 {
                        Rectangle().fill(Theme.line.opacity(0.6))
                            .frame(width: 1, height: 14)
                    }
                    tab(s)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// 顶栏小工具按钮：统一尺寸/底色，禁用时降不透明度。
    private func toolButton(
        _ icon: String, help: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Theme.fg2)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    /// 单标签形态：无标签盒、无底线，徽标+名居中（Safari 单标签融合态）。
    /// hover 才浮现关闭按钮。
    private func singleTab(_ s: Session) -> some View {
        let hovered = hoveredId == s.id
        let ph = phaseOf(s)
        return HStack(spacing: 6) {
            EmblemView(kind: s.kind, phase: ph.key, size: 13)
            Text(s.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(Theme.fg0)
                .lineLimit(1)
            CloseButton(size: 7.5, baseOpacity: hovered ? 0.75 : 0) {
                store.confirmClose(s.id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hoveredId = $0 ? s.id : (hoveredId == s.id ? nil : hoveredId) }
        .contextMenu {
            Button("关闭标签页", role: .destructive) { store.confirmClose(s.id) }
        }
    }

    /// 多标签形态：每个标签均分整行宽度（Safari 自适应分割），内容居中。
    private func tab(_ s: Session) -> some View {
        let active = s.id == store.activeId
        let hovered = hoveredId == s.id
        let ph = phaseOf(s)
        return HStack(spacing: 6) {
            EmblemView(kind: s.kind, phase: ph.key, size: 13)
            Text(s.name)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundColor(active ? Theme.fg0 : Theme.fg2)
                .lineLimit(1)
            CloseButton(size: 7.5, baseOpacity: active || hovered ? 0.75 : 0) {
                store.confirmClose(s.id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        // Safari 式深度融合：活动标签只是一枚很淡的自适应浅色块
        //（暗色下白 10%、亮色下黑 10%），无亮盒无下划线；非活动全透明。
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(active ? Theme.pill.opacity(0.10)
                             : (hovered ? Theme.pill.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { store.show(s.id) }
        .onHover { hoveredId = $0 ? s.id : (hoveredId == s.id ? nil : hoveredId) }
        .contextMenu {
            Button("关闭标签页", role: .destructive) { store.confirmClose(s.id) }
        }
    }
}
