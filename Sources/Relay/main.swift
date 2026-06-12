// Relay 原生版入口 —— 单进程 AppKit 应用（无 storyboard，无 WebView）。
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
