//
//  CircularList.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/25/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

enum ArgumentError : Error {
    case invalidArgument(String)
}

class CircularList<T> {
    private var array: [T?]
    private var startIndex: Int
    var count: Int {
        get {
            return _count
        }
        set {
            precondition(newValue <= maxLength)

            if newValue > array.count {
                let start = array.count
                for _ in start..<newValue {
                    array.append (nil)
                }
            }
            _count = newValue
        }
    }

    private var _count: Int
    var maxLength: Int {
        didSet {
            if maxLength != oldValue {
                let empty : T? = nil
                var newArray = Array(repeating: empty, count:Int(maxLength))
                let top = min (maxLength, array.count)
                for i in 0..<top {
                    newArray [i] = array [getCyclicIndex(i)]
                }
                startIndex = 0
                array = newArray
                return
            }
        }
    }

    ///
    /// This method is called to fill a slot that might be empty on demand, gets a -1 for a row that
    /// does not exist, or the index requested otherwise
    //
    var makeEmpty: ((_ idx: Int) -> T)? = nil

    public init (maxLength: Int)
    {
        array = Array.init(repeating: nil, count: Int(maxLength))
        self.maxLength = maxLength
        self._count = 0
        self.startIndex = 0
    }

    private func getCyclicIndex(_ index: Int) -> Int {
        return Int(startIndex + index) % (array.count)
    }

    func debugGetCyclicIndex(_ index: Int) -> Int {
        getCyclicIndex(index)
    }

    subscript (index: Int) -> T {
        get {
            let idx = getCyclicIndex(index)
            if let p = array [idx] {
                return p
            } else {
                // print ("Making empty for \(index) on type \(String (describing: self))")
                let new = makeEmpty! (idx)
                array [idx] = new
                return new
            }
        }
        set (newValue){
            array [getCyclicIndex(index)] = newValue
      }
    }

    func push (_ value: T)
    {
        array [getCyclicIndex(count)] = value
        if count == array.count {
            startIndex = startIndex + 1
            if startIndex == array.count {
                startIndex = 0
            }
        } else {
            count = count + 1
        }
    }

    func recycle ()
    {
        if count != maxLength {
            print ("can only recycle when the buffer is full")
            abort ()
        }
        let index = getCyclicIndex(count)
        startIndex += 1
        startIndex = startIndex % maxLength
        array [index] = makeEmpty! (-1)
    }

    @discardableResult
    func pop () -> T {
        let v = array [getCyclicIndex(count-1)]!
        count = count - 1
        return v
    }

    func splice (start: Int, deleteCount: Int, items: [T], change: (Int) -> Void)
    {
        if deleteCount > 0 {
            var i = start
            let limit = count-deleteCount
            while i < limit {
                array [getCyclicIndex(i)] = array [getCyclicIndex(i+deleteCount)]
                change(i)
                i += 1
            }
            count = count - deleteCount
        }
        // add items
        var i = count-1
        let ic = items.count
        while i >= start {
#if DEBUG
            // print("Moving line \(i) to \(i + ic): \(array[getCyclicIndex(i)].debugDescription)")
#endif
            array [getCyclicIndex(i + ic)] = array [getCyclicIndex(i)]
            change(i + ic)
            i -= 1
        }
        for i in 0..<ic {
            change(start + i)
            array [getCyclicIndex(start + i)] = items [i]
        }

        // Adjust length as needed
        if Int(count) + ic > array.count {
            let countToTrim = count + items.count - array.count
            startIndex = startIndex + countToTrim
            count = array.count
        } else {
            count = count + items.count
        }
     }

    func trimStart (count: Int)
    {
        let c = count > self.count ? self.count : count
        startIndex = startIndex + c
        self.count -= count
    }

