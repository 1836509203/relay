// 应用内更新状态中心：发现的新版本 + 下载/校验/安装阶段，驱动主界面顶部
// 更新条（UpdateBanner）。系统通知仍保留（后台静默发现时推送），但 App 内
// 以可见的更新条作为主入口——系统通知容易被勿扰/一闪而过吞掉。
// 约定：所有 @Published 仅在主线程修改（Updater 回调统一切主线程后再写）。
import Foundation

final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()
    private init() {}

    enum Phase: Equatable {
        case idle                 // 无更新
        case available            // 已发现新版，等待用户操作
        case downloading(Double)  // 下载中；进度 0...1，<0 表示无 Content-Length（不确定）
        case verifying            // 校验 sha256
        case installing           // 解压覆盖 + 重启
        case failed(String)       // 失败原因（展示给用户）
    }

    @Published var phase: Phase = .idle
    @Published var version: String?   // 新版本号（不含 v 前缀）
    @Published var hidden = false     // 用户点「稍后」临时收起；重新发现/重试时复位

    /// 下载地址与发布说明不参与视图 diff，普通属性即可。
    var assetURL: String?
    var notes: String = ""

    /// 更新条是否显示：有版本号、未被收起、且不处于 idle。
    var isVisible: Bool {
        guard version != nil, !hidden else { return false }
        if case .idle = phase { return false }
        return true
    }

    /// 检查到新版本：登记信息并点亮更新条。下载/校验/安装进行中时不打断当前
    /// 阶段（避免一次后台复查把进度条打回「可更新」）。
    func found(version: String, assetURL: String, notes: String) {
        self.version = version
        self.assetURL = assetURL
        self.notes = notes
        self.hidden = false
        switch phase {
        case .downloading, .verifying, .installing: break
        default: phase = .available
        }
    }
}
