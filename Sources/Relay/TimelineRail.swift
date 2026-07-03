// 侧栏收起时的对话时间轴（Codex 式）：窗口左缘一列小横线，一条线 = 活动
// Claude 会话的一轮对话（用户提问 + 回答）。静默态是一列安静的细线（最新一轮
// 最亮）；鼠标滑过时按与光标的距离做鱼眼式联动伸长（最近的最长、邻近渐次衰减），
// 并在最近的刻度旁弹出该轮预览（提问 + 回答开头）。点击跳转走两阶段闭环
// 滚动（SessionStore.jumpToTurn）。只展示当前会话的轮次：最后一个 compact
// 边界之前的历史已被 CC 换成摘要，跳不到，不给刻度。
// 数据来自 CC transcript（AgentTranscript.recentTurns），onTick 轮询驱动刷新。
import SwiftUI

struct TimelineRail: View {
    @ObservedObject var store: SessionStore
    /// 光标在刻度列内容坐标系里的 y（onContinuousHover 连续更新）；nil = 未悬浮。
    @State private var mouseY: CGFloat?

    fileprivate static let rowHeight: CGFloat = 8
    private static let rowSpacing: CGFloat = 4
    private static let padVertical: CGFloat = 14
    /// 鱼眼衰减宽度（σ，pt）与最大伸长量。σ 收窄让峰形更陡（Codex 观感：
    /// 峰值约在 3-4 条刻度内衰减大半），峰值 = 基线长度的 4 倍左右。
    fileprivate static let fisheyeSigma: CGFloat = 16
    fileprivate static let fisheyeBoost: CGFloat = 18
    /// 「排开」位移场：光标上方的刻度轻轻上推、下方下推的最大幅度（pt）。
    /// 位移场比长度场更宽（σ×1.4），推得柔、不突兀。
    private static let fisheyeSpread: CGFloat = 5

    var body: some View {
        // 刻度条是 agent 聊天内容的缩略，不是任务列表：只在活动会话正在跑
        // Claude 时显示。进程树 5s 一次重分类，CC 退出降级回 shell 后随之消失。
        let isAgentLive = store.activeId
            .flatMap { id in store.sessions.first(where: { $0.id == id })?.kind } == .claude
        let turns = isAgentLive ? (store.activeId.flatMap { store.turns[$0] } ?? []) : []
        // ZStack 恒存在（空时零尺寸）：轮次为空时也要触发 onAppear/onChange
        // 去拉数据，否则 rail 永远不出现（首帧 turns 必为空）。
        ZStack(alignment: .leading) {
            if !turns.isEmpty {
                rail(turns)
            }
        }
        .onAppear { forceRefresh() }
        .onChange(of: store.activeId) { _ in forceRefresh() }
    }

