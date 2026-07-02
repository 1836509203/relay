// 无头引擎回放器：把录制的真实 CC PTY 字节流按原始块边界喂进 TerminalView（无 UI），
// 模拟「向上拖到顶边转发滚轮」的拖选流程，逐块打印引擎内部状态，定位跟踪断点。
import AppKit

final class NullDelegate: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct Rec: Decodable {
    let t: Double
    let kind: String
    let data: String
    let note: String?
}

let args = CommandLine.arguments
let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 900, height: 600)))
let delegate = NullDelegate()
view.terminalDelegate = delegate
let term = view.terminal!

if args.contains("--dims") {
    print("cols=\(term.cols) rows=\(term.rows)")
    exit(0)
}

guard args.count >= 2, let fileData = FileManager.default.contents(atPath: args[1]) else {
    print("usage: replay <recording.jsonl> [--verbose]")
    exit(1)
}
let verbose = args.contains("--verbose")
let decoder = JSONDecoder()
var records: [Rec] = []
for line in String(decoding: fileData, as: UTF8.self).split(separator: "\n") {
    if let r = try? decoder.decode(Rec.self, from: Data(line.utf8)) { records.append(r) }
}
print("records=\(records.count)")

func esc(_ s: String) -> String { s.replacingOccurrences(of: "\u{1B}", with: "␛") }

func summarize(_ bytes: [UInt8]) -> String {
    let s = String(decoding: bytes, as: UTF8.self)
    var tags: [String] = []
    for (seq, tag) in [("[?1049h", "1049h"), ("[?1049l", "1049l"), ("[2J", "2J"),
                       ("[?2026h", "sync-h"), ("[?2026l", "sync-l"),
                       ("[?1000h", "1000h"), ("[?1002h", "1002h"), ("[?1006h", "1006h"),
                       ("\u{1B}[H", "CUP-H"), ("[1;1H", "CUP-11"),
                       ("[S", "SU"), ("[T", "SD"), ("[r", "DECSTBM?")] {
        if s.contains(seq) { tags.append(tag) }
    }
    // 独立 linefeed 数量（粗略）
    let lf = bytes.filter { $0 == 0x0A }.count
    if lf > 0 { tags.append("lf×\(lf)") }
    return tags.joined(separator: ",")
}

func dumpState(_ label: String) {
    let buf = term.displayBuffer
    let sel = view.selection!
    print("[\(label)] alt=\(term.isDisplayBufferAlternate) yBase=\(buf.yBase) yDisp=\(buf.yDisp) lines=\(buf.lines.count) selActive=\(sel.active) start=(\(sel.start.row),\(sel.start.col)) end=(\(sel.end.row),\(sel.end.col))")
}

func screenDump() -> [String] { view.visibleAlternateScreenLines() }

// ---- Phase A: 回放到第一次滚轮注入之前（transcript 已渲染完） ----
var idx = 0
var chunkCount = 0
var totalBytes = 0
var lastYBase = -1
while idx < records.count {
    let r = records[idx]
    if r.kind == "in", let note = r.note, note.hasPrefix("wheel") { break }
    if r.kind == "out", let d = Data(base64Encoded: r.data) {
        let bytes = [UInt8](d)
        view.feed(byteArray: bytes[...])
        chunkCount += 1
        totalBytes += bytes.count
        let buf = term.displayBuffer
        if buf.yBase != lastYBase {
            print("  [A#\(chunkCount)] yBase \(lastYBase) -> \(buf.yBase)  (\(bytes.count)B \(summarize(bytes)))")
            lastYBase = buf.yBase
        } else if verbose {
            print("  [A#\(chunkCount)] \(bytes.count)B \(summarize(bytes))")
        }
    }
    idx += 1
}
print("Phase A done: \(chunkCount) chunks, \(totalBytes) bytes")
dumpState("A-end")
let screenA = screenDump()
print("---- 屏幕（Phase A 结束） ----")
for (i, l) in screenA.enumerated() { print(String(format: "%3d| %@", i, l)) }
print("----")

guard term.isDisplayBufferAlternate else {
    print("!! 不在备用屏，CC 没进 1049h——录制无效")
    exit(2)
}

// ---- Phase B: 模拟真实用户动作——从屏中下部起选，向上拖到顶边，随录制的滚轮回放 ----
let buf = term.displayBuffer
let rows = term.rows
let anchorRow = buf.yDisp + 20   // 锚在 transcript 内容区中部（避开底部固定输入框/状态栏与空行）
view.selection.setSelection(start: Position(col: 0, row: anchorRow), end: Position(col: 5, row: anchorRow - 1))
view.isSelectionDragInProgress = true
let topPoint = CGPoint(x: 20, y: view.bounds.height - 1)   // 顶边 → delta<0 → 向上
view.updateSelectionAutoScroll(at: topPoint)
dumpState("B-armed")
let anchorLineText = buf.translateBufferLineToString(lineIndex: anchorRow, trimRight: true, skipNullCellsFollowingWide: true)
print("锚点行内容: \"\(anchorLineText)\"")

var prevDump = screenDump()
var wheelCount = 0
var feedAfterWheel = 0
while idx < records.count {
    let r = records[idx]
    idx += 1
    if r.kind == "in", let note = r.note, note.hasPrefix("wheel-up") {
        wheelCount += 1
        let forwarded = view.performSelectionAutoScroll(delta: -2, point: topPoint)
        if verbose || wheelCount <= 5 {
            print("[wheel#\(wheelCount)] forwarded=\(forwarded)")
        }
        continue
    }
    if r.kind == "in", let note = r.note, note.hasPrefix("wheel-down") { break }
    guard r.kind == "out", let d = Data(base64Encoded: r.data) else { continue }
    let bytes = [UInt8](d)
    view.feed(byteArray: bytes[...])
    feedAfterWheel += 1
    let cur = screenDump()
    let myShift = view.detectAlternateContentShift(previous: prevDump, current: cur)?.shift
    let sel = view.selection!
    let b = term.displayBuffer
    print("[B#\(feedAfterWheel)] \(bytes.count)B \(summarize(bytes)) | 相邻帧K=\(myShift.map(String.init) ?? "nil") yBase=\(b.yBase) yDisp=\(b.yDisp) | sel=\(sel.active ? "(\(sel.start.row),\(sel.start.col))-(\(sel.end.row),\(sel.end.col))" : "無")")
    prevDump = cur
}
print("Phase B done: wheels=\(wheelCount) feeds=\(feedAfterWheel)")
dumpState("B-end")
print("---- 屏幕（Phase B 结束） ----")
for (i, l) in screenDump().enumerated() { print(String(format: "%3d| %@", i, l)) }
print("----")

// ---- Phase C: 复制结果检查 ----
let copied = view.selectedTextForCopy()
print("---- 复制文本（\(copied.components(separatedBy: "\n").count) 行） ----")
print(copied)
print("----")
// 锚点行内容是否仍被覆盖（跟随成功的标志）
if !anchorLineText.trimmingCharacters(in: .whitespaces).isEmpty {
    print("复制含锚点行: \(copied.contains(anchorLineText.trimmingCharacters(in: .whitespaces)))")
}
