//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/29/20.
//

import Foundation
import Testing

@testable import SwiftTerm

#if os(macOS)
import AppKit
#endif

final class SelectionTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        print ("here")
    }
    
    @Test func testDoesNotCrashWhenSelectingWordOrExpressionOutsideColumnRange() {
        let terminal = Terminal(delegate: self, options: TerminalOptions (cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed (text: "1234567890")
        
        // depending on the size of terminal view, there might be a space near the margin where the user
        // clicks which might result in a col or row outside the bounds of terminal,
        selection.selectWordOrExpression(at: Position(col: -1, row: 0), in: terminal.buffer)
        selection.selectWordOrExpression(at: Position(col: 11, row: 0), in: terminal.buffer)
    }
    
    @Test func testDoesNotCrashWhenSelectingWordOrExpressionOutsideRowRange() {
        let terminal = Terminal(delegate: self, options: TerminalOptions (cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed (text: "1234567890")

        // depending on the size of terminal view, there might be a space near the margin where the user
        // clicks which might result in a col or row outside the bounds of terminal,
        selection.selectWordOrExpression(at: Position (col: 0, row: -1), in: terminal.buffer)

    }

    @Test func testSelectWordOrExpressionSelectsWord() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world")

        selection.selectWordOrExpression(at: Position(col: 1, row: 0), in: terminal.buffer)

        #expect(selection.getSelectedText() == "hello")
    }

    @Test func testSelectWordOrExpressionSelectsBalancedParens() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "(abc) def")

        selection.selectWordOrExpression(at: Position(col: 0, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "(abc)")

        selection.selectWordOrExpression(at: Position(col: 4, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "(abc)")
    }

#if os(macOS)
    private func mouseDraggedEvent(at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)!
    }

    private func mouseUpEvent(at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)!
    }

    private func mouseDownEvent(at point: CGPoint, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1)!
    }

    // Test only on macOS due to differences in how frames are handled on mac and iOS
    @Test func testMouseHitCorrectWhenScrolled() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 10, height: 10)))

        for _ in 0..<100 {
            view.terminal.feed (text: "12345")
        }

        // Scroll all the way down, check the bottom-left corner
        view.scrollTo(row: 100)
        #expect(view.calculateMouseHit(at: CGPoint(x: 0, y: 0)).grid.row == 100)

        // Scroll all the way back up, check the top-left corner
        view.scrollTo(row: 1)
        #expect(view.calculateMouseHit(at: CGPoint(x: 0, y: 10)).grid.row == 1)
    }

    // Relay regression: 拖拽到视口上/下边缘时，选区应靠自动滚动继续扩展。
    // 此前大回滚撤掉了驱动自动滚动的 timer（4ff44c1），此处守住其行为。
    @Test func testSelectionAutoScrollDeltaUsesEdgesAndDirection() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: (0..<80).map { "line \($0)" }.joined(separator: "\n"))

        #expect(view.selectionAutoScrollDelta(for: CGPoint(x: 20, y: view.bounds.midY)) == 0)

        view.selection.startSelection(row: 0, col: 0)
        #expect(view.selectionAutoScrollDelta(for: CGPoint(x: 20, y: view.bounds.midY)) == 0)

        let bottomDelta = view.selectionAutoScrollDelta(for: CGPoint(x: 20, y: 0))
        let topDelta = view.selectionAutoScrollDelta(for: CGPoint(x: 20, y: view.bounds.height))
        #expect(bottomDelta > 0)
        #expect(topDelta < 0)

        // 拖到窗口外越远滚得越快；速度曲线封顶 16 行/帧，长日志快进也不会失控。
        let farBottomDelta = view.selectionAutoScrollDelta(for: CGPoint(x: 20, y: -view.cellDimension.height * 8))
        #expect(farBottomDelta > bottomDelta)
        #expect(farBottomDelta <= 16)

        let veryFarDelta = view.selectionAutoScrollDelta(for: CGPoint(x: 20, y: -view.cellDimension.height * 40))
        #expect(veryFarDelta == 16)
    }

    @Test func testSelectionAutoScrollStepMovesViewportAndSelection() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: (0..<120).map { "line \($0)" }.joined(separator: "\n"))
        view.scrollTo(row: 10)
        view.selection.startSelection(row: 0, col: 0)

        let edgeInset = max(view.cellDimension.height * 1.5, 24)
        let bottomPoint = CGPoint(x: 20, y: edgeInset - 1)
        let oldYDisp = view.terminal.displayBuffer.yDisp
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint))
        #expect(view.terminal.displayBuffer.yDisp == oldYDisp + 2)
        #expect(view.selection.end.row == min(
            view.terminal.displayBuffer.lines.count - 1,
            view.terminal.displayBuffer.yDisp + view.terminal.displayBuffer.rows - 1
        ))

        let topPoint = CGPoint(x: 20, y: view.bounds.height - edgeInset + 1)
        let scrolledYDisp = view.terminal.displayBuffer.yDisp
        #expect(view.performSelectionAutoScroll(delta: -2, point: topPoint))
        #expect(view.terminal.displayBuffer.yDisp == scrolledYDisp - 2)
        #expect(view.selection.end.row == view.terminal.displayBuffer.yDisp)
    }

    // Relay regression: 守护"驱动自动滚动的 timer 接线"本身，而非仅叶子数学函数。
    // 4ff44c1 被回滚时，恰恰是这个 timer 没人驱动；上面两个测试只覆盖叶子函数，
    // 即便接线再次被撤掉也照样通过。此测试要求：边缘点武装 timer、中间点解除。
    @Test func testUpdateSelectionAutoScrollArmsTimerAtEdgeOnly() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: (0..<120).map { "line \($0)" }.joined(separator: "\n"))
        view.scrollTo(row: 10)
        view.selection.startSelection(row: 0, col: 0)

        // 视口中间：不应武装
        view.updateSelectionAutoScroll(at: CGPoint(x: 20, y: view.bounds.midY))
        #expect(view.selectionAutoScrollIsActive == false)

        // 底部边缘：应武装 timer（这正是回滚时丢掉的驱动）
        view.updateSelectionAutoScroll(at: CGPoint(x: 20, y: 0))
        #expect(view.selectionAutoScrollIsActive == true)

        // 回到中间：应解除并清理 timer
        view.updateSelectionAutoScroll(at: CGPoint(x: 20, y: view.bounds.midY))
        #expect(view.selectionAutoScrollIsActive == false)
    }

    // Relay regression: 真实 mouseDragged 每帧也必须把选区终点贴到自动滚动边缘。
    // 0.4.16 只修了 timer tick，拖动事件本身仍把 selection.end 拉回鼠标所在行，
    // 结果表现为"能滚，但高亮选区不能连续延伸"。
    @Test func testMouseDraggedAtAutoScrollEdgeKeepsSelectionAtVisibleEdgeAcrossTicks() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: (0..<120).map { "line \($0)" }.joined(separator: "\r\n"))
        view.scrollTo(row: 10)
        view.selection.startSelection(row: 0, col: 0)

        let edgeInset = max(view.cellDimension.height * 1.5, 24)
        let dragX = view.cellDimension.width * 20
        let bottomPoint = CGPoint(x: dragX, y: edgeInset - 0.5)
        view.mouseDragged(with: mouseDraggedEvent(at: bottomPoint))
        #expect(view.selection.end.row == min(
            view.terminal.displayBuffer.lines.count - 1,
            view.terminal.displayBuffer.yDisp + view.terminal.displayBuffer.rows - 1
        ))
        #expect(view.selectionAutoScrollIsActive == true)

        let oldYDisp = view.terminal.displayBuffer.yDisp
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint))
        #expect(view.terminal.displayBuffer.yDisp == oldYDisp + 2)
        #expect(view.selection.end.row == min(
            view.terminal.displayBuffer.lines.count - 1,
            view.terminal.displayBuffer.yDisp + view.terminal.displayBuffer.rows - 1
        ))

        view.mouseDragged(with: mouseDraggedEvent(at: bottomPoint))
        #expect(view.selection.end.row == min(
            view.terminal.displayBuffer.lines.count - 1,
            view.terminal.displayBuffer.yDisp + view.terminal.displayBuffer.rows - 1
        ))
        #expect(view.selectedTextForCopy().contains("line 26"))

        let topPoint = CGPoint(x: dragX, y: view.bounds.height - edgeInset + 0.5)
        view.mouseDragged(with: mouseDraggedEvent(at: topPoint))
        #expect(view.selection.end.row == view.terminal.displayBuffer.yDisp)
        #expect(view.selectionAutoScrollIsActive == true)
    }

    // Relay 回归（跨屏连续选中，取代旧版"锁可见屏"）：Claude Code/codex 用 CUP 就地重绘、
    // 从不把旧行吐进任何缓冲（yBase 恒为 0），备用屏本地无历史可滚。拖到边缘时改为把滚轮/
    // 方向键转发给程序、让它翻出下一屏，同时把每一帧的选中文本累积起来——高亮受限于当前帧
    // （只能显示程序刚重绘的内容），但复制结果应当囊括已经被滚出可见区的历史内容。
    @Test func testSelectionAutoScrollOnAlternateScreenWithoutScrollbackForwardsAndAccumulates() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let delegate = CapturingTerminalViewDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: "\u{1B}[?1000h")
        // CUP 就地重绘三行、不发换行 → 不产生 alt scrollback（模拟 Claude Code frame 1）。
        view.feed(text: "\u{1B}[Hframe1 top\r\nframe1 mid\r\nframe1 bottom")
        #expect(view.terminal.isDisplayBufferAlternate == true)
        #expect(view.terminal.mouseMode != .off)
        #expect(view.terminal.displayBuffer.yBase == 0)

        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 10, row: 0))
        let bottomPoint = CGPoint(x: view.cellDimension.width * 10, y: 0)
        delegate.sent.removeAll()

        // 无本地历史可滚，但仍要武装 timer——转发与否交给 performSelectionAutoScroll 内部
        // 判断，不再在这一层锁死为 0（区别于旧版"锁可见屏"）。
        #expect(view.selectionAutoScrollDelta(for: bottomPoint) != 0)
        view.updateSelectionAutoScroll(at: bottomPoint)
        #expect(view.selectionAutoScrollIsActive == true)

        // 拖到边缘：转发滚轮/方向键给程序，选区延伸到底部可见行。
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint) == true)
        #expect(delegate.sent.isEmpty == false)
        #expect(view.selection.end.row == view.terminal.displayBuffer.rows - 1)

        // 模拟程序收到滚动后就地重绘出下一屏：整体上移一行，顶部露出全新内容，
        // frame1 的顶行已经不在当前帧里了。
        view.feed(text: "\u{1B}[Hframe1 mid\r\nframe1 bottom\r\nframe2 new")

        // 复制结果应当同时包含 frame1 顶部（已经被滚出可见区，当前 selection.getSelectedText()
        // 单独读不到）和 frame2 新露出的内容——这正是"累积"要做到的事。
        let copied = view.selectedTextForCopy()
        #expect(copied.contains("frame1 top"))
        #expect(copied.contains("frame2 new"))
    }

    // Relay 回归（51a3fbc 点名的历史坑之一："按任意长度（含 1 字符）overlap 拼接易误删行"）：
    // 早期版本的合并算法允许短至 1 行的重叠就采信，两帧恰好在某个短公共行（复用的分隔符/
    // 提示符）处巧合相同时会被误判成"同一行的延续"，把 current 里紧跟着的那次独立重复吞掉——
    // 两次真实出现的内容被错并成一次。修复要求最短可信重叠行数，此测试直接验证这个契约。
    @Test func testMergedAlternateSelectionAutoScrollTextIgnoresShortCoincidentalOverlap() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let existing = "first block A\nfirst block B\n---"
        // current 恰好也以同一个分隔符 "---" 开头，但这是一次无关的、独立的巧合重复
        // （不是同一次滚动里真正延续下来的那一行），后面跟着全新内容。
        let current = "---\nsecond block C\nsecond block D"
        let merged = view.mergedAlternateSelectionAutoScrollText(existing: existing, current: current, direction: .down)

        #expect(merged.contains("first block A"))
        #expect(merged.contains("first block B"))
        #expect(merged.contains("second block C"))
        #expect(merged.contains("second block D"))
        // 关键断言：分隔符应当保留两次真实出现（一次来自 existing 结尾，一次来自 current
        // 开头），而不是被 1 行巧合匹配误吞成一次。
        let separatorOccurrences = merged.components(separatedBy: "---").count - 1
        #expect(separatorOccurrences == 2)
    }

    // Relay 回归（51a3fbc 点名的历史坑之一："松手后流式输出污染 ⌘C"）：拖拽一旦结束，累积器
    // 必须立刻封存。若此刻还欠一次 feedFinish 回调，程序在松手之后继续输出（哪怕只是常规的
    // 流式刷新，不需要用户再有任何动作）不应该让复制文本被悄悄追加新内容。
    @Test func testMouseUpSealsAlternateSelectionAccumulatorAgainstLaterStreaming() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let delegate = CapturingTerminalViewDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: "\u{1B}[?1000h")
        view.feed(text: "\u{1B}[Hframe A\r\nframe B\r\nframe C")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 7, row: 0))
        view.isSelectionDragInProgress = true
        let bottomPoint = CGPoint(x: view.cellDimension.width * 7, y: 0)
        view.updateSelectionAutoScroll(at: bottomPoint)

        // 拖到边缘触发一次转发；不等程序应答就直接松手（needsCaptureAfterFeed 还悬着）。
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint) == true)
        view.mouseUp(with: mouseUpEvent(at: bottomPoint))
        let sealedText = view.selectedTextForCopy()
        #expect(sealedText.isEmpty == false)

        // 松手之后程序仍在正常输出，不应该再改写已经封存的复制文本。
        view.feed(text: "\u{1B}[Hunrelated 1\r\nunrelated 2\r\nunrelated 3")
        #expect(view.selectedTextForCopy() == sealedText)
        #expect(view.selectedTextForCopy().contains("unrelated") == false)
    }

    // Relay 回归（51a3fbc 点名的历史坑之一："缓存污染下次选区复制"）：上一次拖选留下的
    // 累积器，不能泄漏进下一次全新选区的复制结果。
    @Test func testNewMouseDownResetsStaleAlternateSelectionAccumulator() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let delegate = CapturingTerminalViewDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: "\u{1B}[?1000h")
        view.feed(text: "\u{1B}[Hframe A\r\nframe B\r\nframe C")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 7, row: 0))
        view.isSelectionDragInProgress = true
        let bottomPoint = CGPoint(x: view.cellDimension.width * 7, y: 0)
        view.updateSelectionAutoScroll(at: bottomPoint)
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint) == true)
        view.mouseUp(with: mouseUpEvent(at: bottomPoint))
        #expect(view.selectedTextForCopy().isEmpty == false)

        // 全新一次按下：即便还没开始拖，也应该先清掉上一次拖拽遗留的累积文本。
        view.mouseDown(with: mouseDownEvent(at: CGPoint(x: 20, y: bottomPoint.y + view.cellDimension.height * 2)))
        view.selection.setSelection(start: Position(col: 0, row: 1), end: Position(col: 4, row: 1))
        #expect(view.selectedTextForCopy() == view.selection.getSelectedText())
    }

    // Relay regression: Claude Code/codex 会在备用屏里持续输出，旧行从顶部滚出后应进入
    // Relay 本地 scrollback。拖选到边缘时应本地滚动并继续扩展选区，不能转发方向键给程序。
    @Test func testSelectionAutoScrollOnAlternateScreenUsesLocalScrollbackWhenAvailable() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let delegate = CapturingTerminalViewDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: (0..<120).map { "line \($0)" }.joined(separator: "\r\n"))
        #expect(view.terminal.isDisplayBufferAlternate == true)
        #expect(view.terminal.displayBuffer.yBase > 0)

        let maxScrollback = max(0, view.terminal.displayBuffer.lines.count - view.terminal.displayBuffer.rows)
        view.scrollTo(row: max(0, maxScrollback - 3))
        view.selection.startSelection(row: view.terminal.displayBuffer.yDisp, col: 0)

        let bottomPoint = CGPoint(x: 20, y: 0)
        let oldYDisp = view.terminal.displayBuffer.yDisp
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint) == true)
        #expect(view.terminal.displayBuffer.yDisp == min(oldYDisp + 2, maxScrollback))
        #expect(delegate.sent.isEmpty == true)
        #expect(view.selectedTextForCopy() == view.selection.getSelectedText())
    }

    @Test func testAlternateScreenScrollerUsesLocalScrollback() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: (0..<120).map { "line \($0)" }.joined(separator: "\r\n"))

        #expect(view.terminal.isDisplayBufferAlternate == true)
        #expect(view.canScroll == true)
        #expect(view.scrollThumbsize > 0)
        #expect(view.scrollThumbsize < 1)

        view.scrollTo(row: max(0, view.terminal.displayBuffer.lines.count - view.terminal.displayBuffer.rows))
        #expect(view.scrollPosition == 1)
    }

    @Test func testAlternateBufferScrollbackTracksResetAndRuntimeResize() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4, scrollback: 8))
        terminal.feed(text: "\u{1B}[?1049h")
        terminal.feed(text: (0..<20).map { "line \($0)" }.joined(separator: "\r\n"))

        #expect(terminal.isDisplayBufferAlternate == true)
        #expect(terminal.displayBuffer.hasScrollback == true)
        #expect(terminal.displayBuffer.yBase > 0)
        #expect(terminal.altBuffer.disableReflow == true)

        terminal.changeScrollback(2)
        #expect(terminal.altBuffer.hasScrollback == true)
        #expect(terminal.altBuffer.lines.maxLength == terminal.rows + 2)
        #expect(terminal.altBuffer.disableReflow == true)

        terminal.resetToInitialState()
        #expect(terminal.isDisplayBufferAlternate == false)
        #expect(terminal.altBuffer.hasScrollback == true)
        #expect(terminal.altBuffer.lines.maxLength == terminal.rows + 2)
        #expect(terminal.altBuffer.disableReflow == true)
    }

    // Relay 回归（v0.4.5）：「选不中」的真凶是 feedPrepare 每帧无条件 selection.active=false，
    // 在备用屏里把用户刚划下的选区瞬间抹掉——之前只放行 linefeed 不够，feedPrepare 仍清。
    // 备用屏（Claude Code/codex 等全屏 TUI）选区坐标稳定，流式输出绝不应清选区，否则无法复制。
    @Test func testSelectionSurvivesStreamingOnAlternateScreen() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: "\u{1B}[?1049h")
        #expect(view.terminal.isCurrentBufferAlternate == true)
        #expect(view.allowMouseReporting == true)

        view.selection.startSelection(row: 0, col: 0)
        view.selection.dragExtend(row: 0, col: 3)
        #expect(view.selection.active == true)

        // 程序持续刷新（feedPrepare + linefeed 都会触发）；选区必须存活
        view.feed(text: "streaming\nmore output\n")
        #expect(view.selection.active == true)
    }

    // Relay 回归（v0.4.5）：主屏策略——拖拽划选进行中保留选区（支撑「下拖自动滚动选中」），
    // 拖拽结束后恢复「输出滚动即清选区」的原行为，避免选区坐标随回看上滚而错位。
    @Test func testSelectionClearPolicyOnMainScreenDuringAndAfterDrag() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: (0..<5).map { "line \($0)" }.joined(separator: "\n"))

        view.selection.startSelection(row: 0, col: 0)
        view.selection.dragExtend(row: 0, col: 3)

        // 拖拽进行中：流式输出不清选区
        view.isSelectionDragInProgress = true
        view.feed(text: "x\ny\n")
        #expect(view.selection.active == true)

        // 拖拽结束：主屏恢复清除
        view.isSelectionDragInProgress = false
        view.feed(text: "z\n")
        #expect(view.selection.active == false)
    }

    // MARK: - 备用屏拖选：整屏平移检测 + 高亮锚点跟随

    // detectAlternateContentShift 是「高亮选区跟随」和「累积器确定性追加」的共同地基：
    // 它按行对齐前后两帧的整屏文本，容忍 spinner/计时器这类逐帧变化的动画行；
    // 返回带符号平移量（正 = 内容上移，负 = 内容下移）。
    @Test func testDetectAlternateContentShiftFindsShiftDespiteAnimationNoise() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let previous = (0..<12).map { "content line \($0)" }
        // 内容上移 3 行、底部进 3 行新内容，且其中一行是每帧都在变的 spinner 行。
        var current = Array(previous.dropFirst(3)) + ["new line 0", "new line 1", "new line 2"]
        current[4] = "⠧ thinking… (12s)"

        #expect(view.detectAlternateContentShift(previous: previous, current: current)?.shift == 3)
        // 完全相同的两帧 = 原地重绘，平移量 0。
        #expect(view.detectAlternateContentShift(previous: previous, current: previous)?.shift == 0)
        // 整屏换成不相干内容：没有可信对齐，返回 nil（保留基线等完整帧/走保守兜底）。
        let unrelated = (0..<12).map { "other \($0)" }
        #expect(view.detectAlternateContentShift(previous: previous, current: unrelated) == nil)
        // 行数不一致（resize）：nil。
        #expect(view.detectAlternateContentShift(previous: previous, current: Array(previous.dropLast())) == nil)
    }

    @Test func testDetectAlternateContentShiftUpDirection() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let previous = (0..<10).map { "content line \($0)" }
        // 向上翻页：内容整体下移 2 行，顶部进 2 行历史 → 带符号平移量为 -2。
        let current = ["history 0", "history 1"] + Array(previous.dropLast(2))
        #expect(view.detectAlternateContentShift(previous: previous, current: current)?.shift == -2)
    }

    // 真实 CC 布局（PTY 录制回放实证）：只有 transcript 区滚动，底部输入框/边框/状态栏
    // 固定不动。整屏占比类判据会被固定区打穿（38 行里最多 30 行能对上 <80%，每帧 nil）；
    // 「变化过」过滤后固定区不计分，检测只看真正滚动的区，且新进行取自滚动区尾部而非屏底。
    @Test func testDetectAlternateContentShiftWithFixedFooter() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let footer = ["", "───────", "❯ ", "───────", "  [Model] │ proj", "  Usage ██ 23%"]
        let prevBody = (10..<40).map { "  \($0)" }
        let previous = prevBody + footer
        // transcript 区上移 2 行、尾部进 2 行新内容，footer 纹丝不动。
        let currBody = Array(prevBody.dropFirst(2)) + ["  40", "  41"]
        let current = currBody + footer
        let result = view.detectAlternateContentShift(previous: previous, current: current)
        #expect(result?.shift == 2)
        // 新进行的位置在滚动区尾部（行 28-29），不是屏幕底部。
        #expect(result?.changedHi == currBody.count - 1)
        #expect(result?.matchedHi == currBody.count - 3)
    }

    // 捕获文本的稳定性契约：边缘侧行必须取全宽。旧版按鼠标列截断末行，同一内容行下一帧
    // 变成内部行后文本就变了，重叠比对必然失配——几乎每帧都退化成保守拼接、复制出重复块。
    @Test func testAlternateSelectionCaptureTextTakesFullWidthAtEdgeSide() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: "\u{1B}[Halpha line 0\r\nalpha line 1\r\nalpha line 2")

        // 向下拖：末行（边缘侧）虽然 end 停在第 2 列，捕获仍取整行；首行从锚点列起。
        view.selection.setSelection(start: Position(col: 6, row: 0), end: Position(col: 2, row: 2))
        let downText = view.alternateSelectionCaptureText(direction: .down)
        #expect(downText == "line 0\nalpha line 1\nalpha line 2")

        // 向上拖：首行（边缘侧）取整行，末行（锚点侧）截到锚点列（含）。
        view.selection.setSelection(start: Position(col: 3, row: 2), end: Position(col: 5, row: 0))
        let upText = view.alternateSelectionCaptureText(direction: .up)
        #expect(upText == "alpha line 0\nalpha line 1\nalph")
    }

    // 用户可感的核心行为（本次修复的主诉）：备用屏拖到边缘转发滚动后，程序整屏重绘使内容
    // 上移，选区锚点必须随内容同步平移——仍在屏内的已选内容保持高亮，而不是"滚动过程中
    // 之前选中的内容消失"；滚出屏幕后锚点钉在屏顶展开整行，复制由累积器保证完整、不重复。
    @Test func testAlternateSelectionAutoScrollShiftsAnchorToFollowContent() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let delegate = CapturingTerminalViewDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: "\u{1B}[?1000h")
        let rows = view.terminal.rows
        #expect(rows >= 8)
        let frame1 = (0..<rows).map { "alpha line \($0)" }
        view.feed(text: "\u{1B}[2J\u{1B}[H" + frame1.joined(separator: "\r\n"))
        #expect(view.terminal.displayBuffer.yBase == 0)

        // 锚点按在第 3 行第 2 列，向下拖到底部边缘。
        view.selection.setSelection(start: Position(col: 2, row: 3), end: Position(col: 5, row: 4))
        view.isSelectionDragInProgress = true
        let bottomPoint = CGPoint(x: 20, y: 0)
        view.updateSelectionAutoScroll(at: bottomPoint)
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint) == true)
        #expect(delegate.sent.isEmpty == false)
        #expect(view.selection.start.row == 3)

        // 程序响应滚动：整屏上移 2 行，底部露出 2 行新内容。
        let frame2 = Array(frame1.dropFirst(2)) + ["beta line 0", "beta line 1"]
        view.feed(text: "\u{1B}[2J\u{1B}[H" + frame2.joined(separator: "\r\n"))

        // 锚点随内容上移 2 行（3→1），列不变：屏内已选内容的高亮跟着内容走。
        #expect(view.selection.start.row == 1)
        #expect(view.selection.start.col == 2)

        // 再滚一轮：锚点越出屏顶，钉在第 0 行并展开到行首。
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint) == true)
        let frame3 = Array(frame1.dropFirst(4)) + (0..<4).map { "beta line \($0)" }
        view.feed(text: "\u{1B}[2J\u{1B}[H" + frame3.joined(separator: "\r\n"))
        #expect(view.selection.start.row == 0)
        #expect(view.selection.start.col == 0)

        // 复制文本囊括从锚点行起被滚出的历史与新进内容，且确定性追加不产生重复块。
        // 首行从锚点列（第 2 列）起截断，与普通选区复制语义一致。
        let copied = view.selectedTextForCopy()
        #expect(copied.hasPrefix("pha line 3\n"))
        #expect(copied.contains("alpha line \(rows - 1)"))
        #expect(copied.contains("beta line 3"))
        #expect(copied.components(separatedBy: "alpha line 5\n").count == 2)
    }

    // 整屏比对找不到可信平移量时：单帧失败可能只是撕裂帧，锚点与基线都不动；连续多帧
    // （alternateSelectionTrackingMaxFailures = 4）都对不上才判定内容真被整体换掉，此时
    // 复制走保守拼接兜底（宁可重复不可丢内容），锚点仍原地不动——错移会罩进没选过的行。
    @Test func testAlternateSelectionAutoScrollKeepsAnchorWhenShiftUntrusted() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let delegate = CapturingTerminalViewDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: "\u{1B}[?1000h")
        let rows = view.terminal.rows
        let frame1 = (0..<rows).map { "alpha line \($0)" }
        view.feed(text: "\u{1B}[2J\u{1B}[H" + frame1.joined(separator: "\r\n"))

        view.selection.setSelection(start: Position(col: 0, row: 3), end: Position(col: 5, row: 4))
        view.isSelectionDragInProgress = true
        let bottomPoint = CGPoint(x: 20, y: 0)
        view.updateSelectionAutoScroll(at: bottomPoint)
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint) == true)

        // 程序整屏换成不相干内容（大重绘/翻整页）：无可信对齐。
        let frame2 = (0..<rows).map { "gamma line \($0)" }
        view.feed(text: "\u{1B}[2J\u{1B}[H" + frame2.joined(separator: "\r\n"))

        // 前几帧被当作可能的撕裂帧：锚点不动、累积器不污染。
        #expect(view.selection.start.row == 3)
        #expect(view.selectedTextForCopy().contains("gamma") == false)

        // 连续失败满 4 帧（含上面 1 帧）：判定内容真换掉，触发兜底拼接。
        for _ in 0..<3 {
            view.feed(text: "\u{1B}[2J\u{1B}[H" + frame2.joined(separator: "\r\n"))
        }
        #expect(view.selection.start.row == 3)
        // 兜底拼接：老内容和新内容都在复制结果里。
        let copied = view.selectedTextForCopy()
        #expect(copied.contains("alpha line 3"))
        #expect(copied.contains("gamma line \(rows - 1)"))
    }

    // shiftDragAnchor 的钳位契约：锚点只在可见屏内平移，越界钉边并展开整行；未激活不动。
    @Test func testShiftDragAnchorClampsToVisibleScreen() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: (0..<5).map { "line \($0)" }.joined(separator: "\r\n"))

        // 未激活：no-op。
        selection.shiftDragAnchor(rowsBy: -2)
        #expect(selection.start == Position(col: 0, row: 0))

        selection.startSelection(row: 3, col: 2)
        selection.dragExtend(row: 4, col: 5)
        selection.shiftDragAnchor(rowsBy: -1)
        #expect(selection.start == Position(col: 2, row: 2))
        #expect(selection.end == Position(col: 5, row: 4))

        // 越出屏顶：钉在可见区顶行、展开到行首。
        selection.shiftDragAnchor(rowsBy: -5)
        #expect(selection.start == Position(col: 0, row: 0))

        // 越出屏底：钉在可见区底行、展开到行尾。
        selection.shiftDragAnchor(rowsBy: 99)
        #expect(selection.start == Position(col: terminal.cols - 1, row: 4))
    }

    // 真实 CC 的一帧重绘常拆成多个 PTY 块到达（每块都触发一次 feedFinish）。撕裂的半帧对
    // 不出可信平移量时必须保留基线原地等待，等完整帧到齐后一次对出跨块累计平移量——
    // v0.5.8 只处理转发后的第一个 feed，被撕裂帧打穿：半帧污染累积器（复制出重复块）、
    // 真正滚动到位的完整帧被跳过（锚点从未平移、高亮当场脱开）。
    @Test func testAlternateSelectionAutoScrollSurvivesTornFrames() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let delegate = CapturingTerminalViewDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: "\u{1B}[?1000h")
        let rows = view.terminal.rows
        #expect(rows >= 8)
        let frame1 = (0..<rows).map { "alpha line \($0)" }
        view.feed(text: "\u{1B}[2J\u{1B}[H" + frame1.joined(separator: "\r\n"))

        view.selection.setSelection(start: Position(col: 2, row: 3), end: Position(col: 5, row: 4))
        view.isSelectionDragInProgress = true
        let bottomPoint = CGPoint(x: 20, y: 0)
        view.updateSelectionAutoScroll(at: bottomPoint)
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint) == true)

        // 程序响应滚动：内容上移 2 行，但这帧重绘拆成两个 PTY 块到达。
        let frame2 = Array(frame1.dropFirst(2)) + ["beta line 0", "beta line 1"]
        // 第一块：2J 清屏后只画了前 5 行——撕裂帧，对不出可信平移量。
        view.feed(text: "\u{1B}[2J\u{1B}[H" + frame2.prefix(5).joined(separator: "\r\n") + "\r\n")
        #expect(view.selection.start.row == 3)
        // 第二块补齐其余行：完整帧到齐，与保留的老基线一次对出平移量 2，锚点 3→1。
        view.feed(text: frame2.dropFirst(5).joined(separator: "\r\n"))
        #expect(view.selection.start.row == 1)
        #expect(view.selection.start.col == 2)

        // 复制无重复块：撕裂帧期间没有走兜底拼接污染累积器。
        let copied = view.selectedTextForCopy()
        #expect(copied.components(separatedBy: "beta line 0").count == 2)
        #expect(copied.contains("beta line 1"))
        #expect(copied.components(separatedBy: "alpha line 5\n").count == 2)
    }

    // 滚轮浏览/松手后程序继续流式输出（非拖拽态）：选区两端一起随内容平移，高亮继续罩住
    // 相同内容；选区整体滚出屏幕且没有累积复制文本时才自动清除。取代旧的「选中态滚轮
    // 立即清选区」。
    @Test func testAlternateSelectionBrowseTrackingShiftsWholeSelection() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: "\u{1B}[?1049h")
        let rows = view.terminal.rows
        #expect(rows >= 10)
        let frame1 = (0..<rows).map { "alpha line \($0)" }
        view.feed(text: "\u{1B}[2J\u{1B}[H" + frame1.joined(separator: "\r\n"))

        view.selection.setSelection(start: Position(col: 2, row: 3), end: Position(col: 5, row: 5))
        // 浏览态（isSelectionDragInProgress == false）：滚轮转发路径会武装内容跟踪。
        view.armAlternateSelectionTracking()

        // 内容上移 2 行：选区两端同步平移，高亮跟着内容走。
        let frame2 = Array(frame1.dropFirst(2)) + ["beta line 0", "beta line 1"]
        view.feed(text: "\u{1B}[2J\u{1B}[H" + frame2.joined(separator: "\r\n"))
        #expect(view.selection.start == Position(col: 2, row: 1))
        #expect(view.selection.end == Position(col: 5, row: 3))

        // 再上移 4 行：选区整体滚出屏顶，无累积文本 → 自动清除。
        let frame3 = Array(frame1.dropFirst(6)) + (0..<6).map { "beta line \($0)" }
        view.feed(text: "\u{1B}[2J\u{1B}[H" + frame3.joined(separator: "\r\n"))
        #expect(view.selection.active == false)
    }

    // shiftSelectionTrackingContent 的钳位契约：两端随内容平移、越界端钉边展开；
    // 整体滚出可见区时收敛成贴边残段并返回 false。
    @Test func testShiftSelectionTrackingContentClampsAndReportsExit() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: (0..<5).map { "line \($0)" }.joined(separator: "\r\n"))
        selection.startSelection(row: 1, col: 2)
        selection.dragExtend(row: 3, col: 4)

        #expect(selection.shiftSelectionTrackingContent(rowsBy: -1) == true)
        #expect(selection.start == Position(col: 2, row: 0))
        #expect(selection.end == Position(col: 4, row: 2))

        // 部分越出屏顶：越出端钉在顶行、展开到行首，另一端正常平移。
        #expect(selection.shiftSelectionTrackingContent(rowsBy: -1) == true)
        #expect(selection.start == Position(col: 0, row: 0))
        #expect(selection.end == Position(col: 4, row: 1))

        // 整体滚出：收敛为顶部贴边残段并报告 false（调用方决定清除或保留供 ⌘C）。
        #expect(selection.shiftSelectionTrackingContent(rowsBy: -2) == false)
        #expect(selection.start == Position(col: 0, row: 0))
        #expect(selection.end == Position(col: 0, row: 0))
    }