    private func rail(_ turns: [ConversationTurn]) -> some View {
        let hovered = hoveredIndex(count: turns.count)
        // 亮线 = 视口当前所在轮（屏幕指纹定位）；尚未定位到时按 CC 跟随尾部
        // 的默认行为点亮最新一轮。
        let currentId = store.viewportTurnId ?? turns.last?.id
        return VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                TimelineTick(
                    turn: turn,
                    isCurrent: turn.id == currentId,
                    boost: boost(for: index),
                    showPreview: hovered == index
                )
                .offset(y: displacement(for: index))
                .zIndex(hovered == index ? 1 : 0)
            }
        }
        .padding(.leading, 7)
        .padding(.vertical, Self.padVertical)
        // 点击命中按几何格判定（鼠标所在行高整格可点），与「排开」位移解耦——
        // 位移只是视觉，若把命中区挂在被位移的刻度上，光标一靠近刻度就被推走，
        // 永远追不上、点不中。
        .contentShape(Rectangle())
        .onTapGesture {
            if let idx = hoveredIndex(count: turns.count), turns.indices.contains(idx) {
                store.jumpToTurn(turns[idx].id)
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): mouseY = point.y
            case .ended: mouseY = nil
            }
        }
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.85), value: mouseY)
        // 亮线在轮次间移动时平滑过渡（长度/亮度渐变），跳转过程连续扫过。
        .animation(.easeOut(duration: 0.18), value: store.viewportTurnId)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func forceRefresh() {
        if let sid = store.activeId { store.refreshTurns(sid, force: true) }
    }

    /// 第 index 条刻度在本地坐标系（含 padding）里的中心 y。
    private func rowCenter(_ index: Int) -> CGFloat {
        Self.padVertical + CGFloat(index) * (Self.rowHeight + Self.rowSpacing) + Self.rowHeight / 2
    }

    /// 鱼眼伸长量：按与光标的距离高斯衰减，未悬浮为 0。
    private func boost(for index: Int) -> CGFloat {
        guard let my = mouseY else { return 0 }
        let dist = rowCenter(index) - my
        return Self.fisheyeBoost * exp(-(dist * dist) / (2 * Self.fisheyeSigma * Self.fisheyeSigma))
    }

    /// 「排开」位移：光标正下方不动，两侧刻度沿远离光标方向轻推——鱼眼不只
    /// 是变长，还有被指尖拨开的空间感。
    private func displacement(for index: Int) -> CGFloat {
        guard let my = mouseY else { return 0 }
        let dist = rowCenter(index) - my
        let sigma = Self.fisheyeSigma * 1.4
        let falloff = exp(-(dist * dist) / (2 * sigma * sigma))
        return (dist >= 0 ? 1 : -1) * Self.fisheyeSpread * falloff
    }

    /// 光标最近的刻度（气泡挂它）；超出一步行距视为不在任何刻度上。
    private func hoveredIndex(count: Int) -> Int? {
        guard let my = mouseY, count > 0 else { return nil }
        let step = Self.rowHeight + Self.rowSpacing
        let index = Int(((my - Self.padVertical) / step).rounded(.down))
        let clamped = min(max(index, 0), count - 1)
        return abs(rowCenter(clamped) - my) <= step ? clamped : nil
    }
}

private struct TimelineTick: View {
    let turn: ConversationTurn
    let isCurrent: Bool
    let boost: CGFloat
    let showPreview: Bool

    var body: some View {
        Capsule()
            .fill(tickColor)
            .frame(width: tickWidth, height: tickHeight)
            // 撑满行格宽高（点击命中在 rail 容器层按几何格判定，这里只管视觉）。
            .frame(width: 28, height: TimelineRail.rowHeight, alignment: .leading)
            .overlay(alignment: .leading) {
                if showPreview {
                    preview
                        .offset(x: tickWidth + 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                }
            }
    }

    /// 静默态所有刻度等长（当前所在轮只用亮度区分，不加长）；
    /// 长度变化只属于 hover 的鱼眼 remotion，峰值伸到基线 4 倍。
    private var tickWidth: CGFloat {
        8 + boost
    }

    /// 与光标的贴近程度 0…1（伸长量归一化），粗细/亮度共用。
    private var lift: CGFloat {
        min(1, boost / TimelineRail.fisheyeBoost)
    }

    /// hover 中心的线在变长的同时轻微加粗（2 → 3pt），焦点感更实。
    private var tickHeight: CGFloat {
        2 + lift
    }

    private var tickColor: Color {
        // 当前所在轮始终满亮；其余静默时是半透明主色（视觉为灰但要一眼可见，
        // 0.38 在深底上近乎隐形），被光标带起时向满亮白过渡——Codex 的 hover
        // 中心是白线，不是亮灰。
        if isCurrent { return Theme.sidebarPrimary }
        return Theme.sidebarPrimary.opacity(0.52 + 0.48 * lift)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(turn.prompt)
                .font(Theme.uiFont(size: 12.5, weight: .semibold))
                .foregroundColor(Theme.sidebarPrimary)
                .lineLimit(2)
            Text(turn.reply.isEmpty ? "回答中…" : turn.reply)
                .font(Theme.uiFont(size: 11.5))
                .foregroundColor(Theme.sidebarSecondary)
                .lineLimit(4)
            if let ts = turn.timestamp {
                Text(Self.relativeTime(ts))
                    .font(Theme.uiFont(size: 10.5))
                    .foregroundColor(Theme.sidebarSecondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        // overlay 的提议宽度 = 刻度线自身宽（20 来 pt），用 maxWidth 会被压成
        // 竖条；必须显式给定宽度，再让高度取理想值。
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.sidebarFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.sidebarSeparator, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 4)
        )
        .allowsHitTesting(false)
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
