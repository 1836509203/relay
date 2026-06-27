import AppKit
import SwiftUI

struct TabStrip: View {
    @ObservedObject var store: SessionStore
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hoveredTab: String?
    private let tabSpacing: CGFloat = 8
    private let tabHorizontalPadding: CGFloat = 6
    private let minTabWidth: CGFloat = 116
    private let maxTabWidth: CGFloat = 420
    private let collapsedSidebarButtonLeading: CGFloat = 88

    private var windowActive: Bool {
        controlActiveState != .inactive
    }

    private var labelFontSize: CGFloat {
        max(12, CGFloat(store.settings.uiFontSize - 1))
    }

    private var iconFontSize: CGFloat {
        max(11, CGFloat(store.settings.uiFontSize - 2))
    }

    private var closeFontSize: CGFloat {
        max(7.5, CGFloat(store.settings.uiFontSize - 6))
    }

    var body: some View {
        HStack(spacing: 8) {
            if !store.settings.sidebarVisible {
                toolButton("sidebar.left", help: "显示/隐藏侧边栏") {
                    store.settings.sidebarVisible.toggle()
                    store.applySettings()
                }
                .padding(.leading, collapsedSidebarButtonLeading)
            }

            if store.activeTabs.count > 1 {
                tabList
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 12)
            }

            topMenu
            toolButton("plus", help: "新建标签页 ⌘T") { _ = store.newTab() }

            Rectangle().fill(Theme.chromeLine).frame(width: 1, height: 18)

            let canSplit = store.panes.count < 2
            toolButton("rectangle.split.2x1", help: "左右分屏 ⌘D", enabled: canSplit) {
                store.splitActive(.right)
            }
            toolButton("rectangle.split.1x2", help: "上下分屏", enabled: canSplit) {
                store.splitActive(.down)
            }
            .padding(.trailing, 12)
        }
        .frame(height: 42)
        .background(alignment: .bottom) {
            if store.activeTabs.count > 1 {
                TabGlassMaterial(material: .titlebar, windowActive: windowActive, alpha: windowActive ? 0.20 : 0.10)
                    .frame(height: 33)
            }
        }
    }

    private var tabList: some View {
        GeometryReader { proxy in
            let widths = tabWidths(for: store.activeTabs, availableWidth: proxy.size.width)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: tabSpacing) {
                    ForEach(store.activeTabs) { tab in
                        tabCell(tab, width: widths[tab.id] ?? tabWidth(tab, canClose: store.activeTabs.count > 1))
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, tabHorizontalPadding)
            }
            .frame(width: proxy.size.width, height: 38, alignment: .leading)
            .background {
                Capsule(style: .continuous)
                    .fill(Theme.pill.opacity(windowActive ? 0.045 : 0.025))
                    .overlay {
                        TabGlassMaterial(material: .titlebar, windowActive: windowActive, alpha: windowActive ? 0.26 : 0.12)
                            .clipShape(Capsule(style: .continuous))
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Theme.pill.opacity(windowActive ? 0.08 : 0.04), lineWidth: 1)
                    }
                    .padding(.horizontal, tabHorizontalPadding)
                    .padding(.vertical, 5)
            }
        }
        .frame(height: 38, alignment: .leading)
        .clipped()
    }

    private func tabCell(_ tab: Session, width: CGFloat) -> some View {
        let active = tab.id == store.activeId
        let hovered = hoveredTab == tab.id
        let phase = phaseOf(tab).key
        let canClose = store.activeTabs.count > 1
        let contentWidth = max(42, width - (canClose ? 74 : 28))

        return ZStack {
            HStack(spacing: 7) {
                EmblemView(kind: tab.kind, phase: phase, size: 14)
                    .frame(width: 14, height: 14)

                Text(tab.name)
                    .font(Theme.uiFont(size: labelFontSize, weight: active ? .semibold : .medium))
                    .foregroundColor(active ? Theme.fg0 : Theme.fg2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: max(32, contentWidth - 22), alignment: .center)
            }
            .frame(maxWidth: contentWidth, alignment: .center)

            if canClose {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        store.confirmClose(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: closeFontSize, weight: .bold))
                            .foregroundColor(active || hovered ? Theme.fg2 : Theme.fg3)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(hovered ? Theme.pill.opacity(0.12) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .opacity(active || hovered ? 1 : 0)
                    .allowsHitTesting(active || hovered)
                    .help("关闭标签页")
                }
                .padding(.trailing, 8)
            }
        }
        .frame(width: width, height: 28, alignment: .leading)
        .background(
            ZStack {
                TabGlassMaterial(
                    material: active ? .hudWindow : .titlebar,
                    windowActive: windowActive,
                    alpha: tabGlassAlpha(active: active, hovered: hovered)
                )
                Capsule(style: .continuous)
                    .fill(tabFill(active: active, hovered: hovered))
            }
            .clipShape(Capsule(style: .continuous))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(tabStroke(active: active, hovered: hovered), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.show(tab.id) }
        .onHover { inside in
            hoveredTab = inside ? tab.id : (hoveredTab == tab.id ? nil : hoveredTab)
        }
        .contextMenu {
            Button("切换到此标签页") { store.show(tab.id) }
            Button("关闭标签页", role: .destructive) { store.confirmClose(tab.id) }
        }
        .help(tab.name)
    }

    private func tabWidth(_ tab: Session, canClose: Bool) -> CGFloat {
        let chromeWidth: CGFloat = canClose ? 60 : 40
        return min(maxTabWidth, max(minTabWidth, tabTextWidth(tab) + chromeWidth))
    }

    private func tabWidths(for tabs: [Session], availableWidth: CGFloat) -> [String: CGFloat] {
        guard !tabs.isEmpty else { return [:] }
        let spacingWidth = tabSpacing * CGFloat(max(0, tabs.count - 1))
        let contentWidth = max(0, availableWidth - tabHorizontalPadding * 2 - spacingWidth)
        let equalWidth = floor(contentWidth / CGFloat(tabs.count))
        let widths = Array(repeating: max(minTabWidth, equalWidth), count: tabs.count)
        return Dictionary(uniqueKeysWithValues: zip(tabs.map(\.id), widths))
    }

    private func tabFill(active: Bool, hovered: Bool) -> Color {
        if active { return Theme.pill.opacity(windowActive ? 0.12 : 0.07) }
        if hovered { return Theme.pill.opacity(windowActive ? 0.08 : 0.045) }
        return Theme.pill.opacity(windowActive ? 0.035 : 0.02)
    }

    private func tabStroke(active: Bool, hovered: Bool) -> Color {
        if active { return Theme.pill.opacity(windowActive ? 0.26 : 0.14) }
        if hovered { return Theme.pill.opacity(windowActive ? 0.16 : 0.08) }
        return Theme.pill.opacity(windowActive ? 0.08 : 0.04)
    }

    private func tabGlassAlpha(active: Bool, hovered: Bool) -> CGFloat {
        if active { return windowActive ? 0.74 : 0.42 }
        if hovered { return windowActive ? 0.42 : 0.22 }
        return windowActive ? 0.28 : 0.14
    }

    private func tabTextWidth(_ tab: Session) -> CGFloat {
        let units = tab.name.reduce(0) { total, ch in
            total + (ch.unicodeScalars.allSatisfy { $0.value < 128 } ? 1 : 2)
        }
        return min(180, max(32, CGFloat(units) * max(6.6, labelFontSize * 0.56)))
    }

    private var topMenu: some View {
        Menu {
            Button("新建标签页") { _ = store.newTab() }
            Button("左右分屏") { store.splitActive(.right) }
                .disabled(store.panes.count >= 2)
            Button("上下分屏") { store.splitActive(.down) }
                .disabled(store.panes.count >= 2)
            Button("取消分屏") { store.unsplit() }
                .disabled(store.panes.count <= 1)
            Divider()
            Button("关闭标签页", role: .destructive) { store.closeActive() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: labelFontSize, weight: .semibold))
                .foregroundColor(Theme.fg2)
                .frame(width: 25, height: 25)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chromeControl))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("更多")
    }

    private func toolButton(
        _ icon: String, help: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconFontSize, weight: .semibold))
                .foregroundColor(Theme.fg2)
                .frame(width: 25, height: 25)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chromeControl))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }
}

private struct TabGlassMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let windowActive: Bool
    let alpha: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = windowActive ? .active : .inactive
        view.isEmphasized = false
        view.alphaValue = alpha
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = .withinWindow
        view.state = windowActive ? .active : .inactive
        view.isEmphasized = false
        view.alphaValue = alpha
    }
}
