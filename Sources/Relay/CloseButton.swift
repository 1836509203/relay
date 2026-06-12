// 关闭按钮（×）：悬停时圆形底色 + 图标提亮。侧栏任务行与顶部标签页共用，
// 基础可见性由调用方控制（活动行较亮、非活动行淡显/隐藏）。
import SwiftUI

struct CloseButton: View {
    var size: CGFloat = 8.5
    /// 未悬停时的整体不透明度（悬停后恒为 1）。
    var baseOpacity: Double = 0.6
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size, weight: .bold))
                .foregroundColor(hovered ? Theme.fg0 : Theme.fg2)
                .frame(width: size + 9, height: size + 9)
                .background(Circle().fill(hovered ? Theme.pill.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain)
        .opacity(hovered ? 1 : baseOpacity)
        .onHover { hovered = $0 }
    }
}
