// swift-tools-version:5.9
// Relay 原生版 —— 单进程 AppKit/SwiftUI + SwiftTerm（原生终端渲染，无 WebView）。
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 本地 vendor（v1.13.0 + Relay 补丁）：上游 LocalProcess 每次数据回调
        // 都叠发一个新的 DispatchIO.read，洪峰时未完成操作堆积到百万级
        //（每个 ~530B 且 PTY 不 EOF 永不释放），同时输出被切成字节级微块
        // 逐块过解析栈 —— 吞吐与内存的共同根因。补丁见 Vendor/SwiftTerm。
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Relay"
        )
    ]
)
