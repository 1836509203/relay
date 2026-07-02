// 进程内 NSEvent 闭环 e2e：真 NSEvent 打进 MacTerminalView 的 mouseDown/mouseDragged/
// mouseUp，20Hz 自动滚动定时器真跑；转发出的 SGR 滚轮上报（\x1b[<64;…M）由录制的
// 真实 CC 响应帧逐组应答——除了系统事件注入之外，整条链路与真机完全一致。
import AppKit

struct Rec: Decodable {
    let t: Double
    let kind: String
    let data: String
    let note: String?
}

final class PlaybackDelegate: TerminalViewDelegate {
    var wheelUpReports = 0
    var otherSends = 0
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let s = String(decoding: data, as: UTF8.self)
        if s.hasPrefix("\u{1B}[<64;") {
            wheelUpReports += 1
        } else {
            otherSends += 1
        }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

let args = CommandLine.arguments
guard args.count >= 2, let fileData = FileManager.default.contents(atPath: args[1]) else {
    print("usage: e2e <recording.jsonl>")
    exit(1)
}
var records: [Rec] = []
let decoder = JSONDecoder()
for line in String(decoding: fileData, as: UTF8.self).split(separator: "\n") {
    if let r = try? decoder.decode(Rec.self, from: Data(line.utf8)) { records.append(r) }
}

// 切分：Phase A 输出块（第一个 wheel 注入前），随后每个 wheel-up 对应的响应组。
var phaseA: [[UInt8]] = []
var upGroups: [[[UInt8]]] = []
var i = 0
while i < records.count {
    let r = records[i]
    if r.kind == "in", (r.note ?? "").hasPrefix("wheel") { break }
    if r.kind == "out", let d = Data(base64Encoded: r.data) { phaseA.append([UInt8](d)) }
    i += 1
}
while i < records.count {
    let r = records[i]
    i += 1
    if r.kind == "in", (r.note ?? "").hasPrefix("wheel-down") { break }
    if r.kind == "in", (r.note ?? "").hasPrefix("wheel-up") {
        upGroups.append([])
        continue
    }
    if r.kind == "out", let d = Data(base64Encoded: r.data), !upGroups.isEmpty {
        upGroups[upGroups.count - 1].append([UInt8](d))
    }
}
print("phaseA=\(phaseA.count) 块, wheel-up 响应组=\(upGroups.count)")

_ = NSApplication.shared
let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 900, height: 600)))
let delegate = PlaybackDelegate()
view.terminalDelegate = delegate
let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                   styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = view
let term = view.terminal!

for chunk in phaseA { view.feed(byteArray: chunk[...]) }
print("A-end: alt=\(term.isDisplayBufferAlternate) rows=\(term.rows) cols=\(term.cols) cell=\(view.cellDimension!)")
guard term.isDisplayBufferAlternate else { print("!! 不在备用屏"); exit(2) }

func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: win.windowNumber, context: nil,
                       eventNumber: 0, clickCount: clicks, pressure: 1)!
}
func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

// 闭环回放：转发出的 wheel-up 报文逐个消费录制响应组（下一 runloop tick 才 feed，模拟 PTY 异步）。
var consumedGroups = 0
var fedGroups = 0
let pumpTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
    while consumedGroups < delegate.wheelUpReports && consumedGroups < upGroups.count {
        let g = upGroups[consumedGroups]
        consumedGroups += 1
        if g.isEmpty { continue }
        for chunk in g { view.feed(byteArray: chunk[...]) }
        fedGroups += 1
        let scr = view.visibleAlternateScreenLines()
        let nonEmpty = scr.filter { !$0.replacingOccurrences(of: "\0", with: " ").trimmingCharacters(in: .whitespaces).isEmpty }.count
        let nul = scr.filter { $0.contains("\0") }.count
        print("  [组#\(fedGroups)] \(g.map { $0.count }.reduce(0, +))B 非空行=\(nonEmpty) 含NUL行=\(nul) 屏行1=\(scr[1].replacingOccurrences(of: "\0", with: "·")) 屏行5=\(scr[5].replacingOccurrences(of: "\0", with: "·"))")
        break   // 每 tick 只吐一组，保留真机的交错节奏
    }
}
RunLoop.main.add(pumpTimer, forMode: .common)

