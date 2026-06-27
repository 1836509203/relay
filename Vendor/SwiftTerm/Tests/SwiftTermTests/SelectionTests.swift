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

    // Relay regression: vim/less/htop 这类备用屏程序自己管理可见内容，通常不会产生
    // Relay 本地 scrollback。此时边缘拖选必须把滚动转发给 TUI，否则窗口外的内容永远滚不进来。
    @Test func testSelectionAutoScrollOnAlternateScreenSendsScrollInput() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let delegate = CapturingTerminalViewDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1B}[?1049h")
        #expect(view.terminal.isDisplayBufferAlternate == true)

        view.selection.startSelection(row: max(view.terminal.rows - 2, 0), col: 0)
        let bottomPoint = CGPoint(x: 20, y: 0)

        #expect(view.selectionAutoScrollDelta(for: bottomPoint) > 0)
        view.updateSelectionAutoScroll(at: bottomPoint)
        #expect(view.selectionAutoScrollIsActive == true)

        let oldYDisp = view.terminal.displayBuffer.yDisp
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint) == true)
        #expect(view.terminal.displayBuffer.yDisp == oldYDisp)
        #expect(delegate.sent == EscapeSequences.moveDownNormal + EscapeSequences.moveDownNormal)
        #expect(view.selection.end.row == min(
            view.terminal.displayBuffer.lines.count - 1,
            view.terminal.displayBuffer.yDisp + view.terminal.displayBuffer.rows - 1
        ))

        delegate.sent.removeAll()
        view.feed(text: "\u{1B}[?1000h")
        #expect(view.terminal.mouseMode != .off)
        #expect(view.performSelectionAutoScroll(delta: 2, point: bottomPoint) == true)
        #expect(delegate.sent.isEmpty == false)
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

    // Relay regression: Claude Code/codex 这类 mouse-aware TUI 可能既有 Relay 本地
    // alt scrollback，又有程序内部视口历史。本地 scrollback 到边界后，继续拖选到
    // 边缘应 fallback 转发鼠标滚轮，否则表现为"选区滚到边界就停住"。
    @Test func testSelectionAutoScrollForwardsAtAlternateScrollbackBoundaryWhenMouseTrackingEnabled() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        let delegate = CapturingTerminalViewDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: (0..<120).map { "line \($0)" }.joined(separator: "\r\n"))
        view.feed(text: "\u{1B}[?1000h")
        #expect(view.terminal.isDisplayBufferAlternate == true)
        #expect(view.terminal.displayBuffer.yBase > 0)
        #expect(view.terminal.mouseMode != .off)

        view.scrollTo(row: 0)
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        delegate.sent.removeAll()

        let topPoint = CGPoint(x: view.cellDimension.width * 6, y: view.bounds.height)
        #expect(view.performSelectionAutoScroll(delta: -2, point: topPoint) == true)
        #expect(view.terminal.displayBuffer.yDisp == 0)
        #expect(delegate.sent.isEmpty == false)
        #expect(view.selection.end.row == 0)
        #expect(view.selection.end.col == 6)
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

    @Test func testAlternateSelectionAutoScrollMergeKeepsContinuousText() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))

        let down = view.mergedAlternateSelectionAutoScrollText(
            existing: "line 1\nline 2\nline 3",
            current: "line 2\nline 3\nline 4",
            direction: .down)
        #expect(down == "line 1\nline 2\nline 3\nline 4")

        let up = view.mergedAlternateSelectionAutoScrollText(
            existing: "line 2\nline 3\nline 4",
            current: "line 1\nline 2\nline 3",
            direction: .up)
        #expect(up == "line 1\nline 2\nline 3\nline 4")

        let partialCharacterOverlap = view.mergedAlternateSelectionAutoScrollText(
            existing: "abc",
            current: "cde",
            direction: .down)
        #expect(partialCharacterOverlap == "abc\ncde")

        let singleFullLineOverlap = view.mergedAlternateSelectionAutoScrollText(
            existing: "a\nx",
            current: "x\ny",
            direction: .down)
        #expect(singleFullLineOverlap == "a\nx\ny")
    }

    @Test func testAlternateSelectionAutoScrollCopyUsesAccumulatedTextAfterFeed() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: "\u{1B}[Hline 1\r\nline 2\r\nline 3")
        #expect(view.terminal.isDisplayBufferAlternate == true)

        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 2))
        view.isSelectionDragInProgress = true
        let edgeInset = max(view.cellDimension.height * 1.5, 24)
        let bottomPoint = CGPoint(x: view.cellDimension.width * 6, y: edgeInset - 1)
        view.updateSelectionAutoScroll(at: bottomPoint)
        #expect(view.performSelectionAutoScroll(delta: 1, point: bottomPoint) == true)
        #expect(view.selection.end.row == view.terminal.displayBuffer.rows - 1)
        #expect(view.selection.end.col == 6)
        view.feed(text: "\u{1B}[Hline 2\u{1B}[K\r\nline 3\u{1B}[K\r\nline 4\u{1B}[K")

        #expect(view.selection.end.row == view.terminal.displayBuffer.rows - 1)
        #expect(view.selection.end.col == 6)
        #expect(view.selectedTextForCopy() == "line 1\nline 2\nline 3\nline 4")

        view.isSelectionDragInProgress = false
        view.feed(text: "\u{1B}[Hline 3\u{1B}[K\r\nline 4\u{1B}[K\r\nline 5\u{1B}[K")

        #expect(view.selectedTextForCopy() == "line 1\nline 2\nline 3\nline 4")
    }

    @Test func testAlternateSelectionAutoScrollCapturesOnePendingFeedAfterDragEnds() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: "\u{1B}[Hline 1\r\nline 2\r\nline 3")

        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 2))
        view.isSelectionDragInProgress = true
        let bottomPoint = CGPoint(x: view.cellDimension.width * 6, y: 0)
        #expect(view.performSelectionAutoScroll(delta: 1, point: bottomPoint) == true)

        view.isSelectionDragInProgress = false
        view.feed(text: "\u{1B}[Hline 2\u{1B}[K\r\nline 3\u{1B}[K\r\nline 4\u{1B}[K")

        #expect(view.selectedTextForCopy() == "line 1\nline 2\nline 3\nline 4")

        view.feed(text: "\u{1B}[Hline 3\u{1B}[K\r\nline 4\u{1B}[K\r\nline 5\u{1B}[K")
        #expect(view.selectedTextForCopy() == "line 1\nline 2\nline 3\nline 4")
    }

    @Test func testAlternateSelectionAutoScrollCacheClearsForSelectAll() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 800, height: 240)))
        view.feed(text: "\u{1B}[?1049h")
        view.feed(text: "\u{1B}[Hline 1\r\nline 2\r\nline 3")

        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 1))
        view.captureAlternateSelectionAutoScrollText(direction: .down)
        #expect(view.selectedTextForCopy() == "line 1\nline 2")

        view.selectAll(nil)

        #expect(view.selectedTextForCopy() == view.selection.getSelectedText())
        #expect(view.selectedTextForCopy() != "line 1\nline 2")
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
