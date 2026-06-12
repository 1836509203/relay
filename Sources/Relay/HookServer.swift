// 本机 hook 服务 —— Rust 版 hooks.rs 的移植。
// 监听 127.0.0.1 随机端口，Claude Code hooks 用 curl 上报：
//   POST /hook?s=<会话id>&e=<事件>   头 X-Relay-Token: <token>
// 与 Tauri 版协议完全一致，用户已安装的 hooks 配置无需改动。
import Foundation
import Network
import Security

final class HookServer {
    let token: String
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let onEvent: (String, String) -> Void
    /// listener 专用队列：ready 回调不能排在主队列 —— init 在主线程限时等
    /// ready，排主队列会死锁；排在这里则等待期间照常投递。
    private let queue = DispatchQueue(label: "relay.hook")

    /// hook URL 前缀（含 ?s=，调用方再拼 &e=）。listener 未就绪时为 nil，
    /// 此时新会话不注入 hook env，状态退化为启发式检测（不致命）。
    var baseURL: String? { port > 0 ? "http://127.0.0.1:\(port)" : nil }

    init(onEvent: @escaping (String, String) -> Void) {
        self.onEvent = onEvent
        self.token = HookServer.genToken()
        start()
    }

    private func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return }
        listener = l
        // 限时等 ready 再返回：启动即恢复的会话在 init 完成后立刻创建，
        // 若此时端口未就绪，这些会话拿不到 RELAY_HOOK_URL —— claude hooks
        // 静默失效（实测 curl 000），永久退化为启发式检测。本地 TCP 监听
        // 就绪是毫秒级，0.5 秒上限只是兜底。
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = l.port?.rawValue ?? 0
                ready.signal()
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 0.5)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        var buf = Data()
        func step() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, eof, err in
                guard let self else { conn.cancel(); return }
                if let d = data { buf.append(d) }
                if err != nil || buf.count > 64 * 1024 { conn.cancel(); return }
                // 等到完整的 header + body（按 Content-Length）再处理，
                // 让 curl 把 body 发完、收到完整 204 才算成功。
                if let req = HookServer.parseRequest(buf) {
                    self.respond(conn, request: req)
                } else if eof {
                    conn.cancel()
                } else {
                    step()
                }
            }
        }
        step()
    }

    private func respond(_ conn: NWConnection, request: (path: String, token: String?)) {
        var status = "403 Forbidden"
        if let t = request.token, HookServer.constantTimeEq(t, token),
           let (sid, event) = HookServer.parseHookQuery(request.path) {
            status = "204 No Content"
            onEvent(sid, event)
        } else if request.token == nil || !request.path.hasPrefix("/hook") {
            status = request.path.hasPrefix("/hook") ? "403 Forbidden" : "404 Not Found"
        }
        let resp = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// 解析 HTTP 请求：返回 (path+query, token头)。header/body 不完整时返回 nil 继续收。
    static func parseRequest(_ buf: Data) -> (path: String, token: String?)? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])

        var token: String?
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "x-relay-token" { token = val }
            if key == "content-length" { contentLength = Int(val) ?? 0 }
        }
        // body 未收全：继续等（让 curl 把 body 发完再回 204）。
        let bodyBytes = buf.distance(from: headerEnd.upperBound, to: buf.endIndex)
        if bodyBytes < contentLength { return nil }
        return (path, token)
    }

    /// 从 "/hook?s=<sid>&e=<event>" 解析参数。
    static func parseHookQuery(_ path: String) -> (String, String)? {
        guard path.hasPrefix("/hook"), let q = path.firstIndex(of: "?") else { return nil }
        var sid: String?, event: String?
        for pair in path[path.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            if kv[0] == "s" { sid = val }
            if kv[0] == "e" { event = val }
        }
        guard let s = sid, let e = event, !s.isEmpty, !e.isEmpty else { return nil }
        return (s, e)
    }

    static func constantTimeEq(_ a: String, _ b: String) -> Bool {
        let ab = [UInt8](a.utf8), bb = [UInt8](b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    static func genToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