// 锚点选在 transcript 区（Phase A 屏行 24 = "  117"），x=60 → 列 ~7 盖住整个数字。
let cellH = view.cellDimension!.height
let anchorPoint = CGPoint(x: 60, y: 600 - CGFloat(24) * cellH - cellH / 2)
let anchorRowText = view.visibleAlternateScreenLines()[24]
print("锚点屏行 24 = \"\(anchorRowText)\" @ \(anchorPoint)")

view.mouseDown(with: mouse(.leftMouseDown, anchorPoint))
// 逐步向上拖到顶边（edgeInset ≈ 24px，y=599 在边内触发向上自动滚动）。
for step in 1...8 {
    let t = CGFloat(step) / 8
    let p = CGPoint(x: 60, y: anchorPoint.y + (599 - anchorPoint.y) * t)
    view.mouseDragged(with: mouse(.leftMouseDragged, p))
    pump(0.03)
}
print("到顶边: timer=\(view.selectionAutoScrollIsActive) sel=(\(view.selection.start.row),\(view.selection.start.col))-(\(view.selection.end.row),\(view.selection.end.col))")

// 持续按住 4 秒：20Hz 定时器转发滚轮、闭环应答、跟踪平移锚点。
var lastReport = 0
for _ in 0..<8 {
    pump(0.5)
    if delegate.wheelUpReports != lastReport {
        lastReport = delegate.wheelUpReports
        let sel = view.selection!
        print("  [hold] 转发=\(delegate.wheelUpReports) 应答组=\(fedGroups) sel=(\(sel.start.row),\(sel.start.col))-(\(sel.end.row),\(sel.end.col))")
    }
    if consumedGroups >= upGroups.count { break }
}
pump(0.3)
print("---- 屏幕（mouseUp 前） ----")
for (r, l) in view.visibleAlternateScreenLines().enumerated() { print(String(format: "%3d| %@", r, l)) }
let accBefore = view.selectedTextForCopy().components(separatedBy: "\n")
print("累积器（mouseUp 前，\(accBefore.count) 行）首3: \(accBefore.prefix(3)) 末3: \(accBefore.suffix(3))")
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 60, y: 599)))
let accAfter = view.selectedTextForCopy().components(separatedBy: "\n")
print("累积器（mouseUp 后，\(accAfter.count) 行）首6:")
for l in accAfter.prefix(6) { print("  |\(l)|") }
pumpTimer.invalidate()

print("闭环完成: 转发滚轮=\(delegate.wheelUpReports) 应答组=\(fedGroups)/\(upGroups.count)")
let sel = view.selection!
print("松手后: selActive=\(sel.active) start=(\(sel.start.row),\(sel.start.col)) end=(\(sel.end.row),\(sel.end.col))")
print("---- 屏幕（松手时） ----")
for (r, l) in view.visibleAlternateScreenLines().enumerated() { print(String(format: "%3d| %@", r, l)) }

let copied = view.selectedTextForCopy()
let lines = copied.components(separatedBy: "\n")
print("---- 复制文本（\(lines.count) 行） ----")
print(copied)
print("----")

// 完整性判定：提取纯数字行，应当严格 +1 连续、无重复。
let nums = lines.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
var breaks = 0
for j in 1..<max(nums.count, 1) where j < nums.count && nums[j] != nums[j - 1] + 1 { breaks += 1 }
let dups = nums.count - Set(nums).count
print("数字行=\(nums.count) 首=\(nums.first ?? -1) 末=\(nums.last ?? -1) 断点=\(breaks) 重复=\(dups)")
print(copied.contains("117") ? "锚点内容 117 在复制文本中 ✓" : "!! 锚点内容 117 丢失")
exit((breaks == 0 && dups == 0 && copied.contains("117")) ? 0 : 3)