    func shiftElements (start: Int, count: Int, offset: Int) -> Bool
    {
        func dumpState (_ msg: String) -> Bool {
            print ("Assertion at start=\(start) count=\(count) offset=\(offset): \(msg)")
            return false
        }

        if count < 0 {
            return dumpState ("count < 0")
        }
        if start < 0 {
            return dumpState ("start < 0")
        }
        if start >= self.count {
            return dumpState ("start >= self.count")
        }
        if start+offset <= 0 {
            return dumpState ("start+offset <= 0")
        }
//        precondition (count > 0)
//        precondition (start >= 0)
//        precondition (start < self.count)
//        precondition (start+offset > 0)
        if offset > 0 {
            for i in (0..<count).reversed() {
                self [start + i + offset] = self [start + i]
            }
            let expandListBy = start + count + offset - self.count
            if expandListBy > 0 {
                self._count += expandListBy
                while self._count > maxLength {
                    self._count -= 1
                    startIndex += 1
                    // trimmed callback invoke
                }
            }
        } else {
            for i in 0..<count {
                self [start + i + offset] = self [start + i]
            }
        }
        return true
    }

    var isFull: Bool {
        get {
            return count == maxLength
        }
    }
}

internal class CircularBufferLineList {
    private var array: [BufferLine?]
    private var startIndex: Int
    var count: Int {
        get {
            return _count
        }
        set {
            precondition(newValue <= maxLength)

            if newValue > array.count {
                let start = array.count
                for _ in start..<newValue {
                    array.append (nil)
                }
            }
            _count = newValue
        }
    }

    public var isEmpty: Bool { count == 0 }
    public func getArray() -> [BufferLine?] {
        array
    }

    public func getStartIndex() -> Int {
        startIndex
    }

    private var _count: Int
    var maxLength: Int {
        didSet {
            if maxLength != oldValue {
                let empty : BufferLine? = nil
                var newArray = Array(repeating: empty, count:Int(maxLength))
                let top = min (maxLength, array.count)
                for i in 0..<top {
                    newArray [i] = array [getCyclicIndex(i)]
                }
                startIndex = 0
                array = newArray
                return
            }
        }
    }

    ///
    /// This method is called to fill a slot that might be empty on demand, gets a -1 for a row that
    /// does not exist, or the index requested otherwise
    //
    var makeEmpty: ((_ idx: Int) -> BufferLine)? = nil

    /// Called when a line is about to be recycled, with true if the line had images
    var onLineRecycled: ((_ hadImages: Bool) -> Void)? = nil

    /// Called when a line is pushed, with true if the line has images
    var onLinePushed: ((_ hasImages: Bool) -> Void)? = nil

    public init (maxLength: Int)
    {
        array = Array.init(repeating: nil, count: Int(maxLength))
        self.maxLength = maxLength
        self._count = 0
        self.startIndex = 0
    }

    /// The private version exists to allow the Swift optimizer to avoid calls to
    /// `swift_beginAccess`
    private func getCyclicIndex(_ index: Int) -> Int {
        return Int(startIndex &+ index) % (array.count)
    }

    /// Public version of the same method
    func debugGetCyclicIndex(_ index: Int) -> Int {
        return getCyclicIndex(index)
    }

    subscript (index: Int) -> BufferLine {
        _read {
            let idx = getCyclicIndex(index)
            if array[idx] == nil {
                array[idx] = makeEmpty!(idx)
            }
            yield array[idx]!
        }
        set (newValue){
            array [getCyclicIndex(index)] = newValue
      }
    }

    func push (_ value: BufferLine)
    {
        array [getCyclicIndex(count)] = value
        if count == array.count {
            startIndex = startIndex + 1
            if startIndex == array.count {
                startIndex = 0
            }
        } else {
            count = count + 1
        }
        onLinePushed?(value.images != nil)
    }

