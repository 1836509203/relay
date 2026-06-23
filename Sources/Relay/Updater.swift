// 自动更新：基于 GitHub Releases 的轻量更新器（无 Sparkle 依赖）。
// 检查 → 系统通知/对话框 → 下载 zip（直连失败走加速镜像）→ ditto 原地
// 覆盖 → 重启。发布侧配套 scripts/release.sh（构建打包 + tag + Release）。
import AppKit
import CryptoKit
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

    private static func uncachedURL(_ string: String) -> URL? {
        guard var components = URLComponents(string: string) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "relay_cache_bust", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = items
        return components.url
    }

    private static func releaseRequest(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return req
    }

    /// interactive=true（菜单触发）：任何结果都弹对话框；
    /// false（启动/定时后台）：仅发现新版时发系统通知，其余静默。
    static func check(interactive: Bool) {
        guard let url = uncachedURL("https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = releaseRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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
        let req = releaseRequest(url: url, method: "HEAD")
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
        // 点亮 App 内更新条（后台与手动检查都点亮）；手动检查再额外弹对话框即时确认。
        UpdateModel.shared.found(version: version, assetURL: urlString, notes: notes)
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

    // MARK: - 下载 + 完整性校验（多镜像顺序尝试）

    /// 下载 zip → 取同名 `.sha256` → 比对哈希 → 安装。校验基于内容哈希、
    /// 与下载通道解耦：即便经第三方镜像（ghfast.top 等）被投毒，哈希不符即
    /// 拒装。全程在后台线程（URLSession 回调队列），不阻塞 UI；仅弹框/重启
    /// 回主线程。
    /// 更新条「更新 / 重试」入口：用已登记的版本与地址开始下载。
    static func startDownload() {
        guard let urlString = UpdateModel.shared.assetURL,
              let version = UpdateModel.shared.version else { return }
        download(urlString, version: version)
    }

    /// 进度观察句柄：downloadTask.progress 的 KVO，须强引用否则立即释放、无回调。
    private static var progressObservation: NSKeyValueObservation?

    /// 阶段切换统一回主线程（更新条是 @Published）。
    private static func setPhase(_ p: UpdateModel.Phase) {
        DispatchQueue.main.async { UpdateModel.shared.phase = p }
    }

    /// 失败收尾：停掉进度观察、更新条转失败态（保留「重试」）、并弹框告知。
    private static func fail(_ title: String, _ info: String) {
        progressObservation = nil
        setPhase(.failed(info))
        alert(title, info: info)
    }

    private static func download(_ urlString: String, version: String, mirrorIndex: Int = 0) {
        guard mirrorIndex < mirrors.count else {
            fail("下载失败", "直连与加速镜像均不可达，请稍后再试或到发布页手动下载。")
            return
        }
        guard let url = URL(string: mirrors[mirrorIndex] + urlString) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        let task = URLSession.shared.downloadTask(with: req) { local, resp, _ in
            guard let local, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                download(urlString, version: version, mirrorIndex: mirrorIndex + 1) // 换下个镜像
                return
            }
            progressObservation = nil
            setPhase(.verifying)
            // downloadTask 的临时文件回调结束即删：先挪走。
            let zip = FileManager.default.temporaryDirectory
                .appendingPathComponent("Relay-update-\(version).zip")
            try? FileManager.default.removeItem(at: zip)
            do {
                try FileManager.default.moveItem(at: local, to: zip)
            } catch {
                fail("下载失败", error.localizedDescription)
                return
            }
            // 完整性校验：取同镜像下的 .sha256，比对本地计算的哈希。
            guard let expected = fetchExpectedHash(urlString: urlString, mirrorIndex: mirrorIndex) else {
                fail("无法验证更新包", "未能获取发布校验和（.sha256）。为防止下载内容被篡改，已取消安装；请到发布页手动下载。")
                return
            }
            guard let actual = sha256(of: zip) else {
                fail("无法验证更新包", "未能计算下载文件的校验和，已取消安装。")
                return
            }
            guard expected.caseInsensitiveCompare(actual) == .orderedSame else {
                fail("更新包校验失败",
                     "下载内容与发布校验和不匹配（可能传输损坏或来源不可信），已取消安装。请到发布页手动下载。")
                return
            }
            setPhase(.installing)
            install(zip: zip, version: version)
        }
        // 进度：fractionCompleted 基于 Content-Length；镜像不返回长度时 totalUnitCount<=0，
        // 用 -1 表示不确定，更新条改走无限进度样式。
        progressObservation = task.progress.observe(\.fractionCompleted) { prog, _ in
            let f = prog.totalUnitCount > 0 ? prog.fractionCompleted : -1
            setPhase(.downloading(f))
        }
        setPhase(.downloading(0))
        task.resume()
    }

    /// 取发布的期望哈希：同镜像下 `<asset>.sha256`，内容形如 `<hex>  <文件名>`。
    private static func fetchExpectedHash(urlString: String, mirrorIndex: Int) -> String? {
        guard let url = URL(string: mirrors[mirrorIndex] + urlString + ".sha256"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let hex = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init)
        // 基本健壮性：必须是 64 位十六进制，否则视为无效。
        guard let h = hex, h.count == 64, h.allSatisfy({ $0.isHexDigit }) else { return nil }
        return h
    }

    private static func sha256(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 安装（原地覆盖 + 重启，后台线程执行）

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
            fail("安装失败", "更新包解压失败或不含 .app。")
            return
        }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            fail("安装失败", "当前不是从 .app 包运行，无法原地更新。")
            return
        }
        // 原地覆盖：运行中的进程持有旧 inode，文件替换不影响存活；
        // 退出走 applicationWillTerminate 正常落盘会话，再拉起新版。
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        cp.arguments = [newApp.path, target.path]
        try? cp.run(); cp.waitUntilExit()
        guard cp.terminationStatus == 0 else {
            fail("安装失败", "无法写入 \(target.path)，请检查权限。")
            return
        }
        // 重启：sleep 1 等本进程退出后 open。路径单引号包裹并转义单引号，
        // 杜绝安装路径含特殊字符时的命令注入。
        let quoted = "'" + target.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \(quoted)"]
        try? relaunch.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// 任何线程可调：弹框统一回主线程（NSAlert 必须主线程）。
    private static func alert(_ msg: String, info: String) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = msg
            a.informativeText = info
            a.runModal()
        }
    }
}
