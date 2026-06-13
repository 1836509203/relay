// 主界面顶部更新条：发现新版 / 下载进度 / 校验 / 安装 / 失败的可见入口。
// 刻意不用 overlay 浮层（会遮终端，违背 RootView「不在窗口内弹浮层」原则），
// 而是占布局的一条横幅，随阶段切换内容；收起后高度归零。
import AppKit
import SwiftUI

struct UpdateBanner: View {
    @ObservedObject var model: UpdateModel

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(tint.opacity(0.5)).frame(height: 1)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 当前阶段强调色：失败用红，其余用琥珀金主强调色。
    private var tint: Color {
        if case .failed = model.phase { return Theme.red }
        return Theme.termAccent
    }

    private var versionText: String { model.version.map { "v\($0)" } ?? "" }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .available:
            Image(systemName: "arrow.down.circle.fill").foregroundColor(tint)
            Text("Relay \(versionText) 可更新").foregroundColor(Theme.fg0)
            Spacer(minLength: 8)
            linkButton("发布说明") { openReleases() }
            actionButton("更新") { Updater.startDownload() }
            linkButton("稍后") { model.hidden = true }

        case .downloading(let f):
            Image(systemName: "arrow.down.circle").foregroundColor(tint)
            Text("下载更新 \(versionText)…").foregroundColor(Theme.fg0)
            if f >= 0 {
                ProgressView(value: min(max(f, 0), 1))
                    .progressViewStyle(.linear).frame(width: 150).tint(tint)
                Text("\(Int(f * 100))%").foregroundColor(Theme.fg2).monospacedDigit()
            } else {
                // 镜像不返回 Content-Length：进度不可测，转无限指示。
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                Text("下载中…").foregroundColor(Theme.fg2)
            }
            Spacer(minLength: 8)

        case .verifying:
            Image(systemName: "checkmark.shield").foregroundColor(tint)
            Text("校验更新包…").foregroundColor(Theme.fg0)
            ProgressView().progressViewStyle(.circular).controlSize(.small)
            Spacer(minLength: 8)

        case .installing:
            Image(systemName: "shippingbox").foregroundColor(tint)
            Text("正在安装，即将自动重启…").foregroundColor(Theme.fg0)
            ProgressView().progressViewStyle(.circular).controlSize(.small)
            Spacer(minLength: 8)

        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(tint)
            Text("更新失败：\(msg)")
                .foregroundColor(Theme.fg0).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            actionButton("重试") { Updater.startDownload() }
            linkButton("关闭") { model.phase = .idle; model.hidden = true }
        }
    }

    private func actionButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(tint)
    }

    private func linkButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundColor(Theme.fg2)
    }

    private func openReleases() {
        if let url = URL(string: "https://github.com/\(Updater.repo)/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }
}