    /// Relay patch（捕获式回看 / 反向插入）：在逻辑索引 0 处 O(1) 插入一行历史，
    /// 即把一行**更早**的内容接到回看缓冲的最顶端，其余逻辑行整体下移一位
    /// （实现为 startIndex 自减一格、环形回绕，写入新腾出的头部槽位）。用于
    /// Claude Code / codex 这类就地重绘 TUI 的「捕获式滚动」：每收割到一行被卷出
    /// 屏幕上方的历史，就 prepend 到回看缓冲顶端。
    ///
    /// 与 push() 相反：push 在尾部追加、满了从**头部**淘汰最旧行；prepend 在头部
    /// 追加且**绝不淘汰**——缓冲已满（count == maxLength）时返回 false，由调用方
    /// 据此停止收割。这样已落盘的历史行严格不可变，是「高亮 == 复制」不变式的地基。
    ///
    /// ⚠️ 副作用：成功后**所有逻辑索引整体 +1**。调用方必须同步把指向旧内容的
    /// yBase / yDisp / 选区行号一并 +1，否则它们会指向错位的行。
    @discardableResult
    func prependScrollback (_ value: BufferLine) -> Bool
    {
        // 满了就拒绝：绝不覆盖尾部历史行（push 式的头部淘汰在反向插入里是错的）。
        guard _count < array.count else { return false }
        let newStart = (startIndex - 1 + array.count) % array.count
        array [newStart] = value
        startIndex = newStart
        _count += 1
        onLinePushed?(value.images != nil)
        return true
    }

    func recycle (clearAttribute: Attribute)
    {
        if count != maxLength {
            print ("can only recycle when the buffer is full")
            abort ()
        }
        let index = getCyclicIndex(count)
        startIndex += 1
        startIndex = startIndex % maxLength
        let hadImages = array[index]?.images != nil
        array[index]?.clear(with: clearAttribute)
        onLineRecycled?(hadImages)
        //array [index] = makeEmpty! (-1)
    }

    @discardableResult
    func pop () -> BufferLine {
        let v = array [getCyclicIndex(count-1)]!
        count = count - 1
        return v
    }

    func splice (start: Int, deleteCount: Int, items: [BufferLine], change: (Int) -> Void)
    {
        if deleteCount > 0 {
            var i = start
            let limit = count-deleteCount
            while i < limit {
                array [getCyclicIndex(i)] = array [getCyclicIndex(i+deleteCount)]
                change(i)
                i += 1
            }
            count = count - deleteCount
        }
        // add items
        var i = count-1
        let ic = items.count
        while i >= start {
#if DEBUG
            // print("Moving line \(i) to \(i + ic): \(array[getCyclicIndex(i)].debugDescription)")
#endif
            array [getCyclicIndex(i + ic)] = array [getCyclicIndex(i)]
            change(i + ic)
            i -= 1
        }
        for i in 0..<ic {
            change(start + i)
            array [getCyclicIndex(start + i)] = items [i]
        }

        // Adjust length as needed
        if Int(count) + ic > array.count {
            let countToTrim = count + items.count - array.count
            startIndex = startIndex + countToTrim
            count = array.count
        } else {
            count = count + items.count
        }
     }

    func trimStart (count: Int)
    {
        let c = count > self.count ? self.count : count
        startIndex = startIndex + c
        self.count -= count
    }

    func shiftElements (start: Int, count: Int, offset: Int) -> Bool
    {
        func dumpState (_ msg: String) -> Bool {
            print ("Assertion at start=\(start) count=\(count) offset=\(offset): \(msg)")
            return false
        }

        if count < 0 {
            return dumpState ("count < 0")
        }
        if start < 0 {
            return dumpState ("start < 0")
        }
        if start >= self.count {
            return dumpState ("start >= self.count")
        }
        if start+offset <= 0 {
            return dumpState ("start+offset <= 0")
        }
        if offset > 0 {
            for i in (0..<count).reversed() {
                array[getCyclicIndex(start + i + offset)] = array[getCyclicIndex(start + i)]
            }
            let expandListBy = start + count + offset - self.count
            if expandListBy > 0 {
                self._count += expandListBy
                while self._count > maxLength {
                    self._count -= 1
                    startIndex += 1
                    // trimmed callback invoke
                }
            }
        } else {
            for i in 0..<count {
                array[getCyclicIndex(start + i + offset)] = array[getCyclicIndex(start + i)]
            }
        }
        return true
    }

    var isFull: Bool {
        get {
            return count == maxLength
        }
    }
}
