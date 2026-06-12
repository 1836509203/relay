// 给 app 包设置 Finder 自定义图标（resource fork + FinderInfo C 标志）。
// macOS 26 的 Dock/Mission Control 角标走 Assets.car 资产管线，老式
// CFBundleIconFile icns 解析不到（iconservices 日志:"Unable to find
// asset in (null)"）；无 Xcode/actool 编不了 car —— 自定义图标在
// IconServices 优先级最高，三处（Dock/角标/Finder）通吃。
import AppKit
let app = CommandLine.arguments[1], png = CommandLine.arguments[2]
guard let img = NSImage(contentsOf: URL(fileURLWithPath: png)) else {
    fputs("无法读取 \(png)\n", stderr); exit(1)
}
exit(NSWorkspace.shared.setIcon(img, forFile: app, options: []) ? 0 : 2)