#endif

    // MARK: - Selection Tests Ported from Ghostty

    /// Test that selection start and end are properly ordered
    /// From Ghostty: "Selection: order, standard"
    @Test func testSelectionOrdering() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "ABCDE\nFGHIJ\nKLMNO")

        // Set selection from higher position to lower position
        selection.setSelection(
            start: Position(col: 5, row: 2),
            end: Position(col: 2, row: 0)
        )

        // Selection service should keep start before end internally
        // or the getSelectedText should work regardless of order
        let text = selection.getSelectedText()
        #expect(text.contains("ABCDE") || text.contains("CDE"))
    }

    /// Test selecting entire line
    /// From Ghostty: row selection
    @Test func testSelectRow() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "line1\nline2\nline3")

        selection.select(row: 1)

        #expect(selection.active)
        #expect(selection.start.row == 1)
        #expect(selection.end.row == 1)
        #expect(selection.start.col == 0)
        #expect(selection.end.col == terminal.cols - 1)
    }

    /// Test select all
    /// From Ghostty: selection of entire buffer
    @Test func testSelectAll() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "line1\nline2\nline3")

        selection.selectAll()

        #expect(selection.active)
        #expect(selection.start.col == 0)
        #expect(selection.start.row == 0)
    }

    /// Test drag extend moves end position
    /// From Ghostty: selection adjustment
    @Test func testDragExtendMovesEnd() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "ABCDEFGHIJ")

        // Start selection at position 2
        selection.startSelection(row: 0, col: 2)

        // Drag to position 7
        selection.dragExtend(row: 0, col: 7)

        #expect(selection.end.col == 7)
        #expect(selection.end.row == 0)
    }

    /// Test drag extend across multiple lines
    /// From Ghostty: multi-line selection
    @Test func testDragExtendMultiLine() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "line1\nline2\nline3")

        // Start selection on line 0
        selection.startSelection(row: 0, col: 2)

        // Drag to line 2
        selection.dragExtend(row: 2, col: 3)

        #expect(selection.isMultiLine)
        #expect(selection.end.row == 2)
    }

    /// Test shift extend can swap start and end
    /// From Ghostty: "Selection: adjust left/right"
    @Test func testShiftExtendSwapsWhenNeeded() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "ABCDEFGHIJ")

        // Start selection at position 5
        selection.startSelection(row: 0, col: 5)
        selection.dragExtend(row: 0, col: 7)

        // Now shift extend to position 2 (before start)
        selection.shiftExtend(row: 0, col: 2)

        // Selection should now include position 2
        let text = selection.getSelectedText()
        #expect(text.contains("C") || selection.start.col <= 2)
    }

    /// Test selection with empty line
    @Test func testSelectionWithEmptyContent() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)

        // Don't feed any text - buffer should be empty/spaces
        selection.startSelection(row: 0, col: 0)
        selection.dragExtend(row: 0, col: 5)

        // Should not crash, text may be empty or spaces
        let text = selection.getSelectedText()
        #expect(text.count >= 0)
    }

    /// Test selection active state
    /// From Ghostty: selection state management
    @Test func testSelectionActiveState() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "test content")

        #expect(!selection.active)

        selection.startSelection(row: 0, col: 0)
        #expect(selection.active)

        selection.active = false
        #expect(!selection.active)
    }

    /// Test hasSelectionRange
    @Test func testHasSelectionRange() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "test content")

        // Initially no range
        #expect(!selection.hasSelectionRange)

        // Start selection - still no range (start == end)
        selection.startSelection(row: 0, col: 5)
        #expect(!selection.hasSelectionRange)

        // Extend - now has range
        selection.dragExtend(row: 0, col: 8)
        #expect(selection.hasSelectionRange)
    }

    /// Test selection text extraction with newlines
    /// From Ghostty: formatter tests for selection
    @Test func testSelectionTextWithNewlines() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "AAA\r\nBBB\r\nCCC")

        // Use selectAll to get everything
        selection.selectAll()

        let text = selection.getSelectedText()
        // Should contain content from multiple lines
        #expect(text.contains("AAA"))
        #expect(text.contains("BBB"))
        #expect(text.contains("CCC"))
    }

    /// Test word selection at word boundaries
    /// From Ghostty: word boundary selection
    @Test func testWordSelectionAtBoundary() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world test")

        // Select word at start of "world"
        selection.selectWordOrExpression(at: Position(col: 6, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "world")

        // Select word at end of "world"
        selection.selectWordOrExpression(at: Position(col: 10, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "world")
    }

    /// Test balanced expression selection with nested brackets
    @Test func testBalancedExpressionNested() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "foo(bar[baz])end")

        // Click on opening paren - should select balanced expression
        selection.selectWordOrExpression(at: Position(col: 3, row: 0), in: terminal.buffer)
        let text = selection.getSelectedText()

        // Should include the full balanced expression
        #expect(text == "(bar[baz])")
    }

    /// Test balanced expression with braces
    @Test func testBalancedExpressionBraces() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "x{a{b}c}y")

        selection.selectWordOrExpression(at: Position(col: 1, row: 0), in: terminal.buffer)
        let text = selection.getSelectedText()

        #expect(text == "{a{b}c}")
    }

    /// Test selection mode persists during extension
    @Test func testSelectionModePersistence() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world test")

        // Start character selection
        selection.startSelection(row: 0, col: 5)
        #expect(selection.selectionMode == .character)

        // Select row
        selection.select(row: 0)
        #expect(selection.selectionMode == .row)
    }

    /// Test soft start doesn't activate selection visually
    @Test func testSoftStartBehavior() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "test")

        // Soft start should set position but selection should still be active
        // (in SwiftTerm, setSoftStart calls setActiveAndNotify)
        selection.setSoftStart(row: 0, col: 3)

        // The position should be set
        #expect(selection.start.col == 3)
        #expect(selection.end.col == 3)
    }
}

#if os(macOS)
final class CapturingTerminalViewDelegate: TerminalViewDelegate {
    var sent: [UInt8] = []

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
