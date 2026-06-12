// 自动更新：基于 GitHub Releases 的轻量更新器（无 Sparkle 依赖）。
// 检查 → 系统通知/对话框 → 下载 zip（直连失败走加速镜像）→ ditto 原地
// 覆盖 → 重启。发布侧配套 scripts/release.sh（构建打包 + tag + Release）。
import AppKit
import Foundation
import UserNotifications

enum Updater {
    static let repo = "1836509203/relay"
    static let assetName = "Relay.app.zip"
    /// asset 下载加速前缀（直连超时再依次尝试；API 检查始终直连）。
    static let mirrors = ["", "https://ghfast.top/", "https://gh-proxy.com/"]

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - 检查

    /// interactive=true（菜单触发）：任何结果都弹对话框；
    /// false（启动/定时后台）：仅发现新版时发系统通知，其余静默。
    static func check(interactive: Bool) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    // API 不可达或匿名配额耗尽（共享代理出口 60 次/时/IP 很容易
                    // 被打满，403）→ 改走网页重定向探测，不消耗 API 配额。
                    checkViaRedirect(interactive: interactive, apiError: err)
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let assets = obj["assets"] as? [[String: Any]] ?? []
                let assetURL = assets.first { ($0["name"] as? String) == assetName }?["browser_download_url"] as? String
                if isNewer(latest, than: currentVersion) {
                    guard let assetURL else {
                        if interactive { alert("新版本 v\(latest) 缺少安装包", info: "Release 未上传 \(assetName)。") }
                        return
                    }
                    offer(version: latest, urlString: assetURL,
                          notes: obj["body"] as? String ?? "", interactive: interactive)
                } else if interactive {
                    alert("已是最新版本", info: "当前 \(currentVersion)；远端最新 \(latest)。")
                }
            }
        }.resume()
    }

    /// API 的后备路径：releases/latest 网页 302 到 /releases/tag/<tag>，
    /// 跟随重定向后从最终 URL 提取版本号（无 rate limit）。asset 地址按
    /// GitHub 固定格式构造，发布说明拿不到（留空）。
    private static func checkViaRedirect(interactive: Bool, apiError: Error?) {
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                guard let final = resp?.url, final.pathComponents.dropLast().last == "tag",
                      let tag = final.pathComponents.last, tag.hasPrefix("v") else {
                    if interactive {
                        alert("无法获取更新信息",
                              info: (apiError ?? err)?.localizedDescription
                                  ?? "网络不可达，或仓库还没有发布任何版本。")
                    }
                    return
                }
                let latest = String(tag.dropFirst())
                if isNewer(latest, than: currentVersion) {
                    offer(version: latest,
                          urlString: "https://github.com/\(repo)/releases/download/\(tag)/\(assetName)",
                          notes: "", interactive: interactive)
                } else if interactive {
                    alert("已是最新版本", info: "当前 \(currentVersion)；远端最新 \(latest)。")
                }
            }
        }.resume()
    }

    /// 简化 semver：逐段数值比较（v 前缀已剥）。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 提示

    private static func offer(version: String, urlString: String, notes: String, interactive: Bool) {
        if !interactive {
            // 后台发现：系统通知推送，不打断当前操作；安装走通知点击或菜单。
            let content = UNMutableNotificationContent()
            content.title = "Relay 有新版本 v\(version)"
            content.body = "在菜单 Relay → 检查更新… 中一键安装。"
            content.sound = nil
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "relay.update.\(version)", content: content, trigger: nil))
            return
        }
        let a = NSAlert()
        a.messageText = "发现新版本 v\(version)（当前 \(currentVersion)）"
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = trimmed.isEmpty ? "是否立即下载并安装？" : String(trimmed.prefix(600))
        a.addButton(withTitle: "立即更新")
        a.addButton(withTitle: "查看发布页")
        a.addButton(withTitle: "稍后")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            download(urlString, version: version)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)/releases/latest")!)
        default: break
        }
    }

    // MARK: - 下载（多镜像顺序尝试）

    private static func download(_ urlString: String, version: String, mirrorIndex: Int = 0) {
        guard mirrorIndex < mirrors.count else {
            alert("下载失败", info: "直连与加速镜像均不可达，请稍后再试或到发布页手动下载。")
            return
        }
        guard let url = URL(string: mirrors[mirrorIndex] + urlString) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        let task = URLSession.shared.downloadTask(with: req) { local, resp, _ in
            DispatchQueue.main.async {
                guard let local, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    download(urlString, version: version, mirrorIndex: mirrorIndex + 1)
                    return
                }
                // downloadTask 的临时文件回调结束即删：先挪走再安装。
                let zip = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Relay-update-\(version).zip")
                try? FileManager.default.removeItem(at: zip)
                do {
                    try FileManager.default.moveItem(at: local, to: zip)
                    install(zip: zip, version: version)
                } catch {
                    alert("下载失败", info: error.localizedDescription)
                }
            }
        }
        task.resume()
    }

    // MARK: - 安装（原地覆盖 + 重启）

    private static func install(zip: URL, version: String) {
        let unpack = FileManager.default.temporaryDirectory
            .appendingPathComponent("Relay-unpack-\(version)", isDirectory: true)
        try? FileManager.default.removeItem(at: unpack)
        try? FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)

        // ditto 解压保留 resource fork（自定义图标在 rsrc 里）。
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, unpack.path]
        try? p.run(); p.waitUntilExit()

        guard p.terminationStatus == 0,
              let newApp = (try? FileManager.default.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil))?
                  .first(where: { $0.pathExtension == "app" }) else {
            alert("安装失败", info: "更新包解压失败或不含 .app。")
            return
        }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            alert("安装失败", info: "当前不是从 .app 包运行，无法原地更新。")
            return
        }
        // 原地覆盖：运行中的进程持有旧 inode，文件替换不影响存活；
        // 退出走 applicationWillTerminate 正常落盘会话，再拉起新版。
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        cp.arguments = [newApp.path, target.path]
        try? cp.run(); cp.waitUntilExit()
        guard cp.terminationStatus == 0 else {
            alert("安装失败", info: "无法写入 \(target.path)，请检查权限。")
            return
        }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"\(target.path)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    private static func alert(_ msg: String, info: String) {
        let a = NSAlert()
        a.messageText = msg
        a.informativeText = info
        a.runModal()
    }
}
