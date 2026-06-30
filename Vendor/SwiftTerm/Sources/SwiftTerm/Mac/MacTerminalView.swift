//
//  MacTerminalView.swift
//
// This is the AppKit version of the TerminalView and holds the state
// variables in the `TerminalView` class, but as much of the terminal
// implementation details live in the Apple/AppleTerminalView which
// contains the shared AppKit/UIKit code
//
//  Created by Miguel de Icaza on 3/4/20.
//
#if os(macOS)
import Foundation
import AppKit
import CoreText
import CoreGraphics
import Carbon.HIToolbox
#if canImport(MetalKit)
import MetalKit
#endif

/**
 * TerminalView provides an AppKit front-end to the `Terminal` termininal emulator.
 * It is up to a subclass to either wire the terminal emulator to a remote terminal
 * via some socket, to an application that wants to run with terminal emulation, or
 * wiring this up to a pseudo-terminal.
 *
 * Users are notified of interesting events in their implementation of the `TerminalViewDelegate`
 * methods - an instance must be provided to the constructor of `TerminalView`.
 *
 * Developers might want to surface UIs for `optionAsMetaKey` and `allowMouseReporting` in
 * their application.  They both default to true, but this means that Option-Letter is hijacked for
 * terminal purposes to send the sequence ESC-Letter, instead of the macOS specific character and
 * means that when mouse-aware applications are running, they hijack the normal selection process.
 *
 * Call the `getTerminal` method to get a reference to the underlying `Terminal` that backs this
 * view.
 *
 * Use the `configureNativeColors()` to set the defaults colors for the view to match the OS
 * defaults, otherwise, this uses its own set of defaults colors.
 */
open class TerminalView: NSView, NSTextInputClient, NSUserInterfaceValidations, TerminalDelegate {
#if canImport(MetalKit)
    // Default to throttling Metal redraws during live-resize; set SWIFTTERM_METAL_LIVE_RESIZE_THROTTLE=0 to disable.
    private static let metalLiveResizeThrottleEnabled: Bool = {
        let value = ProcessInfo.processInfo.environment["SWIFTTERM_METAL_LIVE_RESIZE_THROTTLE"]
        if value == "0" || value == "false" || value == "FALSE" {
            return false
        }
        return true
    }()
#endif
    private static let regularArrowKeyCodes: Set<UInt16> = [
        UInt16(kVK_LeftArrow),
        UInt16(kVK_RightArrow),
        UInt16(kVK_DownArrow),
        UInt16(kVK_UpArrow)
    ]

    struct FontSet {
        public let normal: NSFont
        let bold: NSFont
        let italic: NSFont
        let boldItalic: NSFont
        
        static var defaultFont: NSFont {
            if #available(macOS 10.15, *)  {
                return NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            } else {
                return NSFont(name: "Menlo Regular", size: NSFont.systemFontSize) ?? NSFont(name: "Courier", size: NSFont.systemFontSize)!
            }
        }
        
        public init(font baseFont: NSFont, fontSize: CGFloat? = nil) {
            self.normal = baseFont
            self.bold = NSFontManager.shared.convert(baseFont, toHaveTrait: [.boldFontMask])
            self.italic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask])
            self.boldItalic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask, .boldFontMask])
        }

        // Expected by the shared rendering code
        func underlinePosition () -> CGFloat
        {
            return normal.underlinePosition
        }

        // Expected by the shared rendering code
        func underlineThickness () -> CGFloat
        {
            return normal.underlineThickness
        }
    }
    
    /**
     * The delegate that the TerminalView uses to interact with its hosting
     */
    public weak var terminalDelegate: TerminalViewDelegate?

    /// If true, the caret view will show different shapes depending on the focus
    /// otherwise, it will behave like it is focused
    public var caretViewTracksFocus: Bool {
        get {
            return caretView.tracksFocus
        }
        set {
            caretView.tracksFocus = newValue
        }
    }

    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    private var findBar: TerminalFindBarView?
    private var findBarTerm: String = ""
    private var findBarOptions: SearchOptions = SearchOptions()
    var debug: TerminalDebugView?
    var pendingDisplay: Bool = false
#if canImport(MetalKit)
    var metalView: MTKView?
    var metalRenderer: MetalTerminalRenderer?
    /// Experimental GPU path: CoreText glyph atlas + Metal quads.
    /// Limitations: image caching is basic; GPU path is still evolving.
    private var useMetalRenderer = false
    var metalDirtyRange: ClosedRange<Int>?
    var pendingMetalDisplay: Bool = false
    /// Controls how the Metal renderer builds GPU buffers each frame.
    ///
    /// The default is ``MetalBufferingMode/perRowPersistent``, which caches
    /// per-row vertex data and only rebuilds dirty rows. Switch to
    /// ``MetalBufferingMode/perFrameAggregated`` for workloads that repaint
    /// most of the screen every frame.
    ///
    /// You can change this property at any time; the renderer picks up the
    /// new mode on the next frame.
    public var metalBufferingMode: MetalBufferingMode = .perRowPersistent

    /// Whether the terminal view is currently using the Metal GPU renderer.
    ///
    /// Returns `true` after a successful call to ``setUseMetal(_:)`` with
    /// `true`, and `false` otherwise.
    public var isUsingMetalRenderer: Bool {
        return useMetalRenderer
    }
#endif

    var cellDimension: CellDimension!
    var caretView: CaretView!
    public var terminal: Terminal!
    private var progressBarView: TerminalProgressBarView?
    private var progressReportTimer: Timer?
    private var lastProgressValue: UInt8?

    var selection: SelectionService!
    private var scroller: NSScroller!
    
    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary
    // of attributes for an NSAttributedString
    var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    
    
    // Cache for the colors in the 0..255 range
    var colors: [NSColor?] = Array(repeating: nil, count: 256)
    var trueColors: [Attribute.Color:NSColor] = [:]
    var transparent = TTColor.transparent ()
    var isBigSur = true
    
    /// This flag is automatically set to true after the initializer is called, if running on a system older than BigSur.
    /// Starting with BigSur any screen updates will invoke the draw() method with the whole region, regardless
    /// of how much changed.   Setting this to true, will disable this OS behavior, setting it to false, will keep
    /// the original BigSur behavior to redraw the whole region.
    ///
    /// For more details on this see:
    /// https://gist.github.com/lukaskubanek/9a61ac71dc0db8bb04db2028f2635779
    /// https://developer.apple.com/forums/thread/663256?answerId=646653022#646653022
    public var disableFullRedrawOnAnyChanges = false
    var fontSet: FontSet

    /// The font to use to render the terminal
    public var font: NSFont {
        get {
            return fontSet.normal
        }
        set {
            fontSet = FontSet (font: newValue)
            resetFont()
            selectNone()
        }
    }
    
    public init(frame: CGRect, font: NSFont?) {
        self.fontSet = FontSet (font: font ?? FontSet.defaultFont)

        super.init (frame: frame)
        setup()
    }
    
    public override init (frame: CGRect)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        super.init (frame: frame)
        setup()
    }
    
    public required init? (coder: NSCoder)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        super.init (coder: coder)
        setup()
    }
    
    private func setup()
    {
        wantsLayer = true
        isBigSur = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0))
        if isBigSur {
            disableFullRedrawOnAnyChanges = true
        }
        if #available(macOS 14, *) {
            self.clipsToBounds = true
        }
        setupScroller()
        setupOptions()
        setupProgressBar()
        setupFocusNotification()
    }

#if canImport(MetalKit)
    /// Enables or disables GPU-accelerated rendering via Metal.
    ///
    /// When enabled, the terminal view replaces its CoreGraphics rendering
    /// path with a Metal-based renderer that rasterizes glyphs into a
    /// texture atlas and draws cells as GPU quads. This can significantly
    /// reduce CPU usage for large or rapidly-updating terminals.
    ///
    /// Metal rendering is **disabled by default**. Call this method after
    /// the view has been added to a window:
    ///
    /// ```swift
    /// try terminalView.setUseMetal(true)
    /// ```
    ///
    /// You can switch back to CoreGraphics at any time by passing `false`.
    ///
    /// - Parameter enabled: Pass `true` to activate Metal rendering, or
    ///   `false` to revert to CoreGraphics.
    /// - Throws: ``MetalError`` if the Metal device or pipeline cannot be
    ///   initialized (for example, on hardware without Metal support).
    public func setUseMetal(_ enabled: Bool) throws {
        if enabled == useMetalRenderer {
            return
        }
        if enabled {
            try updateMetalRenderer(enabled: true)
            useMetalRenderer = true
        } else {
            try updateMetalRenderer(enabled: false)
            useMetalRenderer = false
        }
    }

    private func updateMetalRenderer(enabled: Bool) throws {
        if enabled {
            if metalView != nil {
                return
            }
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw MetalError.deviceUnavailable
            }
            let mtkView = MTKView(frame: bounds, device: device)
            mtkView.autoresizingMask = [.width, .height]
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
            mtkView.framebufferOnly = true
            mtkView.colorPixelFormat = .bgra8Unorm
            // Relay patch: materialize the backing CAMetalLayer immediately —
            // without this, `mtkView.layer` stays nil until AppKit lazily
            // backs the view, and the isOpaque override below silently no-ops.
            mtkView.wantsLayer = true
            let renderer = try MetalTerminalRenderer(view: mtkView, terminalView: self)
            mtkView.delegate = renderer
            if let caretView = caretView {
                addSubview(mtkView, positioned: .below, relativeTo: caretView)
                caretView.disableAnimations()
                caretView.isHidden = true
            } else {
                addSubview(mtkView, positioned: .below, relativeTo: nil)
            }
            // Relay patch: honor alpha in nativeBackgroundColor — an opaque
            // CAMetalLayer ignores destination alpha and composites against
            // black, defeating per-window translucency/blur. Must run AFTER
            // addSubview: before the view enters a layer-backed hierarchy the
            // backing layer may not exist yet and `layer?` is a silent no-op.
            mtkView.layer?.isOpaque = false
            metalView = mtkView
            metalRenderer = renderer
            needsDisplay = false
            mtkView.setNeedsDisplay(mtkView.bounds)
        } else {
            metalView?.removeFromSuperview()
            metalView = nil
            metalRenderer = nil
            if let caretView = caretView {
                caretView.isHidden = false
                caretView.updateCursorStyle()
            }
            needsDisplay = true
        }
    }
#endif
    
    func startDisplayUpdates ()
    {
        // Not used on Mac
    }
    
    func suspendDisplayUpdates()
    {
        // Not used on Mac
    }
    
    var becomeMainObserver, resignMainObserver: NSObjectProtocol?
    
    deinit {
        if let becomeMainObserver {
            NotificationCenter.default.removeObserver (becomeMainObserver)
        }
        if let resignMainObserver {
            NotificationCenter.default.removeObserver (resignMainObserver)
        }
        progressReportTimer?.invalidate()
        selectionAutoScrollTimer?.invalidate()
    }
    
    func setupFocusNotification() {
        becomeMainObserver = NotificationCenter.default.addObserver(forName: .init("NSWindowDidBecomeMainNotification"), object: nil, queue: nil) { [unowned self] notification in
            self.caretView.updateCursorStyle()
        }
        resignMainObserver = NotificationCenter.default.addObserver(forName: .init("NSWindowDidResignMainNotification"), object: nil, queue: nil) { [unowned self] notification in
            self.caretView.disableAnimations()
            self.caretView.updateView()
        }
    }

    private func setupProgressBar() {
        let bar = TerminalProgressBarView(frame: .zero)
        bar.isHidden = true
        if let scroller {
            addSubview(bar, positioned: .above, relativeTo: scroller)
        } else {
            addSubview(bar)
        }
        progressBarView = bar
        updateProgressBarFrame()
    }

    private func updateProgressBarFrame() {
        guard let progressBarView else { return }
        let height: CGFloat = 2
        progressBarView.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    }

    private func resolveProgress(for report: Terminal.ProgressReport) -> UInt8? {
        switch report.state {
        case .remove:
            return nil
        case .set:
            return report.progress ?? 0
        case .error:
            return report.progress ?? lastProgressValue
        case .indeterminate:
            return nil
        case .pause:
            return report.progress ?? lastProgressValue ?? 100
        }
    }

    private func resetProgressReportTimer() {
        progressReportTimer?.invalidate()
        progressReportTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            self?.clearProgressReport()
        }
    }

    private func clearProgressReport() {
        progressReportTimer?.invalidate()
        progressReportTimer = nil
        lastProgressValue = nil
        progressBarView?.apply(state: .remove, progress: nil)
    }

    private func handleProgressReport(_ report: Terminal.ProgressReport) {
        if report.state == .remove {
            clearProgressReport()
            return
        }

        let resolvedProgress = resolveProgress(for: report)
        if let resolvedProgress {
            lastProgressValue = resolvedProgress
        }
        progressBarView?.apply(state: report.state, progress: resolvedProgress)
        resetProgressReportTimer()
    }
    
    func setupOptions ()
    {
        setupOptions (width: getEffectiveWidth (size: bounds.size), height: bounds.height)
        layer?.backgroundColor = nativeBackgroundColor.cgColor
    }

    /// This controls whether the backspace should send ^? or ^H, the default is ^?
    public var backspaceSendsControlH: Bool = false
    
    var _nativeFg, _nativeBg: TTColor!
    var settingFg = false, settingBg = false
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeForegroundColor: NSColor {
        get { _nativeFg }
        set {
            if settingFg { return }
            settingFg = true
            _nativeFg = newValue
            terminal.foregroundColor = nativeForegroundColor.getTerminalColor ()
            settingFg = false
        }
    }

    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeBackgroundColor: NSColor {
        get { _nativeBg }
        set {
            if settingBg { return }
            settingBg = true
            _nativeBg = newValue
            terminal.backgroundColor = nativeBackgroundColor.getTerminalColor ()
            // Relay patch: keep the backing layer in sync. setupOptions() seeds
            // layer.backgroundColor from the init-time default (opaque black);
            // without this, later theme/alpha changes never reach the layer and
            // a transparent terminal background composites over solid black.
            layer?.backgroundColor = newValue.cgColor
            settingBg = false
        }
    }
    
    /// Controls weather to use high ansi colors, if false terminal will use bold text instead of high ansi colors
    public var useBrightColors: Bool = true

    /// When true, block element (U+2580-U+259F) and box drawing (U+2500-U+257F) characters use custom rendering.
    public var customBlockGlyphs: Bool = true {
        didSet {
            terminal.updateFullScreen()
            queuePendingDisplay()
        }
    }

    /// When true, custom block/box glyphs use anti-aliasing instead of pixel-aligned edges.
    public var antiAliasCustomBlockGlyphs: Bool = false {
        didSet {
            terminal.updateFullScreen()
            queuePendingDisplay()
        }
    }
    
    /// Controls the color for the caret
    public var caretColor: NSColor {
        get { caretView.caretColor }
        set { caretView.caretColor = newValue }
    }

    /// Controls the color for the text in the caret when using a block cursor, if not set
    /// the cursor will render with the foreground color
    public var caretTextColor: NSColor? {
        get { caretView.caretTextColor }
        set { caretView.caretTextColor = newValue }
    }

    var _selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor
    /// The color used to render the selection
    public var selectedTextBackgroundColor: NSColor {
        get {
            return _selectedTextBackgroundColor
        }
        set {
            _selectedTextBackgroundColor = newValue
        }
    }

    func backingScaleFactor () -> CGFloat
    {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }
    
    @objc
    func scrollerActivated ()
    {
        flashScroller()
        switch scroller.hitPart {
        case .decrementPage:
            pageUp()
            scroller.doubleValue =  scrollPosition
        case .incrementPage:
            pageDown()
            scroller.doubleValue =  scrollPosition
        case .knob:
            scroll(toPosition: scroller.doubleValue)
        case .knobSlot:
            print ("Scroller .knobSlot clicked")
        case .noPart:
            print ("Scroller .noPart clicked")
        case .decrementLine:
            print ("Scroller .decrementLine clicked")
        case .incrementLine:
            print ("Scroller .incrementLine clicked")
        default:
            print ("Scroller: New value introduced")
        }
    }

    // Relay patch: overlay style — thin floating knob over the content
    // (no reserved gutter, no permanent track), Safari/system-scroller feel.
    let scrollerStyle: NSScroller.Style = .overlay

    func getScrollerFrame() -> CGRect {
        return NSRect(x: bounds.maxX - scrollerWidth, y: 0, width: scrollerWidth, height: bounds.height)
    }

    func setupScroller()
    {
        if scroller == nil {
            scroller = NSScroller(frame: .zero)
            scroller.translatesAutoresizingMaskIntoConstraints = false
            addSubview(scroller)

            // Use Auto Layout to position the scroller. This ensures correct layout
            // whether the parent view uses frame-based or constraint-based layout.
            NSLayoutConstraint.activate([
                scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
                scroller.topAnchor.constraint(equalTo: topAnchor),
                scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
                scroller.widthAnchor.constraint(equalToConstant: scrollerWidth)
            ])
        }
        scroller.scrollerStyle = scrollerStyle
        // Relay patch: smallest knob metrics + auto-hide. Hidden until the
        // user actually scrolls (flashScroller), then fades back out — an
        // alpha-0 NSView still hit-tests, so visibility uses isHidden too.
        scroller.controlSize = .small
        scroller.alphaValue = 0
        scroller.isHidden = true
        scroller.knobProportion = 0.1
        scroller.isEnabled = false
        if let progressBarView {
            addSubview(progressBarView, positioned: .above, relativeTo: scroller)
        }
        scroller.action = #selector(scrollerActivated)
        scroller.target = self
    }

    func updateScrollerFrame() {
        // Scroller position is managed by Auto Layout constraints
    }

    /// This method sents the `nativeForegroundColor` and `nativeBackgroundColor`
    /// to match macOS default colors for text and its background.
    public func configureNativeColors ()
    {
        self.nativeForegroundColor = NSColor.textColor
        self.nativeBackgroundColor = NSColor.textBackgroundColor
    }
    
    open func bufferActivated(source: Terminal) {
        // Relay patch（捕获式滚动）：换屏后旧 alt 缓冲的 banked 几何已被终端自身清理(activateNormalBuffer→clear)，
        // 这里只复位收割状态机，不再去动（可能已是另一个）缓冲，避免对错误缓冲做折叠。
        if harvestState != .idle {
            harvestState = .idle
            harvestAwaitingRepaint = false
            clearHarvestWatchdog()
            harvestBankedCount = 0
            harvestRows = 0
            harvestPrevScratch = []
        }
        updateScroller ()
    }
    
    open func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalDelegate?.send (source: self, data: data)
    }
        
    private var scrollerWidth: CGFloat {
        // Relay patch: small overlay metrics — the thinnest system scroller.
        NSScroller.scrollerWidth(for: .small, scrollerStyle: scrollerStyle)
    }

    /// Relay patch: overlay scrollers float above the content, so no column
    /// width is reserved for them (legacy style needs a gutter).
    private var reservedScrollerWidth: CGFloat {
        scrollerStyle == .overlay ? 0 : scrollerWidth
    }

    /**
     * Given the current set of columns and rows returns a frame that would host this control.
     */
    open func getOptimalFrameSize () -> NSRect
    {
        return NSRect (x: 0, y: 0, width: cellDimension.width * CGFloat(terminal.cols) + reservedScrollerWidth, height: cellDimension.height * CGFloat(terminal.rows))
    }

    func getEffectiveWidth (size: CGSize) -> CGFloat
    {
        return (size.width - reservedScrollerWidth)
    }
    
    open func scrolled(source terminal: Terminal, yDisp: Int) {
        // Relay patch: this fires once per scrolled LINE while output streams;
        // three NSScroller property sets plus a delegate round-trip per line
        // dominate CPU on large outputs. Defer both to the throttled display
        // pass (updateDisplay), which already runs at most once per frame.
        scrollerRefreshPending = true
        queuePendingDisplay()
    }
    
    open func linefeed(source: Terminal) {
        // Relay patch: 普通拖拽现在默认本地划选，含运行中的 Claude Code/Codex 等
        // 全屏 TUI（见 mouseReportingRequested）。备用屏幕里输出会持续刷新换行，
        // 若每个换行都 selectNone()，用户刚从流式 agent 输出里划下的选区会被瞬间
        // 抹掉，等于选不了。故备用屏幕保留选区（键入时 keyDown 已会清选区，不冲突）；
        // 主屏幕维持原行为：换行入滚动历史时清选区，避免选区坐标随内容上滚而错位——
        // 但拖拽划选进行中（isSelectionDragInProgress）也保留，以支持「下拖自动滚动选中」。
        if allowMouseReporting && !terminal.isCurrentBufferAlternate && !isSelectionDragInProgress {
            selection.selectNone()
        }
    }
    
    /// This vaiable controls whether mouse events are sent to the application running under the
    /// terminal if it has requested the data.   This poses a problem for selection, so users
    /// need a way of toggling this behavior.
    public var allowMouseReporting: Bool = true

    /// Controls how link tracking resolves hovered links:
    /// `.explicit` = OSC 8 only, `.implicit` = explicit + implicit fallback, `.none` = off.
    public var linkReporting: LinkReporting = .implicit

    /// Controls link highlighting and link activation behavior.
    public var linkHighlightMode: LinkHighlightMode = .hoverWithModifier {
        didSet {
            linkHighlightRange = nil
            updateLinkHighlightTracking()
            terminal.updateFullScreen()
            queuePendingDisplay()
        }
    }

    var linkHighlightRange: [Terminal.LinkMatch.RowRange]?

    /**
     * If set to true, this will call the TerminalViewDelegate's rangeChanged method
     * when there are changes that are being performed on the UI
     */
    public var notifyUpdateChanges = false

    func updateDebugDisplay()
    {
        debug?.update()
    }
    
    func updateScroller () {
        scroller.isEnabled = canScroll
        scroller.doubleValue = scrollPosition
        scroller.knobProportion = scrollThumbsize
    }

    // Relay patch: auto-hide scroller — appears on user scrolling, fades out
    // after a short idle. isHidden tracks alpha so the invisible scroller
    // never swallows clicks along the right edge.
    private var scrollerHideTimer: Timer?

    func flashScroller () {
        guard canScroll else { return }
        scrollerHideTimer?.invalidate()
        scroller.isHidden = false
        scroller.alphaValue = 1
        scrollerHideTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.scroller.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.scroller.alphaValue == 0 else { return }
                self.scroller.isHidden = true
            })
        }
    }

    var userScrolling = false

    // Relay patch: set by scrolled(source:yDisp:); flushed by updateDisplay.
    var scrollerRefreshPending = false

    override open func viewWillDraw() {
        
        // Starting with BigSur, it looks like even sending one pixel to be redrawn will trigger
        // a call to draw() for the whole surface
        if disableFullRedrawOnAnyChanges {
            let layer = self.layer
            layer?.contentsFormat = .RGBA8Uint
        }
    }
    #if false
    override open func setNeedsDisplay(_ invalidRect: NSRect) {
        print ("setNeeds: \(invalidRect)")
        super.setNeedsDisplay(invalidRect)
    }
    #endif
    
    func getCurrentGraphicsContext () -> CGContext?
    {
        NSGraphicsContext.current?.cgContext
    }
    
    override public func draw (_ dirtyRect: NSRect) {
#if canImport(MetalKit)
        if metalView != nil {
            return
        }
#endif
        guard let currentContext = getCurrentGraphicsContext() else {
            return
        }
        drawTerminalContents (dirtyRect: dirtyRect, context: currentContext, bufferOffset: terminal.displayBuffer.yDisp)
    }
    
    public override func cursorUpdate(with event: NSEvent)
    {
        NSCursor.iBeam.set ()
    }
    
    func makeFirstResponder ()
    {
        window?.makeFirstResponder (self)
    }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateScrollerFrame()
        updateProgressBarFrame()
        guard cellDimension != nil else { return }
        // Relay patch（捕获式滚动）：resize 会重排缓冲、破坏收割几何 → 先在旧几何上优雅复位再 resize。
        if harvestState != .idle { abortHarvest() }
        _ = processSizeChange(newSize: frame.size)
#if canImport(MetalKit)
        if useMetalRenderer {
            if inLiveResize && TerminalView.metalLiveResizeThrottleEnabled {
                queueMetalDisplay()
            } else {
                requestMetalDisplay()
            }
        } else {
            needsDisplay = true
        }
#else
        needsDisplay = true
#endif
        updateCursorPosition()
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateScroller()
        selection.active = false
        updateProgressBarFrame()
    }
    
    private var _hasFocus = false
    open var hasFocus : Bool {
        get {
            //print ("hasFocus: \(_hasFocus) window=\(window?.isKeyWindow)")
            return _hasFocus && (window?.isKeyWindow ?? true)
        }
        set {
            _hasFocus = newValue
            caretView.focused = newValue
        }
    }

    //
    // NSTextInputClient protocol implementation
    //
    public override func becomeFirstResponder() -> Bool {
        let response = super.becomeFirstResponder()
        if response {
            hasFocus = true
            caretView.updateCursorStyle()
            terminal.setTerminalFocus(true)
        }
        return response
    }
    
    public override func resignFirstResponder() -> Bool {
        let response = super.resignFirstResponder()
        if response {
            caretView.disableAnimations()
            hasFocus = false
            terminal.setTerminalFocus(false)
        }
        return response
    }
    
    public override var acceptsFirstResponder: Bool {
        get {
            return true
        }
    }
    
    // Tracking object, maintained by `startTracking` and `deregisterTrackingInterest`
    var tracking: NSTrackingArea? = nil
    
    // Turns on AppKit mouse event tracking - used both by the url highlighter and the mouse move,
    // when the client application has set MouseMove.anyEvent
    //
    // Can be invoked multiple times, use the "deregisterTrackingInterest" method to turn it off
    // which will take into account both the url highlighter state (which is bound to the command
    // key being pressed) and the client requirements
    func startTracking ()
    {
        if tracking == nil {
            tracking = NSTrackingArea (rect: frame, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: [:])
            addTrackingArea(tracking!)
        }
    }
    
    func shouldTrackMouse () -> Bool
    {
        if terminal.mouseMode == .anyEvent {
            return true
        }
        if commandActive {
            return true
        }
        if linkHighlightMode == .hover {
            return true
        }
        if linkHighlightMode == .hoverWithModifier && commandActive {
            return true
        }
        return false
    }

    // Can be invoked by both the keyboard handler monitoring the command key, and the
    // mouse tracking system, only when both are off, this is turned off.
    func deregisterTrackingInterest ()
    {
        if !shouldTrackMouse() {
            if tracking != nil {
                removeTrackingArea(tracking!)
                tracking = nil
            }
        }
    }

    func updateLinkHighlightTracking ()
    {
        if shouldTrackMouse() {
            startTracking()
        } else {
            deregisterTrackingInterest()
        }
    }
    
    func turnOffUrlPreview ()
    {
        if commandActive {
            deregisterTrackingInterest()
            removePreviewUrl()
            commandActive = false
            lastReportedLink = nil
            updatePathPointerCursor(active: false)   // ⌘ 松开：手型光标复位 I-beam
            if linkHighlightMode == .hoverWithModifier {
                let oldRange = linkHighlightRange
                linkHighlightRange = nil
                invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
                queuePendingDisplay()
            }
            if linkHighlightMode == .alwaysWithModifier {
                terminal.updateFullScreen()
                queuePendingDisplay()
            }
        }
    }
    
    // If true, the Command key has been pressed
    var commandActive = false
    
    // We monitor the flags changed to enable URL previews on mouse-hover like iTerm
    // when the Command key is pressed.
    
    public override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.command){
            commandActive = true
            startTracking()

            if let hit = currentMouseHit() {
                if let payload = payloadString(at: hit) {
                    previewUrl(payload: payload)
                }
                reportLink(at: hit)
                updateHoverLink(at: hit)
            } else if let payload = getPayload(for: event) as? String {
                previewUrl (payload: payload)
            }
            if linkHighlightMode == .alwaysWithModifier {
                terminal.updateFullScreen()
                queuePendingDisplay()
            }
        } else {
            turnOffUrlPreview ()
        }
        if terminal.keyboardEnhancementFlags.contains(.reportAllKeys),
           !kittyIsComposing,
           let modifierKey = kittyModifierKey(from: event.keyCode),
           let modifierFlag = modifierFlag(for: modifierKey) {
            let isDown = event.modifierFlags.contains(modifierFlag)
            let eventType: KittyKeyboardEventType = isDown ? .press : .release
            if eventType == .release && !terminal.keyboardEnhancementFlags.contains(.reportEvents) {
                super.flagsChanged(with: event)
                return
            }
            let modifiers = kittyModifiers(from: event, includeOption: true)
            let kittyEvent = KittyKeyEvent(key: .functional(modifierKey),
                                           modifiers: modifiers,
                                           eventType: eventType,
                                           text: nil,
                                           shiftedKey: nil,
                                           baseLayoutKey: nil,
                                           composing: kittyIsComposing)
            _ = sendKittyEvent(kittyEvent)
        }
        super.flagsChanged(with: event)
    }
    
    public override func mouseExited(with event: NSEvent) {
        turnOffUrlPreview()
        if linkHighlightMode == .hover || linkHighlightMode == .hoverWithModifier {
            let oldRange = linkHighlightRange
            linkHighlightRange = nil
            invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
            queuePendingDisplay()
        }
        super.mouseExited(with: event)
    }
    
    /// If set to true, the terminal treats the "Option" key as the Meta key in old terminals,
    /// which has the effect of sending the ESC character before the character that was
    /// entered.  Applications use this to provide bindings for Alt-keys, or in Emacs terms
    /// the Meta key (M-x stands for Meta-x, or pressing the option key and x).
    ///
    /// If this is set to `false`, then the key is passed to the OS, which produces the
    /// OS specific feature.
    public var optionAsMetaKey: Bool = true

    private struct PendingKittyKeyEvent {
        let event: NSEvent
        let eventType: KittyKeyboardEventType
    }

    private var pendingKittyKeyEvent: PendingKittyKeyEvent?
    private var kittyIsComposing = false
    
    //
    // We capture a handful of keydown events and pre-process those, and then let
    // interpretKeyEvents do the rest of the work, that includes text-insertion, and
    // keybinding mapping.
    //
    // That is why we do not handle things like the return key here, instead those are
    // handled by doCommand below.
    //
    // This currently handles the function keys here, but probably should be done in
    // doCommand/noop: - but more research needs to take place to figure out the priority
    // of those keys.
    //
    public override func keyDown(with event: NSEvent) {
        // Relay patch（捕获式滚动）：primed 期间打字 = 明确的新交互 → 先回挂 live（折叠收割几何 + 清选区），
        // 否则键入触发的 CC 输出落到 off-screen scratch、用户看不到（视口还停在 banked 历史）。
        // 这也是用户「滚到底想保留选区」后返回实时画面的自然手势（打字即清选区，符合预期）。
        if harvestState == .primed { reattachToLive() }
        selection.active = false
        let eventFlags = event.modifierFlags

        if !terminal.keyboardEnhancementFlags.isEmpty {
            pendingKittyKeyEvent = nil
            if eventFlags.contains([.option, .command]), event.charactersIgnoringModifiers == "o" {
                optionAsMetaKey.toggle()
                return
            }

            let wantsEvents = terminal.keyboardEnhancementFlags.contains(.reportEvents)
            let wantsAllKeys = terminal.keyboardEnhancementFlags.contains(.reportAllKeys)
            let repeatEventType: KittyKeyboardEventType = (event.isARepeat && wantsEvents) ? .repeatPress : .press
            let textEventType: KittyKeyboardEventType = (event.isARepeat && wantsEvents && wantsAllKeys) ? .repeatPress : .press
            if let functionKey = kittyFunctionalKey(from: event) {
                let kittyEvent = KittyKeyEvent(key: .functional(functionKey),
                                               modifiers: kittyModifiers(from: event, includeOption: optionAsMetaKey),
                                               eventType: repeatEventType,
                                               text: kittyTextForFunctionalKey(functionKey, event: event),
                                               shiftedKey: nil,
                                               baseLayoutKey: nil,
                                               composing: kittyIsComposing)
                if sendKittyEvent(kittyEvent) {
                    return
                }
            }

            if eventFlags.contains(.control) || (optionAsMetaKey && eventFlags.contains(.option)) {
                if let kittyEvent = kittyTextEvent(from: event, eventType: repeatEventType),
                   sendKittyEvent(kittyEvent) {
                    return
                }
            }

            pendingKittyKeyEvent = PendingKittyKeyEvent(event: event, eventType: textEventType)
            interpretKeyEvents([event])
            return
        }
        
        // Handle Option-letter to send the ESC sequence plus the letter as expected by terminals
        if eventFlags.contains ([.option, .command]) {
            if event.charactersIgnoringModifiers == "o" {
                optionAsMetaKey.toggle()
            }
        } else if optionAsMetaKey && eventFlags.contains (.option) {
            if let rawCharacter = event.charactersIgnoringModifiers {
                if let fs = rawCharacter.unicodeScalars.first {
                    switch Int (fs.value) {
                    case NSLeftArrowFunctionKey:
                        send (EscapeSequences.emacsBack)
                        return
                    case NSRightArrowFunctionKey:
                        send (EscapeSequences.emacsForward)
                        return
                    default: break
                    }
                }
                send (EscapeSequences.cmdEsc)
                send (txt: rawCharacter)
            }
            return
        } else if eventFlags.contains (.control) {
            // Sends the control sequence
            if let ch = event.charactersIgnoringModifiers {
                if let fs = ch.unicodeScalars.first {
                    switch Int (fs.value) {
                    case NSLeftArrowFunctionKey:
                        send (EscapeSequences.controlLeft)
                        return
                    case NSRightArrowFunctionKey:
                        send (EscapeSequences.controlRight)
                        return
                    default:
                        break
                    }
                }
                send (applyControlToEventCharacters (ch))
                return
            }
        } else if eventFlags.contains (.function) {
            if let str = event.charactersIgnoringModifiers {
                if let fs = str.unicodeScalars.first {
                    let c = Int (fs.value)
                    switch c {
                    case NSF1FunctionKey:
                        send (EscapeSequences.cmdF [0])
                    case NSF2FunctionKey:
                        send (EscapeSequences.cmdF [1])
                    case NSF3FunctionKey:
                        send (EscapeSequences.cmdF [2])
                    case NSF4FunctionKey:
                        send (EscapeSequences.cmdF [3])
                    case NSF5FunctionKey:
                        send (EscapeSequences.cmdF [4])
                    case NSF6FunctionKey:
                        send (EscapeSequences.cmdF [5])
                    case NSF7FunctionKey:
                        send (EscapeSequences.cmdF [6])
                    case NSF8FunctionKey:
                        send (EscapeSequences.cmdF [7])
                    case NSF9FunctionKey:
                        send (EscapeSequences.cmdF [8])
                    case NSF10FunctionKey:
                        send (EscapeSequences.cmdF [9])
                    case NSF11FunctionKey:
                        send (EscapeSequences.cmdF [10])
                    case NSF12FunctionKey:
                        send (EscapeSequences.cmdF [11])
                    case NSDeleteFunctionKey:
                        send (EscapeSequences.cmdDelKey)
                        //                    case NSUpArrowFunctionKey:
                        //                        send (EscapeSequences.MoveUpNormal)
                        //                    case NSDownArrowFunctionKey:
                        //                        send (EscapeSequences.MoveDownNormal)
                        //                    case NSLeftArrowFunctionKey:
                        //                        send (EscapeSequences.MoveLeftNormal)
                        //                    case NSRightArrowFunctionKey:
                    //                        send (EscapeSequences.MoveRightNormal)
                    case NSPageUpFunctionKey:
                        pageUp ()
                    case NSPageDownFunctionKey:
                        pageDown()
                    default:
                        interpretKeyEvents([event])
                    }
                }
            }
            return
        }
        
        interpretKeyEvents([event])
    }

    public override func keyUp(with event: NSEvent) {
        let flags = terminal.keyboardEnhancementFlags
        if flags.contains(.reportEvents) {
            let hasAltOrCtrl = event.modifierFlags.contains(.control) || (optionAsMetaKey && event.modifierFlags.contains(.option))
            let shouldHandle = flags.contains(.reportAllKeys) || hasAltOrCtrl || kittyFunctionalKey(from: event) != nil
            if shouldHandle, let kittyEvent = kittyKeyEvent(from: event, eventType: .release, text: nil) {
                if !flags.contains(.reportAllKeys),
                   case .unicode(let codepoint) = kittyEvent.key,
                   codepoint == 9 || codepoint == 13 || codepoint == 127 {
                    // Enter/Tab/Backspace only report release events in report-all-keys mode.
                } else {
                    _ = sendKittyEvent(kittyEvent)
                }
            }
        }
        super.keyUp(with: event)
    }
    
    public override func doCommand(by selector: Selector) {
        if !terminal.keyboardEnhancementFlags.isEmpty {
            switch selector {
            case #selector(insertNewline(_:)):
                if sendKittyFunctionalKey(.enter) { return }
            case #selector(cancelOperation(_:)):
                if sendKittyFunctionalKey(.escape) { return }
            case #selector(deleteBackward(_:)):
                if sendKittyFunctionalKey(.backspace) { return }
            case #selector(moveUp(_:)):
                if sendKittyFunctionalKey(.up) { return }
            case #selector(moveDown(_:)):
                if sendKittyFunctionalKey(.down) { return }
            case #selector(moveLeft(_:)):
                if sendKittyFunctionalKey(.left) { return }
            case #selector(moveRight(_:)):
                if sendKittyFunctionalKey(.right) { return }
            case #selector(insertTab(_:)):
                if sendKittyFunctionalKey(.tab) { return }
            case #selector(insertBacktab(_:)):
                if sendKittyFunctionalKey(.tab, modifiers: [.shift]) { return }
            case #selector(moveToBeginningOfLine(_:)):
                if sendKittyFunctionalKey(.home) { return }
            case #selector(scrollToBeginningOfDocument(_:)):
                if sendKittyFunctionalKey(.home) { return }
            case #selector(moveToEndOfLine(_:)):
                if sendKittyFunctionalKey(.end) { return }
            case #selector(scrollToEndOfDocument(_:)):
                if sendKittyFunctionalKey(.end) { return }
            case #selector(scrollPageUp(_:)):
                fallthrough
            case #selector(pageUp(_:)):
                if terminal.applicationCursor {
                    if sendKittyFunctionalKey(.pageUp) { return }
                } else {
                    pageUp()
                    return
                }
            case #selector(scrollPageDown(_:)):
                fallthrough
            case #selector(pageDown(_:)):
                if terminal.applicationCursor {
                    if sendKittyFunctionalKey(.pageDown) { return }
                } else {
                    pageDown()
                    return
                }
            default:
                break
            }
        }
        switch selector {
        case #selector(insertNewline(_:)):
            send (EscapeSequences.cmdRet)
        case #selector(cancelOperation(_:)):
            send (EscapeSequences.cmdEsc)
        case #selector(deleteBackward(_:)):
            send ([backspaceSendsControlH ? 8 : 0x7f])
        case #selector(moveUp(_:)):
            sendKeyUp()
        case #selector(moveDown(_:)):
            sendKeyDown()
        case #selector(moveLeft(_:)):
            sendKeyLeft()
        case #selector(moveRight(_:)):
            sendKeyRight()
        case #selector(insertTab(_:)):
            send (EscapeSequences.cmdTab)
        case #selector(insertBacktab(_:)):
            send (EscapeSequences.cmdBackTab)
        case #selector(moveToBeginningOfLine(_:)):
            send (terminal.applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
        case #selector(scrollToBeginningOfDocument(_:)):
            send (terminal.applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
        case #selector(moveToEndOfLine(_:)):
            send (terminal.applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
        case #selector(scrollToEndOfDocument(_:)):
            send (terminal.applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
        case #selector(scrollPageUp(_:)):
            fallthrough
        case #selector(pageUp(_:)):
            if terminal.applicationCursor {
                send (EscapeSequences.cmdPageUp)
            } else {
                pageUp()
            }
        case #selector(scrollPageDown(_:)):
            fallthrough
        case #selector(pageDown(_:)):
            if terminal.applicationCursor {
                send (EscapeSequences.cmdPageDown)
            } else {
                pageDown()
            }
        case #selector(pageDownAndModifySelection(_:)):
            if terminal.applicationCursor {
                // TODO: view should scroll one page up.
            } else {
                send (EscapeSequences.cmdPageDown)
            }
        case #selector(moveToLeftEndOfLine(_:)):
            // Apple sends the Emacs back-word commands
            send (EscapeSequences.emacsBack)
        case #selector(moveToRightEndOfLine(_:)):
            send (EscapeSequences.emacsForward)
        default:
            print ("Unhandle selector \(selector)")
        }
    }
    
    // NSTextInputClient protocol implementation
    open func insertText(_ string: Any, replacementRange: NSRange) {
        insertText(string, replacementRange: replacementRange, isPaste: false)
    }
    
    func insertText(_ string: Any, replacementRange: NSRange, isPaste: Bool) {
        // Relay patch: IME commit replaces the composition — drop the overlay.
        if !imeMarkedText.isEmpty {
            imeMarkedText = ""
            imeUpdateOverlay()
        }
        if let str = string as? NSString {
            if !terminal.keyboardEnhancementFlags.isEmpty {
                if isPaste, terminal.bracketedPasteMode {
                    pendingKittyKeyEvent = nil
                    send(data: EscapeSequences.bracketedPasteStart[0...])
                    send (txt: str as String)
                    send(data: EscapeSequences.bracketedPasteEnd[0...])
                    return
                }
                let pendingEvent = pendingKittyKeyEvent
                pendingKittyKeyEvent = nil
                kittyIsComposing = false
                let text = str as String
                let kittyEvent: KittyKeyEvent
                if text.unicodeScalars.count == 1,
                   let pendingEvent,
                   let event = kittyTextEvent(from: pendingEvent.event, eventType: pendingEvent.eventType, text: text) {
                    kittyEvent = event
                } else {
                    kittyEvent = kittyTextEventFromText(text)
                }
                _ = sendKittyEvent(kittyEvent)
                return
            }
            if isPaste, terminal.bracketedPasteMode {
                send(data: EscapeSequences.bracketedPasteStart[0...])
            }
            send (txt: str as String)
            if isPaste, terminal.bracketedPasteMode {
                send(data: EscapeSequences.bracketedPasteEnd[0...])
            }
        }
        // TODO: I do not think we actually need this needsDisplay, the data fed should bubble this up
        // needsDisplay = true
    }
    
    // Relay patch: render the IME composition (preedit) text. Upstream only
    // popped the candidate window — the pinyin being typed never showed on
    // screen. An NSTextField overlay tracks the caret cell and shows the
    // underlined composition string until commit/cancel.
    var imeMarkedText = ""
    var imeSelectedRange = NSRange(location: 0, length: 0)
    private var imeOverlay: NSTextField?

    /// 终端光标格的像素原点（与 updateCursorPosition 同一套坐标推导）。
    /// 预编辑浮层必须锚在这里：caretView.frame 在组合期会被加上预编辑
    /// 偏移，拿它当锚点会逐键漂移。
    private func terminalCursorOrigin() -> CGPoint {
        let buffer = terminal.displayBuffer
        let vy = buffer.yBase + buffer.y
        guard vy >= 0, vy < buffer.lines.count else { return .zero }
        let doublePosition: CGFloat = buffer.lines[vy].renderMode == .single ? 1.0 : 2.0
        let offset = cellDimension.height * CGFloat(buffer.y - (buffer.yDisp - buffer.yBase) + 1)
        return CGPoint(x: cellDimension.width * doublePosition * CGFloat(buffer.x),
                       y: frame.height - offset)
    }

    /// 组合期插入点在预编辑文本内的横向偏移（selectedRange.location 处，
    /// 拼音输入法通常在末尾 —— 光标应跟在最后一个字母后面）。
    func imeCaretOffsetX() -> CGFloat {
        guard !imeMarkedText.isEmpty else { return 0 }
        let ns = imeMarkedText as NSString
        let loc = min(max(0, imeSelectedRange.location), ns.length)
        guard loc > 0 else { return 0 }
        return NSAttributedString(string: ns.substring(to: loc),
                                  attributes: [.font: font]).size().width
    }

    private func imeUpdateOverlay() {
        guard !imeMarkedText.isEmpty else {
            imeOverlay?.removeFromSuperview()
            imeOverlay = nil
            // Metal 路径的常规光标由渲染器绘制，caretView 保持隐藏；
            // CG 路径恢复 caretView。
            caretView?.isHidden = metalRenderer != nil
            updateCursorPosition()
            queuePendingDisplay()
            return
        }
        let field: NSTextField
        if let existing = imeOverlay {
            field = existing
        } else {
            let f = NSTextField(labelWithString: "")
            f.isBezeled = false
            f.isEditable = false
            f.drawsBackground = true
            addSubview(f)
            imeOverlay = f
            field = f
        }
        // 浮层底色必须不透明：半透明主题下 nativeBackgroundColor.alpha=0，
        // 直接用会让预编辑文字和底下的终端内容叠在一起糊成一团。
        field.backgroundColor = nativeBackgroundColor.withAlphaComponent(1)
        field.attributedStringValue = NSAttributedString(
            string: imeMarkedText,
            attributes: [
                .font: font,
                .foregroundColor: nativeForegroundColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        field.sizeToFit()
        field.setFrameOrigin(terminalCursorOrigin())
        // 组合期 caretView 改演插入点：跟在预编辑文本的 selectedRange 处
        //（updateCursorPosition 会按 imeCaretOffsetX 持续摆位），终端自身
        // 光标由渲染器在组合期一并隐藏。
        if let caret = caretView {
            caret.isHidden = false
        }
        updateCursorPosition()
        queuePendingDisplay()
    }

    // NSTextInputClient protocol implementation
    open func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        kittyIsComposing = true
        if let s = string as? String {
            imeMarkedText = s
        } else if let a = string as? NSAttributedString {
            imeMarkedText = a.string
        }
        imeSelectedRange = selectedRange
        imeUpdateOverlay()
    }

    private func kittyEncoder() -> KittyKeyboardEncoder {
        KittyKeyboardEncoder(flags: terminal.keyboardEnhancementFlags,
                             applicationCursor: terminal.applicationCursor,
                             backspaceSendsControlH: backspaceSendsControlH)
    }

    private func kittyModifiers(from event: NSEvent, includeOption: Bool) -> KittyKeyboardModifiers {
        var modifiers: KittyKeyboardModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.ctrl) }
        if includeOption, event.modifierFlags.contains(.option) { modifiers.insert(.alt) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.super) }
        if event.modifierFlags.contains(.capsLock) { modifiers.insert(.capsLock) }
        return modifiers
    }

    private func kittyFunctionalKey(from event: NSEvent) -> KittyFunctionalKey? {
        switch Int(event.keyCode) {
        case kVK_ANSI_Keypad0:
            return .keypad0
        case kVK_ANSI_Keypad1:
            return .keypad1
        case kVK_ANSI_Keypad2:
            return .keypad2
        case kVK_ANSI_Keypad3:
            return .keypad3
        case kVK_ANSI_Keypad4:
            return .keypad4
        case kVK_ANSI_Keypad5:
            return .keypad5
        case kVK_ANSI_Keypad6:
            return .keypad6
        case kVK_ANSI_Keypad7:
            return .keypad7
        case kVK_ANSI_Keypad8:
            return .keypad8
        case kVK_ANSI_Keypad9:
            return .keypad9
        case kVK_ANSI_KeypadDecimal:
            return .keypadDecimal
        case kVK_ANSI_KeypadDivide:
            return .keypadDivide
        case kVK_ANSI_KeypadMultiply:
            return .keypadMultiply
        case kVK_ANSI_KeypadMinus:
            return .keypadSubtract
        case kVK_ANSI_KeypadPlus:
            return .keypadAdd
        case kVK_ANSI_KeypadEnter:
            return .keypadEnter
        case kVK_ANSI_KeypadEquals:
            return .keypadEqual
        case kVK_ANSI_KeypadClear:
            return .keypadBegin
        default:
            break
        }
        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first else {
            return nil
        }
        if event.modifierFlags.contains(.numericPad),
           !Self.regularArrowKeyCodes.contains(event.keyCode) {
            switch Int(scalar.value) {
            case NSUpArrowFunctionKey:
                return .keypadUp
            case NSDownArrowFunctionKey:
                return .keypadDown
            case NSLeftArrowFunctionKey:
                return .keypadLeft
            case NSRightArrowFunctionKey:
                return .keypadRight
            case NSHomeFunctionKey:
                return .keypadHome
            case NSEndFunctionKey:
                return .keypadEnd
            case NSPageUpFunctionKey:
                return .keypadPageUp
            case NSPageDownFunctionKey:
                return .keypadPageDown
            case NSInsertFunctionKey:
                return .keypadInsert
            case NSDeleteFunctionKey:
                return .keypadDelete
            default:
                break
            }
        }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey:
            return .up
        case NSDownArrowFunctionKey:
            return .down
        case NSLeftArrowFunctionKey:
            return .left
        case NSRightArrowFunctionKey:
            return .right
        case NSHomeFunctionKey:
            return .home
        case NSEndFunctionKey:
            return .end
        case NSPageUpFunctionKey:
            return .pageUp
        case NSPageDownFunctionKey:
            return .pageDown
        case NSInsertFunctionKey:
            return .insert
        case NSDeleteFunctionKey:
            return .delete
        case NSPrintScreenFunctionKey:
            return .printScreen
        case NSScrollLockFunctionKey:
            return .scrollLock
        case NSPauseFunctionKey:
            return .pause
        case NSMenuFunctionKey:
            return .menu
        case NSF1FunctionKey:
            return .f1
        case NSF2FunctionKey:
            return .f2
        case NSF3FunctionKey:
            return .f3
        case NSF4FunctionKey:
            return .f4
        case NSF5FunctionKey:
            return .f5
        case NSF6FunctionKey:
            return .f6
        case NSF7FunctionKey:
            return .f7
        case NSF8FunctionKey:
            return .f8
        case NSF9FunctionKey:
            return .f9
        case NSF10FunctionKey:
            return .f10
        case NSF11FunctionKey:
            return .f11
        case NSF12FunctionKey:
            return .f12
        case NSF13FunctionKey:
            return .f13
        case NSF14FunctionKey:
            return .f14
        case NSF15FunctionKey:
            return .f15
        case NSF16FunctionKey:
            return .f16
        case NSF17FunctionKey:
            return .f17
        case NSF18FunctionKey:
            return .f18
        case NSF19FunctionKey:
            return .f19
        case NSF20FunctionKey:
            return .f20
        case NSF21FunctionKey:
            return .f21
        case NSF22FunctionKey:
            return .f22
        case NSF23FunctionKey:
            return .f23
        case NSF24FunctionKey:
            return .f24
        case NSF25FunctionKey:
            return .f25
        case NSF26FunctionKey:
            return .f26
        case NSF27FunctionKey:
            return .f27
        case NSF28FunctionKey:
            return .f28
        case NSF29FunctionKey:
            return .f29
        case NSF30FunctionKey:
            return .f30
        case NSF31FunctionKey:
            return .f31
        case NSF32FunctionKey:
            return .f32
        case NSF33FunctionKey:
            return .f33
        case NSF34FunctionKey:
            return .f34
        case NSF35FunctionKey:
            return .f35
        default:
            return nil
        }
    }

    private func kittyTextForFunctionalKey(_ key: KittyFunctionalKey, event: NSEvent) -> String? {
        switch key {
        case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
             .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
             .keypadDecimal, .keypadDivide, .keypadMultiply, .keypadSubtract,
             .keypadAdd, .keypadEqual, .keypadSeparator:
            let text = event.characters ?? event.charactersIgnoringModifiers
            return text?.isEmpty == false ? text : nil
        default:
            return nil
        }
    }

    private func kittyModifierKey(from keyCode: UInt16) -> KittyFunctionalKey? {
        switch keyCode {
        case 54:
            return .rightSuper
        case 55:
            return .leftSuper
        case 56:
            return .leftShift
        case 57:
            return .capsLock
        case 58:
            return .leftAlt
        case 59:
            return .leftControl
        case 60:
            return .rightShift
        case 61:
            return .rightAlt
        case 62:
            return .rightControl
        default:
            return nil
        }
    }

    private func modifierFlag(for key: KittyFunctionalKey) -> NSEvent.ModifierFlags? {
        switch key {
        case .leftShift, .rightShift:
            return .shift
        case .leftControl, .rightControl:
            return .control
        case .leftAlt, .rightAlt:
            return .option
        case .leftSuper, .rightSuper:
            return .command
        case .capsLock:
            return .capsLock
        default:
            return nil
        }
    }

    private static let kittyBaseLayoutKeyMap: [UInt16: UnicodeScalar] = {
        func scalar(_ char: Character) -> UnicodeScalar {
            char.unicodeScalars.first!
        }
        return [
            0: scalar("a"),
            1: scalar("s"),
            2: scalar("d"),
            3: scalar("f"),
            4: scalar("h"),
            5: scalar("g"),
            6: scalar("z"),
            7: scalar("x"),
            8: scalar("c"),
            9: scalar("v"),
            11: scalar("b"),
            12: scalar("q"),
            13: scalar("w"),
            14: scalar("e"),
            15: scalar("r"),
            16: scalar("y"),
            17: scalar("t"),
            18: scalar("1"),
            19: scalar("2"),
            20: scalar("3"),
            21: scalar("4"),
            22: scalar("6"),
            23: scalar("5"),
            24: scalar("="),
            25: scalar("9"),
            26: scalar("7"),
            27: scalar("-"),
            28: scalar("8"),
            29: scalar("0"),
            30: scalar("]"),
            31: scalar("o"),
            32: scalar("u"),
            33: scalar("["),
            34: scalar("i"),
            35: scalar("p"),
            37: scalar("l"),
            38: scalar("j"),
            39: scalar("'"),
            40: scalar("k"),
            41: scalar(";"),
            42: scalar("\\"),
            43: scalar(","),
            44: scalar("/"),
            45: scalar("n"),
            46: scalar("m"),
            47: scalar("."),
            49: scalar(" "),
            50: scalar("`")
        ]
    }()

    private func kittyBaseLayoutKey(from event: NSEvent) -> UnicodeScalar? {
        Self.kittyBaseLayoutKeyMap[event.keyCode]
    }

    private func kittyTextEvent(from event: NSEvent, eventType: KittyKeyboardEventType, text: String? = nil) -> KittyKeyEvent? {
        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first else {
            return nil
        }
        let baseScalar = String(scalar).lowercased().unicodeScalars.first ?? scalar
        let shiftedScalar = event.modifierFlags.contains(.shift) ? event.characters?.unicodeScalars.first : nil
        let baseLayout = kittyBaseLayoutKey(from: event)
        let baseLayoutKey = baseLayout == baseScalar ? nil : baseLayout
        let modifiers = kittyModifiers(from: event, includeOption: optionAsMetaKey)
        return KittyKeyEvent(key: .unicode(baseScalar.value),
                             modifiers: modifiers,
                             eventType: eventType,
                             text: text,
                             shiftedKey: shiftedScalar,
                             baseLayoutKey: baseLayoutKey,
                             composing: kittyIsComposing)
    }

    private func kittyKeyEvent(from event: NSEvent, eventType: KittyKeyboardEventType, text: String? = nil) -> KittyKeyEvent? {
        if let functionKey = kittyFunctionalKey(from: event) {
            let modifiers = kittyModifiers(from: event, includeOption: optionAsMetaKey)
            return KittyKeyEvent(key: .functional(functionKey),
                                 modifiers: modifiers,
                                 eventType: eventType,
                                 text: text,
                                 shiftedKey: nil,
                                 baseLayoutKey: nil,
                                 composing: kittyIsComposing)
        }
        return kittyTextEvent(from: event, eventType: eventType, text: text)
    }

    private func kittyTextEventFromText(_ text: String) -> KittyKeyEvent {
        return KittyKeyEvent(key: .none,
                             modifiers: [],
                             eventType: .press,
                             text: text,
                             shiftedKey: nil,
                             baseLayoutKey: nil,
                             composing: kittyIsComposing)
    }

    @discardableResult
    private func sendKittyEvent(_ event: KittyKeyEvent) -> Bool {
        guard let bytes = kittyEncoder().encode(event) else { return false }
        send(bytes)
        return true
    }

    @discardableResult
    private func sendKittyFunctionalKey(_ key: KittyFunctionalKey, modifiers: KittyKeyboardModifiers = [], eventType: KittyKeyboardEventType = .press) -> Bool {
        let event = KittyKeyEvent(key: .functional(key),
                                  modifiers: modifiers,
                                  eventType: eventType,
                                  text: nil,
                                  shiftedKey: nil,
                                  baseLayoutKey: nil,
                                  composing: kittyIsComposing)
        return sendKittyEvent(event)
    }
    
    // NSTextInputClient protocol implementation
    open func unmarkText() {
        kittyIsComposing = false
        imeMarkedText = ""
        imeUpdateOverlay()
    }
    
    // NSTextInputClient protocol implementation
    open func selectedRange() -> NSRange {
        guard let selection = self.selection, selection.active else {
            // This means "no selection":
            return NSRange.empty
        }
        
        let displayBuffer = terminal.displayBuffer
        var startLocation = (selection.start.row * displayBuffer.rows) + selection.start.col
        var endLocation = (selection.end.row * displayBuffer.rows) + selection.end.col
        if startLocation > endLocation {
            swap(&startLocation, &endLocation)
        }
        let length = endLocation - startLocation
        if length == 0 {
            return NSRange.empty
        }
        return NSRange(location: startLocation, length: endLocation - startLocation)
    }
    
    // NSTextInputClient protocol implementation
    open func markedRange() -> NSRange {
        imeMarkedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: imeMarkedText.utf16.count)
    }

    // NSTextInputClient protocol implementation
    open func hasMarkedText() -> Bool {
        !imeMarkedText.isEmpty
    }

    // NSTextInputClient protocol implementation
    open func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }
    
    // NSTextInputClient Protocol implementation
    open func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        // TODO print ("validAttributesForMarkedText: This should return the actual range from the selection")
        return []
    }
    
    // NSTextInputClient protocol implementation
    open func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        
        if let r = window?.convertToScreen(convert(caretView!.frame, to: nil)) {
            return r
        }
        
        return .zero
    }
    
    // NSTextInputClient protocol implementation
    open func characterIndex(for point: NSPoint) -> Int {
        print ("characterIndex:for point: This should return the actual range from the selection")
        return NSNotFound
    }
    
    open func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        //print ("Validating selector: \(item.action)")
        switch item.action {
        case #selector(performFindPanelAction(_:)):
            switch item.tag {
            case Int(NSFindPanelAction.showFindPanel.rawValue):
                return true
            case Int(NSFindPanelAction.next.rawValue):
                return true
            case Int(NSFindPanelAction.previous.rawValue):
                return true
            case Int(NSFindPanelAction.setFindString.rawValue):
                return selection.active
            default:
                return false
            }
        case #selector(performTextFinderAction(_:)):
            if let fa = NSTextFinder.Action (rawValue: item.tag) {
                switch fa {
                case .showFindInterface:
                    return true
                case .showReplaceInterface:
                    return true
                case .hideReplaceInterface:
                    return true
                case .hideFindInterface:
                    return true
                case .nextMatch:
                    return true
                case .previousMatch:
                    return true
                case .setSearchString:
                    return selection.active
                default:
                    return false
                }
            }
            return false
        case #selector(paste(_:)):
            return true
        case #selector(selectAll(_:)):
            return true
        case #selector(copy(_:)):
            return selection.active
        default:
            print ("Validating User Interface Item: \(item)")
            return false
        }
    }

    @objc open func performFindPanelAction(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else {
            return
        }
        switch menuItem.tag {
        case Int(NSFindPanelAction.showFindPanel.rawValue):
            showFindBar(prefillSelection: true)
        case Int(NSFindPanelAction.next.rawValue):
            performFind(next: true)
        case Int(NSFindPanelAction.previous.rawValue):
            performFind(next: false)
        case Int(NSFindPanelAction.setFindString.rawValue):
            setFindPasteboardFromSelection()
            showFindBar(prefillSelection: true)
        default:
            break
        }
    }

    open override func performTextFinderAction(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let action = NSTextFinder.Action(rawValue: menuItem.tag) else {
            return
        }

        switch action {
        case .nextMatch:
            performFind(next: true)
        case .previousMatch:
            performFind(next: false)
        case .setSearchString:
            setFindPasteboardFromSelection()
            showFindBar(prefillSelection: true)
        case .showFindInterface:
            showFindBar(prefillSelection: true)
        case .hideFindInterface:
            hideFindBar()
        default:
            break
        }
    }

    private func performFind(next: Bool) {
        let termFromBar = (findBar?.isHidden == false) ? findBar?.searchText : nil
        guard let term = termFromBar ?? findPasteboardString(), !term.isEmpty else {
            return
        }
        updateFindPasteboard(term)
        let options = findBar?.options ?? SearchOptions()
        if next {
            _ = findNext(term, options: options)
        } else {
            _ = findPrevious(term, options: options)
        }
    }

    private func setFindPasteboardFromSelection() {
        let selected = selectedTextForCopy()
        guard !selected.isEmpty else {
            return
        }
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(selected, forType: .string)
    }

    private func findPasteboardString() -> String? {
        let pasteboard = NSPasteboard(name: .find)
        return pasteboard.string(forType: .string)
    }

    private func updateFindPasteboard(_ term: String) {
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(term, forType: .string)
    }

    private func ensureFindBar() -> TerminalFindBarView {
        if let findBar {
            return findBar
        }
        let bar = TerminalFindBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        bar.onSearchChanged = { [weak self] term in
            self?.handleFindBarSearchChanged(term)
        }
        bar.onFindNext = { [weak self] in
            self?.performFind(next: true)
        }
        bar.onFindPrevious = { [weak self] in
            self?.performFind(next: false)
        }
        bar.onClose = { [weak self] in
            self?.hideFindBar()
        }
        bar.onOptionsChanged = { [weak self] options in
            self?.handleFindBarOptionsChanged(options)
        }

        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])
        findBar = bar
        return bar
    }

    private func showFindBar(prefillSelection: Bool) {
        let bar = ensureFindBar()
        bar.isHidden = false
        let selectedText = prefillSelection ? selectedTextForCopy() : nil
        let initial = (selectedText?.isEmpty == false) ? selectedText : findPasteboardString()
        if let initial {
            bar.searchText = initial
            handleFindBarSearchChanged(initial)
        }
        bar.focus()
    }

    private func hideFindBar() {
        findBar?.isHidden = true
        window?.makeFirstResponder(self)
    }

    private func handleFindBarSearchChanged(_ term: String) {
        findBarTerm = term
        if term.isEmpty {
            clearSearch()
            return
        }
        updateFindPasteboard(term)
        _ = findNext(term, options: findBarOptions)
    }

    private func handleFindBarOptionsChanged(_ options: SearchOptions) {
        findBarOptions = options
        if !findBarTerm.isEmpty {
            _ = findNext(findBarTerm, options: options)
        }
    }
    
    open func selectionChanged(source: Terminal) {
        #if canImport(MetalKit)
        if metalView != nil {
            let buffer = terminal.displayBuffer
            if buffer.lines.count == 0 {
                metalDirtyRange = nil
            } else {
                let startRow = buffer.yDisp
                let endRow = min(buffer.lines.count - 1, buffer.yDisp + buffer.rows - 1)
                if startRow <= endRow {
                    metalDirtyRange = startRow...endRow
                } else {
                    metalDirtyRange = nil
                }
            }
            queueMetalDisplay()
            return
        }
        #endif
        needsDisplay = true
    }
    
    func cut (sender: Any?) {}
    
    @objc
    open func paste(_ sender: Any)
    {
        let clipboard = NSPasteboard.general
        // Relay patch: 从 Finder 复制/拖拽的文件，剪贴板 .string 往往只是显示名
        // （如 "stodownload.MP4"），真实绝对路径在 file-url 类型里。优先读文件
        // URL，插入 shell 转义后的绝对路径（多文件以空格分隔），符合「在终端粘贴
        // 文件即得到可用路径」的预期（对齐 Terminal.app/iTerm2 行为）。
        if let urls = clipboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let joined = urls.map { Self.shellEscapePath($0.path) }.joined(separator: " ")
            insertText(joined, replacementRange: NSRange(location: 0, length: 0), isPaste: true)
            return
        }
        let text = clipboard.string(forType: .string)
        insertText(text ?? "", replacementRange: NSRange(location: 0, length: 0), isPaste: true)
    }

    /// Relay patch: shell 安全的路径表示——全是安全字符则原样输出（多数路径如此，
    /// 与手输一致）；含空格/元字符则用单引号包裹（内嵌单引号转义为 '\''），
    /// 任意字符都安全、回车即可用。public 供宿主拖放处理复用同一套转义。
    public static func shellEscapePath(_ path: String) -> String {
        if path.isEmpty { return "''" }
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./")
        if path.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    
    @objc
    open func copy(_ sender: Any)
    {
        // find the selected range of text in the buffer and put in the clipboard
        let str = selectedTextForCopy()
        
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(str, forType: .string)
    }

    open override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let copyItem = menu.addItem(withTitle: "拷贝", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = selection?.active == true

        let pasteItem = menu.addItem(withTitle: "粘贴", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self

        menu.addItem(.separator())

        let selectAllItem = menu.addItem(withTitle: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        return menu
    }
    
    public override func selectAll(_ sender: Any?)
    {
        selectAll ()
    }
    
    //func undo (sender: Any) {}
    //func redo (sender: Any) {}
    func zoomIn (sender: Any) {}
    func zoomOut (sender: Any) {}
    func zoomReset (sender: Any) {}
    
    // Returns the vt100 mouseflags
    func encodeMouseEvent (with event: NSEvent, overwriteRelease: Bool = false) -> Int
    {
        let flags = event.modifierFlags
        let isReleaseEvent = overwriteRelease || [NSEvent.EventType.leftMouseUp, .otherMouseUp, .rightMouseUp].contains(event.type)
        
        return terminal.encodeButton(button: event.buttonNumber, release: isReleaseEvent, shift: flags.contains(.shift), meta: flags.contains(.option), control: flags.contains(.control))
    }
    
    func calculateMouseHit (with event: NSEvent) -> (grid: Position, pixels: Position)
    {
        let point = convert(event.locationInWindow, from: nil)
        return calculateMouseHit(at: point)
    }

    func calculateMouseHit (at point: CGPoint) -> (grid: Position, pixels: Position)
    {
        func toInt (_ p: NSPoint) -> Position {

            let x = min (max (p.x, 0), bounds.width)
            let y = min (max (p.y, 0), bounds.height)
            return Position (col: Int (x), row: Int (bounds.height-y))
        }
        let displayBuffer = terminal.displayBuffer
        let col = Int (point.x / cellDimension.width)
        let row = Int ((frame.height-point.y) / cellDimension.height)
        let colValue = min (max (0, col), terminal.cols-1)
        let bufferRow = row + displayBuffer.yDisp
        let maxRow = max (0, displayBuffer.lines.count - 1)
        let rowValue = min (max (0, bufferRow), maxRow)
        return (Position(col: colValue, row: rowValue), toInt (point))
    }
    
    private func sharedMouseEvent (with event: NSEvent)
    {
        let displayBuffer = terminal.displayBuffer
        let hit = calculateMouseHit(with: event)
        let buttonFlags = encodeMouseEvent(with: event)
        let screenRow = max (0, min (displayBuffer.rows - 1, hit.grid.row - displayBuffer.yDisp))
        terminal.sendEvent(buttonFlags: buttonFlags, x: hit.grid.col, y: screenRow, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
    }
    
    private var autoScrollDelta = 0
    private var selectionAutoScrollTimer: Timer?
    private var selectionAutoScrollPoint: CGPoint = .zero
    /// Relay patch（平滑滚动）：精确滚动设备(触控板/妙控鼠标)的亚行像素累积器。每个滚轮
    /// event 把 |scrollingDeltaY| 累加进来，攒满一个 cellHeight 即产出整行步进，余数留存——
    /// 让触控板逐行连续滚动，而非被 calcScrollingVelocity 量化成 3 行一跳（用户反馈「向上
    /// 滚一次三行三行、不丝滑」的直接根因）。
    private var wheelPixelAccumY: CGFloat = 0
    /// 上次精确滚动的方向(±1)；方向反转时清空累积，避免上一方向余量把视口往回带一帧。
    private var wheelAccumSign: Int = 0
    /// 改动H（加速度）：上次精确滚动 event 的时间戳(秒)，算瞬时行速 rowsPerSec=Δrows/Δt 用。0=无上次。
    private var lastWheelTime: TimeInterval = 0
    // mouseDown 记录的选区锚点：保证拖拽划选从「真正按下的格子」开始，而非拖动第一帧的采样点。
    private var pendingSelectionAnchor: Position?

    // 拖拽划选进行中标志：为 true 时，流式输出（feedPrepare / linefeed）不得清掉选区，
    // 否则在 Claude Code/codex 等持续刷新的程序里，用户刚划下的选区会被下一帧抹掉，根本选不中。
    // mouseDragged 置 true，mouseDown / mouseUp 复位。非 private：feedPrepare 在
    // AppleTerminalView.swift 的同模块扩展里需读取它。
    var isSelectionDragInProgress = false

    // 选区自动滚动方向（本地 scrollback 滚动用）。
    enum AlternateSelectionAutoScrollDirection {
        case up
        case down
    }

    // 测试钩子：选区自动滚动 timer 是否处于武装状态。守护"驱动自动滚动的 timer 接线"。
    var selectionAutoScrollIsActive: Bool { selectionAutoScrollTimer != nil }

    func selectionAutoScrollVelocity (distanceFromEdge: CGFloat) -> Int
    {
        let cellHeight = max(cellDimension?.height ?? 1, 1)
        let cellDistance = max(1, Int(ceil(distanceFromEdge / cellHeight)))
        // 越往窗口外拖，滚得越快——长日志里靠近边缘是精修、拖远是快进，不会"像卡住"。
        switch cellDistance {
        case 0...1:
            return 1
        case 2...3:
            return 2
        case 4...6:
            return 4
        case 7...12:
            return 8
        default:
            return 16
        }
    }

    // 本地 scrollback 在给定方向上是否还有可滚的历史行（delta<0 上滚、delta>0 下滚）。
    private func canSelectionAutoScrollLocally (delta: Int) -> Bool
    {
        let displayBuffer = terminal.displayBuffer
        let maxScrollback = max(0, displayBuffer.lines.count - displayBuffer.rows)
        if delta < 0 {
            return displayBuffer.yDisp > 0
        }
        return displayBuffer.yDisp < maxScrollback
    }

    private func selectionAutoScrollDeltaIgnoringSelectionState (for point: CGPoint) -> Int
    {
        guard terminal.displayBuffer.rows > 0 else {
            return 0
        }
        let edgeInset = max((cellDimension?.height ?? 1) * 1.5, 24)
        let delta: Int
        if point.y < edgeInset {
            delta = selectionAutoScrollVelocity(distanceFromEdge: edgeInset - point.y)
        } else if point.y > bounds.height - edgeInset {
            delta = -selectionAutoScrollVelocity(distanceFromEdge: point.y - (bounds.height - edgeInset))
        } else {
            return 0
        }
        // 锁可见屏：备用屏（Claude Code/codex 就地重绘、无本地 scrollback）一旦本地历史在该方向
        // 滚尽，自动滚动归零——既不武装空转 timer、也不把滚轮转发给程序。selectionPosition 的
        // 钳制仍会把选区延伸到可见边缘行（拖到窗口外即选满可见内容），只是不再越过视口。
        // alt-scrollback 确有历史时（程序真发了换行）仍照常本地滚动连续选中。主屏行为不受影响。
        if terminal.isDisplayBufferAlternate && !canSelectionAutoScrollLocally(delta: delta) {
            return 0
        }
        return delta
    }

    func selectionAutoScrollDelta (for point: CGPoint) -> Int
    {
        guard selection?.active == true else {
            return 0
        }
        return selectionAutoScrollDeltaIgnoringSelectionState(for: point)
    }

    private func selectionPosition (for point: CGPoint) -> Position
    {
        let displayBuffer = terminal.displayBuffer
        let cellWidth = max(cellDimension.width, 1)
        let cellHeight = max(cellDimension.height, 1)
        let x = min(max(point.x, 0), max(bounds.width - 1, 0))
        let y = min(max(point.y, 0), max(bounds.height - 1, 0))
        let col = min(max(0, Int(x / cellWidth)), terminal.cols - 1)
        let screenRow = Int((bounds.height - y) / cellHeight)
        let clampedScreenRow = min(max(0, screenRow), max(0, displayBuffer.rows - 1))
        let maxRow = max(0, displayBuffer.lines.count - 1)
        let row = min(max(0, displayBuffer.yDisp + clampedScreenRow), maxRow)
        return Position(col: col, row: row)
    }

    private func selectionAutoScrollEdgePosition (delta: Int, point: CGPoint) -> Position
    {
        let displayBuffer = terminal.displayBuffer
        let cellWidth = max(cellDimension.width, 1)
        let x = min(max(point.x, 0), max(bounds.width - 1, 0))
        let col = min(max(0, Int(x / cellWidth)), terminal.cols - 1)
        let edgeScreenRow = delta < 0 ? 0 : max(0, displayBuffer.rows - 1)
        let maxRow = max(0, displayBuffer.lines.count - 1)
        let row = min(max(0, displayBuffer.yDisp + edgeScreenRow), maxRow)
        return Position(col: col, row: row)
    }

    private func selectionDragPosition (for point: CGPoint) -> Position
    {
        let delta = selectionAutoScrollDeltaIgnoringSelectionState(for: point)
        if delta != 0 {
            return selectionAutoScrollEdgePosition(delta: delta, point: point)
        }
        return selectionPosition(for: point)
    }

    private func extendSelectionToAutoScrollEdge (direction: AlternateSelectionAutoScrollDirection, point: CGPoint)
    {
        let delta = direction == .up ? -1 : 1
        selection.dragExtend(bufferPosition: selectionAutoScrollEdgePosition(delta: delta, point: point))
    }

    private func ensureSelectionAutoScrollTimer ()
    {
        guard selectionAutoScrollTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] timer in
            self?.scrollingTimerElapsed(source: timer)
        }
        selectionAutoScrollTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSelectionAutoScroll ()
    {
        autoScrollDelta = 0
        selectionAutoScrollTimer?.invalidate()
        selectionAutoScrollTimer = nil
    }

    func updateSelectionAutoScroll (at point: CGPoint)
    {
        selectionAutoScrollPoint = point
        autoScrollDelta = selectionAutoScrollDelta(for: point)
        if autoScrollDelta == 0 {
            stopSelectionAutoScroll()
        } else {
            ensureSelectionAutoScrollTimer()
        }
    }

    @discardableResult
    func performSelectionAutoScroll (delta: Int, point: CGPoint) -> Bool
    {
        guard selection.active, delta != 0 else {
            return false
        }

        // Relay patch（捕获式滚动）：备用屏(CC)拖选自动滚动的收割路由。向上拖到顶边时主动收割——
        // 转发滚轮让 CC 露出更早一行，drainHarvest 入库后 yDisp 保持 0、内容整体下移=向上滚视觉、
        // 选区延伸到新顶行。中部上下拖只在 banked 历史内浏览并延伸选区，clamp 到 [0,bankedCount]；
        // **拖动中绝不回挂 live、绝不清选区**（拖动是在选，不是导航）——回挂只属于刻意的滚轮到底手势。
        if harvestEligible {
            let b = terminal.displayBuffer
            if delta < 0, harvestState == .idle, b.yBase == 0, b.yDisp == 0 { _ = prime() }
            if harvestState == .primed {
                let goingUp = delta < 0
                if goingUp, b.yDisp <= 0 {
                    _ = harvestStepRequest()                         // 顶部：异步收割更早一行
                } else {
                    let target = goingUp ? max(0, b.yDisp + delta)   // delta<0：向更早 banked 行回滚
                                         : min(harvestBankedCount, b.yDisp + delta)  // 前滚 clamp 到底部
                    if target != b.yDisp { scrollTo(row: target) }
                }
                extendSelectionToAutoScrollEdge(direction: goingUp ? .up : .down, point: point)
                didSelectionDrag = true
                return true
            }
        }

        // 锁可见屏兜底（harvest 未启用/未 prime / 非备用屏时）：只读真实缓冲行，读到哪复制到哪，
        // 高亮逐字节 == 复制。备用屏无本地历史时 selectionAutoScrollDelta 已 gate 为 0、停在可见
        // 边缘 = 锁可见屏；主屏 scrollback / alt-scrollback 有历史时本地滚动连续选中。
        let direction: AlternateSelectionAutoScrollDirection = delta < 0 ? .up : .down
        let oldYDisp = terminal.displayBuffer.yDisp
        let oldEnd = selection.end
        if delta < 0 {
            scrollUp(lines: -delta)
        } else {
            scrollDown(lines: delta)
        }

        extendSelectionToAutoScrollEdge(direction: direction, point: point)
        didSelectionDrag = true
        return terminal.displayBuffer.yDisp != oldYDisp || selection.end != oldEnd
    }

    // Relay patch（单一数据源不变式 / 核心）：复制文本**只**来自 selection.getSelectedText()，
    // 与高亮渲染读的是同一个 displayBuffer.lines[row]（Metal/CoreGraphics 都按绝对行号取行）。
    // 因此「看到的高亮」逐字节等于「复制到的文本」。此前的 alternateSelectionAutoScrollText
    // 跨帧累积器是第二个独立数据源——在 Claude Code/codex 这类就地重绘的 TUI 里，高亮画在固定
    // 网格上、内容每帧被重绘，累积文本与高亮必然分叉（用户核心抱怨「看到的≠复制的」）。已整体删除。
    func selectedTextForCopy () -> String
    {
        return selection.getSelectedText()
    }

    /// Relay patch（捕获式滚动 / 核心检测算法，已用黄金轨迹离线验证）：比较转发滚轮
    /// 前后两帧的整屏文本网格，找出「整体下移一行」的最长连续区间——即 Claude Code /
    /// codex 收到滚轮后就地重绘出的转录文本带——并返回该区间正上方那一行，也就是本次
    /// 滚轮新「卷入」屏幕顶部的、更早的一行内容（供 prependScrollback 落盘）。
    ///
    /// 为什么不是「固定表头/表尾」检测：实测 CC 顶部并无恒定表头（更早内容直接出现在
    /// 第 0 行，或紧贴首条已置顶的对话行之下），底部状态栏每帧都在变（"✻ Churned"→
    /// "Jump to bottom"、输入行追加文字、进度条刷新）。唯一稳定的信号是转录带逐行下移
    /// 一格：cur[i] == prev[i-1]。取最长的这种连续区间 [lo, hi)，新行即 cur[lo-1]。
    ///
    /// 严格性即安全性：最长区间长度 < minBandRows 视为不可信（可能是部分重绘、换屏、
    /// 缩放或非滚动刷新），返回 nil → 调用方本帧**不入库、不动 buffer**，从而绝不产生
    /// 与高亮错位的历史行。纯函数、零副作用，可离线单测（见 scratchpad/golden_grids.json，
    /// 对 cc_scroll2 黄金轨迹可无缺口复原 164…180 + 首行 prompt）。
    static func detectRevealedTopLine (prev: [String], cur: [String], minBandRows: Int = 3) -> (line: String, revealedRow: Int)? {
        let rows = min(prev.count, cur.count)
        guard rows >= minBandRows + 1 else { return nil }
        var bestLo = -1
        var bestLen = 0
        var i = 1
        while i < rows {
            // 下移一行的连续区间起点：cur[i] 等于上一帧的 cur[i-1] 位置内容，且该行非空白
            //（空白行恒等会制造伪区间，必须排除——与 Python 参考实现的 .strip() 一致）。
            if cur[i] == prev[i - 1], !cur[i].trimmingCharacters(in: .whitespaces).isEmpty {
                let lo = i
                while i < rows, cur[i] == prev[i - 1] { i += 1 }
                let len = i - lo
                if len > bestLen { bestLen = len; bestLo = lo }
            } else {
                i += 1
            }
        }
        guard bestLen >= minBandRows, bestLo >= 1 else { return nil }
        return (cur[bestLo - 1], bestLo - 1)
    }

    /// 改动H(detectN)：把 detectRevealedTopLine 从「下移恰好 1 行」推广到「下移 N 行(N=1..maxShift)」。
    /// 实测 CC 在流水线快速续发时会把多个滚轮报告合并成一帧滚 N 行(探针:32% nil 中 64% 是 n2/n3/n4)，
    /// 单行版只认 N=1 故丢弃这些真滚动帧、还卡满看门狗。本函数对每个 N 扫最长「cur[i]==prev[i-N] 且
    /// 去空白非空」连续 band，在 band>=minBandRows 的候选里选「band 最长、并列取最小 N」(最保守，避免
    /// 重复边框/提示行在大 N 上凑长 band 误判)。返回 (topRow, count)：topRow=max(0,lo-N) 是最旧卷入行号，
    /// count=min(N,lo) 是本帧实际可回收行数(起点不足 N 时只回收可见部分，其余为固有物理缺口、非 bug)。
    static func detectRevealedBand (prev: [String], cur: [String], minBandRows: Int = 3, maxShift: Int = 4) -> (topRow: Int, count: Int)? {
        let rows = min(prev.count, cur.count)
        guard rows >= minBandRows + 1 else { return nil }
        var bestLen = 0, bestLo = -1, bestN = 0
        for n in 1...maxShift {
            guard rows >= n + minBandRows else { break }       // 该 N 下凑不出 minBandRows 长 band
            var i = n
            while i < rows {
                if cur[i] == prev[i - n], !cur[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let lo = i
                    while i < rows, cur[i] == prev[i - n] { i += 1 }
                    let len = i - lo
                    if len > bestLen { bestLen = len; bestLo = lo; bestN = n }   // n 递增、仅严格更长才替换→并列天然保留最小 N
                } else {
                    i += 1
                }
            }
        }
        guard bestLen >= minBandRows, bestLo >= 1, bestN >= 1 else { return nil }
        return (max(0, bestLo - bestN), min(bestN, bestLo))
    }

    // MARK: - Relay patch: 备用屏「捕获式滚动连续选中」(capture-on-scroll harvest)
    //
    // 问题：Claude Code（备用屏）就地全重绘、从不把行滚进 scrollback，屏外历史只在 CC 内存里。
    // 解法：用户向上拖选/滚轮到顶边时，主动转发滚轮让 CC 重绘上一屏 → band-diff 算出新卷入的顶行
    // → prependScrollback 入「真回看缓冲」→ 选区行号同步 +1。被选中的行从此都是 [0,yBase) 里
    // CC 永不写的冻结 BufferLine，故「高亮逐字节 == 复制」恒成立（捕获再不准也只 bank 错内容）。
    //
    // 不变式：harvest 进行中 yBase == lines.count - rows（scratch = CC 的活体屏 = 环尾 rows 行）。
    // 几何全在主队列变更（feed/渲染/事件同线程，已确认），无需加锁。
    // 杀手开关 RELAY_ALT_HARVEST=0 即时回退到锁可见屏的绿色地基；任何异常 → abortHarvest 优雅降级。

    enum HarvestState { case idle, primed }
    var harvestState: HarvestState = .idle
    var harvestAwaitingRepaint = false        // 至多一个在途的转发滚轮（等 drainHarvest 落库后再发下一个）
    var harvestBankedCount = 0                // 已 prepend 的行数（reattach 计数 + 判定 banked 底部）
    var harvestRows = 0                       // prime 时的 rows，resize 检测用
    var harvestPrevScratch: [String] = []     // 上一帧 scratch 网格（detectRevealedTopLine 的 prev）
    var harvestWatchdog: Timer?               // 自愈看门狗：CC 对转发滚轮不吐数据时 awaiting 会永卡 true，超时清掉
    var harvestEmptySteps = 0                 // 改动E：连续「转发上滚却收割不到任何历史」的次数(看门狗每次超时累计)
    static let harvestMaxEmptySteps = 3       // 改动E：≥3 避开 tick0 resync；达阈值且从未 bank+无选区→自愈回 live
    /// 改动G（平滑收割流水线）：本次手势待续发的收割步预算。收割顶边分支按 velocity 累加，
    /// drainHarvest 每成功落库一行就消费 1 并自动续发下一步——把「等下一个 momentum event 才推进
    /// 一行」换成「重绘落库即续推进」，让触控板像素累积(wheelVelocity)真正影响翻动速度(受 CC 重绘
    /// 往返速率封顶)。严格维持「至多一个在途上报」不变式：续发只在 drainHarvest 成功分支(awaiting
    /// 刚清空)发生。方向反转/abort/看门狗超时/prime 必清零，避免预算泄漏把视口带歪。
    var pendingHarvestSteps = 0

    /// awaiting 看门狗超时（秒）。CC 正常重绘走 feedFinish→drainHarvest 会即时清 awaiting 并 invalidate
    /// 本 timer；只有 CC【完全不吐数据】（到其历史顶端 / 忙 / 忽略滚轮）才会等到超时——此时清掉
    /// awaiting，使下一次手势能继续，绝不让滚轮永久卡死。给得足够宽（明显大于 CC 最坏单帧重绘耗时），
    /// 避免在 CC 繁忙时误触——误触会把一帧迟到的真重绘当作自发输出丢弃(丢行漂移)。
    static let harvestWatchdogTimeout: TimeInterval = 0.25   // 改动H(P1)：0.5→0.25。detectN 吸收掉合并帧后，残余 nil 多为 spinner/状态栏半帧，到顶/沉默应秒级自愈而非半秒冻结(肉眼最明确的「顿」)。取值仍明显大于 CC 最坏单帧重绘，避免繁忙误判把迟到真帧当自发输出丢弃。

    // Relay patch：默认【开启】alt-screen 收割（用户 2026-06-30 拍板要「真·跨屏连续选中」、知情接受
    // 卡顿风险）。收割靠「prime 冻结屏 → 注入 1 个滚轮 → diff 落库 → yBase++」逐行往返地把 CC/codex
    // 滚出顶部的行搬进 Relay scrollback，让选区/高亮/复制同读 [0,yBase) 冻结缓冲 → 跨屏 highlight==copy
    // 逐字节可信。代价（已知、用户接受）：这条逐行借的链路抢在 scrollWheel 直接转发路径(下方
    // isDisplayBufferAlternate 转发分支)前面，把程序原本流畅的自滚换成 Relay 主导的一行一行卡顿——
    // CC、codex 实测都卡(两者同样开鼠标上报、同样命中 eligible)。设 RELAY_ALT_HARVEST=0 即可显式关闭、
    // 回退到「滚轮直接转发 button4/5 给程序、程序自滚自历史」的流畅行为(iTerm2/Ghostty 同款)作 A/B 对照。
    // 「流畅且跨屏」的终极解需 detached-PTY（未做）。
    static let harvestEnabled = ProcessInfo.processInfo.environment["RELAY_ALT_HARVEST"] != "0"

    /// 收割是否对当前缓冲适用：开关开 + 允许鼠标上报 + 备用屏 + 程序在用鼠标上报。
    /// 收割靠注入「滚轮鼠标上报」让 CC 翻页，故必须鼠标上报在用。默认 harvestEnabled=true（RELAY_ALT_HARVEST=0 可关）。
    private var harvestEligible: Bool {
        Self.harvestEnabled && allowMouseReporting && terminal.isDisplayBufferAlternate && terminal.mouseMode != .off
    }

    /// 中央安全闸：harvest 期间几何不变式是否仍成立。任一不成立=发生了 resize/换屏/CC 自滚 → 应 abort。
    private var harvestInvariantHolds: Bool {
        guard harvestState == .primed else { return true }
        let b = terminal.buffer                         // 改动F：几何检查读 live buffer(CC 真正写入处)，不被同步窗口冻结快照干扰
        return terminal.isDisplayBufferAlternate
            && b.rows == harvestRows
            && b.yBase == b.lines.count - b.rows
            && b.yBase >= b.rows
    }

    private var harvestMidViewportPoint: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// 当前 scratch（CC 活体屏，绝对行 [yBase, yBase+rows)）的纯文本网格快照。
    private func harvestScratchSnapshot () -> [String] {
        let b = terminal.buffer                         // 改动F：读 CC 写入的 live scratch，绕开同步窗口快照→收割不再等窗口结束才入库
        let rows = b.rows
        var out: [String] = []
        out.reserveCapacity(rows)
        for y in 0..<rows {
            let idx = b.yBase + y
            if idx >= 0, idx < b.lines.count {
                out.append(b.lines[idx].translateToString(trimRight: true, skipNullCellsFollowingWide: true))
            } else {
                out.append("")
            }
        }
        return out
    }

    /// 进入收割态：把当前活体屏冻结为回看，并在其下深拷贝一份 scratch 供 CC 续画。
    /// 仅在 idle + 备用屏 + yBase==0 + 环有 2*rows 容量时成功。
    @discardableResult
    private func prime () -> Bool {
        guard harvestState == .idle, harvestEligible, !terminal.isSynchronizedOutputActive else { return false }  // 改动B(P0)：同步窗口内不启动收割
        let b = terminal.buffer                         // 改动F：在 live buffer 上建收割几何(prime 已确保非同步窗口，此刻 displayBuffer===buffer)
        let rows = b.rows
        guard rows > 0, b.yBase == 0, b.lines.count == rows, rows * 2 <= b.lines.maxLength else { return false }
        b.lines.count = rows * 2                       // 活跃区 rows → 2*rows：尾 rows 行成为 scratch
        for y in 0..<rows {                            // 冻结屏深拷贝进 scratch（CC 差分重绘需正确底图）
            b.lines[rows + y] = BufferLine(from: b.lines[y])
        }
        b.yBase = rows                                 // CC 写 [rows,2rows)；[0,rows) 冻结。yBase==count-rows
        terminal.setViewYDisp(0)                       // 视口仍显冻结屏(yDisp=0)；经 setViewYDisp 使 userScrolling=(0<yBase)=true，
                                                       // 锁住视口 → primed 期间 CC 向 scratch 的输出不会经 scroll() 把视口弹到 scratch
        harvestRows = rows
        harvestBankedCount = 0
        harvestEmptySteps = 0                           // 改动E：复位空步计数
        pendingHarvestSteps = 0                         // 改动G：新手势开始，清续发预算
        harvestAwaitingRepaint = false
        harvestPrevScratch = harvestScratchSnapshot()
        harvestState = .primed
        return true
    }

    /// 请求 CC 多露一行更早历史：转发一个上滚滚轮（至多一个在途，落库在随后的 drainHarvest）。
    /// 返回 true=本次确实发出了收割滚轮；false=在途/不可收割（调用方据此决定是否落到本地路径，避免冻结）。
    @discardableResult
    private func harvestStepRequest () -> Bool {
        guard harvestState == .primed, !harvestAwaitingRepaint, harvestEligible else { return false }
        guard harvestInvariantHolds else { abortHarvest(); return false }
        harvestPrevScratch = harvestScratchSnapshot()
        harvestAwaitingRepaint = true
        scheduleHarvestWatchdog()
        sendAlternateMouseWheel(up: true, lines: 1, at: harvestMidViewportPoint, modifierFlags: [])
        return true
    }

    /// 安排/重置 awaiting 看门狗。加到 .common 模式：滚动追踪/拖动期间主 runloop 切到
    /// eventTracking 模式，default 模式 timer 不触发——.common 覆盖二者，保证一定能自愈。
    private func scheduleHarvestWatchdog () {
        harvestWatchdog?.invalidate()
        let t = Timer(timeInterval: Self.harvestWatchdogTimeout, repeats: false) { [weak self] _ in
            self?.harvestWatchdogFired()
        }
        RunLoop.main.add(t, forMode: .common)
        harvestWatchdog = t
    }

    private func clearHarvestWatchdog () {
        harvestWatchdog?.invalidate()
        harvestWatchdog = nil
    }

    /// 看门狗触发=超时后 awaiting 仍为 true，说明 CC 对上次转发滚轮【完全没吐数据】（到顶/忙/忽略）。
    /// 清掉 awaiting 让后续手势能继续；scratch 既然没变，prevScratch 重同步为当前即可（幂等、防错位）。
    /// 绝不在这里动几何或选区——只解开「在途」这把锁，是整个状态机唯一的自愈出口。
    private func harvestWatchdogFired () {
        harvestWatchdog = nil
        guard harvestState == .primed, harvestAwaitingRepaint else { return }
        // CC 对转发滚轮超时未吐数据：只解开「在途」这把锁，让后续手势能继续。
        // 【不】重同步 harvestPrevScratch——保留 pre-step 基线；下次 harvestStepRequest 进场会重新基线，
        // 故即便 CC 的重绘迟到、被当作自发输出丢弃，也只丢这一行、不产生持久错位漂移（用户再上滚即补回）。
        harvestAwaitingRepaint = false
        pendingHarvestSteps = 0                          // 改动G：CC 对转发滚轮沉默→续发预算作废，不残留到下次手势
        harvestEmptySteps += 1                          // 改动E：CC 对本次转发上滚完全沉默 = 一次空步
        if !harvestInvariantHolds { abortHarvest(); return }
        harvestGiveUpIfStuck()                          // 改动E：累计空步达阈值且从未 bank+无选区→优雅回挂 live
    }

    /// 改动E：primed 但从未收割到任何历史(bankedCount==0)、累计空步达阈值、且无选区时——说明 CC 不配合
    /// (到其历史顶/忙/忽略滚轮)，靠下滚 reattach 逃逸对「持续上滚」无效。此时优雅放弃收割：abortHarvest→
    /// collapseHarvest 走 setViewYDisp(0) 清 userScrolling、[0,rows) 冻结帧==当前屏(无闪烁)，恢复 live 跟随。
    /// 一旦成功 bank 过一行(bankedCount>0)此出口永久关闭，绝不影响正常历史浏览。
    private func harvestGiveUpIfStuck () {
        guard harvestState == .primed, harvestBankedCount == 0,
              harvestEmptySteps >= Self.harvestMaxEmptySteps,
              !selection.active else { return }
        abortHarvest()
    }

    /// 收割态滚轮浏览路由（鼠标滚轮调用）。返回 true=已消费该手势（调用方应 return，
    /// 不再走通用本地/转发路径）。核心原则：浏览 banked 历史**绝不清选区**；只有「滚到
    /// banked 底部再下滚」这一刻意手势才回挂 live 并清选区。
    private func harvestRouteScroll (goingUp: Bool, velocity: Int) -> Bool {
        guard harvestState == .primed else { return false }
        // DS2：primed 期间若 CC 自驱滚动(IND/滚动区 LF)破坏了几何不变式(yBase==count-rows 等)，
        // 静默 desync 会让后续 band-diff 基线错位。每次滚动路由前校验，坏了就优雅降级回 live。
        guard harvestInvariantHolds else { abortHarvest(); return true }
        let b = terminal.displayBuffer
        let yDisp = b.yDisp
        if goingUp {
            if yDisp <= 0 {
                // 收割态顶部：请求更早一行。无论是否发出都消费本 notch——绝不把未入库的滚轮
                // 直接转发给 CC（会造成 CC 多滚一行而我们没入库的错位），也绝不冻结。
                // 改动G：按本 notch 的 velocity 累加续发预算(clamp 到一屏，防大甩动 momentum 爆量)。
                // drainHarvest 落库后会自动续发剩余预算，单手势连续 bank velocity 行而非死等下个 event。
                pendingHarvestSteps = min(pendingHarvestSteps + velocity, harvestRows)
                if harvestStepRequest() { flashScroller() }
                return true
            }
            flashScroller()
            scrollTo(row: max(0, yDisp - velocity))         // 向更早 banked 行回滚（选区保持）
            return true
        } else {
            pendingHarvestSteps = 0                      // 改动G：方向反转(下滚)清续发预算，避免上滚余量把视口带歪
            if yDisp >= harvestBankedCount {
                // 已在 banked 底部（=harvest 起始屏）。
                // 有选区 → 停在底部、保留选区，【绝不】回挂 live（回挂会 selectNone 清掉选区——
                // 用户明确抱怨「滑到底选中自动取消」）。用户在选/复制时，到底就是到底，不该清。
                // 返回 live 改由「打字(keyDown)」这一明确的新交互手势触发（见 keyDown 里的 reattach）。
                if selection.active && harvestBankedCount > 0 {     // 改动D(P3)：仅当确有 banked 历史(上滚=替代逃逸通道)
                    return true                                     // 才为保选区而 park；bankedCount==0 残留选区不再困死，落到下面 reattach 逃逸。
                }
                // 无选区 → 纯回看到底，按终端惯例回挂 live（无可丢失）。bankedCount==0 也要逃逸，消死格。
                reattachToLive()
                return true
            }
            flashScroller()
            scrollTo(row: min(harvestBankedCount, yDisp + velocity))  // 向更晚 banked 行前滚（选区保持）
            return true
        }
    }

    /// feedFinish 内调用：CC 对上次转发滚轮的重绘已落到 scratch，diff 出新卷入顶行并入库。
    func drainHarvest () {
        guard Self.harvestEnabled, harvestState == .primed, harvestAwaitingRepaint else { return }
        guard harvestInvariantHolds else { abortHarvest(); return }   // abort 内部已清 awaiting+watchdog
        let cur = harvestScratchSnapshot()
        let band = Self.detectRevealedBand(prev: harvestPrevScratch, cur: cur)
        guard let band = band else {
            // 改动C(P1)：非滚动重绘帧(spinner/状态栏/PTY 分块半帧)——【不】消费在途令牌、不撤看门狗，
            // 仅刷新基线，等真正的滚动重绘帧到来再入库；看门狗兜底「CC 自始至终不吐滚动帧」(到顶/忙)。
            harvestPrevScratch = cur
            harvestGiveUpIfStuck()                     // 改动E：若已累计足够空步且从未 bank→自愈回 live
            return
        }
        harvestAwaitingRepaint = false                 // 改动C：确认是真滚动重绘帧，此处才消费在途令牌
        clearHarvestWatchdog()                         // CC 已响应真滚动帧：撤掉自愈看门狗
        harvestEmptySteps = 0                          // 改动E：成功收割→清空空步计数
        let b = terminal.buffer                         // 改动F：prepend/几何都作用于 live buffer(CC 真正写入处)，不读同步窗口快照
        // 改动H(detectN)：CC 可能把多个滚轮报告合并成一帧滚 count 行；newest-first 逐行 prepend——
        // band.topRow..topRow+count-1 顶→底=旧→新，prependScrollback 总插逻辑 0，故从底(新)向顶(旧)
        // 依次 prepend，才能让最旧行落到回看缓冲顶端(行序正确)。环满即停止，已入库的保留。
        var banked = 0
        var r = band.topRow + band.count - 1
        while r >= band.topRow {
            let bankRow = b.yBase + r
            guard bankRow >= 0, bankRow < b.lines.count else { break }
            let bankLine = BufferLine(from: b.lines[bankRow])
            guard b.lines.prependScrollback(bankLine) else { break }   // 环满 → 停止收割
            banked += 1
            r -= 1
        }
        guard banked > 0 else { abortHarvest(); return }   // 一行都没入(越界/环满起步)→兜底降级
        b.yBase += banked                              // 整体下移 banked：同步 yBase/选区；yDisp 保持 0=向上滚视觉
        terminal.setViewYDisp(0)                       // 经 setViewYDisp 维持 userScrolling=(0<yBase)=true，锁住视口
        selection.shiftRows(by: banked)
        harvestBankedCount += banked
        harvestPrevScratch = harvestScratchSnapshot()
        setNeedsDisplay(bounds)
        // 改动G/H：本帧已推进 banked 行(awaiting 刚于上方清空)，按实际推进量扣预算并续发下一步——
        // 严格维持「至多一个在途」：harvestStepRequest 内 guard !harvestAwaitingRepaint 已保证。
        // 续发失败(到 CC 历史顶/不可收割)即清零预算，不残留到下次手势。
        if pendingHarvestSteps > 0 {
            pendingHarvestSteps = max(0, pendingHarvestSteps - banked)
            if pendingHarvestSteps > 0, !harvestStepRequest() { pendingHarvestSteps = 0 }
        }
    }

    /// 折叠收割几何，复位到「活体直绘」。copyTail=true 时把原始尾屏拷回 [0,rows) 作初始帧（优雅回挂）；
    /// false 时硬复位、交给 CC 重绘（错误兜底，几何可能已坏不可信）。
    private func collapseHarvest (copyTail: Bool) {
        let b = terminal.buffer                         // 改动A(P0)：折叠/复位必须作用于 live buffer，绝不作用于
                                                        // 同步窗口的冻结快照——否则 live 几何不复位、setViewYDisp(0)
                                                        // 算出 userScrolling=true(live yBase 仍=rows)→视口永久冻结(真凶)。
        let rows = b.rows
        if copyTail {
            // 原始冻结尾屏（harvest 起始时的活体屏）位于 logical[bankedCount, bankedCount+rows)，最贴近 live。
            // 先快照到临时数组再写，避免源/目标区间重叠时自我覆盖。
            let tailTop = max(0, min(harvestBankedCount, max(0, b.lines.count - rows)))
            if b.lines.count >= tailTop + rows {
                let snap = (0..<rows).map { BufferLine(from: b.lines[tailTop + $0]) }
                for y in 0..<rows { b.lines[y] = snap[y] }
            }
        }
        if b.lines.count > rows { b.lines.count = rows }
        b.yBase = 0
        terminal.setViewYDisp(0)                       // 关键(真凶 DS1 修复)：回 live 必须经 setViewYDisp 把 userScrolling 清回 false
                                                       //（此时 0<yBase=0 → false），否则残留 true → CC 新输出经 Terminal.scroll()
                                                       // 的 `if !userScrolling { yDisp=yBase }`(Terminal.swift:5314) 被跳过 → 视口不再
                                                       // 跟随 live = 用户报告的「卡死不能滚动」，唯敲键(ensureCaretIsVisible)/切任务(resize→abort)能救。
        harvestState = .idle
        harvestAwaitingRepaint = false
        clearHarvestWatchdog()
        harvestBankedCount = 0
        harvestRows = 0
        harvestEmptySteps = 0                           // 改动E：复位空步计数
        pendingHarvestSteps = 0                         // 改动G：折叠回 live(含 abort/reattach)清续发预算
        harvestPrevScratch = []
        terminal.refresh(startRow: 0, endRow: rows)
        setNeedsDisplay(bounds)
    }

    /// 错误/换屏/resize 兜底：清选区 + 硬复位。最坏短暂残留一帧旧内容，CC 持续刷新会盖掉。
    func abortHarvest () {
        guard harvestState != .idle else { return }
        selection.selectNone()
        collapseHarvest(copyTail: false)
    }

    /// 回到 live：先转发足量下滚让 CC 内部滚回底部（在底部钳住，超发安全），再折叠复位。
    /// CC 的下滚回包异步到达时 yBase 已=0 → 直接画成 live tail。
    func reattachToLive () {
        guard harvestState == .primed else { return }
        let downs = min(harvestBankedCount + terminal.buffer.rows + 2, 256)   // 改动A(P0)：用 live buffer 的 rows
        harvestState = .idle                           // 防止下滚回包又被 drainHarvest 当收割
        harvestAwaitingRepaint = false
        clearHarvestWatchdog()
        for _ in 0..<downs {
            sendAlternateMouseWheel(up: false, lines: 1, at: harvestMidViewportPoint, modifierFlags: [])
        }
        selection.selectNone()
        collapseHarvest(copyTail: true)
    }

    // Callback from when the mouseDown autoscrolling timer goes off
    private func scrollingTimerElapsed (source: Timer)
    {
        guard selection.active, autoScrollDelta != 0 else {
            stopSelectionAutoScroll()
            return
        }

        let changed = performSelectionAutoScroll(delta: autoScrollDelta, point: selectionAutoScrollPoint)
        autoScrollDelta = selectionAutoScrollDelta(for: selectionAutoScrollPoint)
        if changed {
            setNeedsDisplay(bounds)
        }
    }
    
    /// 滚轮专用：按住 Shift / Option / ⌘ 滚动时，绕过「把滚轮转发给程序」，改走
    /// 本地滚动历史（scrollback）。普通滚动仍转发给全屏 TUI（vim/less/Claude Code）
    /// 让其内容滚动，见 scrollWheel。注意：点击/拖拽划选走的是**相反**的优先级
    /// （普通拖拽即本地划选），见 mouseReportingRequested —— 两者刻意不共用一套语义。
    @inline(__always)
    func mouseReportingBypassed(with event: NSEvent) -> Bool {
        let f = event.modifierFlags
        return f.contains(.shift) || f.contains(.option) || f.contains(.command)
    }

    /// Relay patch（划选优先）：本产品是 AI agent 终端，从运行中的 Claude Code/
    /// Codex 输出里划选、复制是高频核心动作。因此点击/拖拽反转了终端默认优先级——
    /// 普通拖拽 **始终本地划选**，即使 TUI（vim/tmux/Claude Code/Codex 等）开了
    /// 鼠标追踪；只有按住 ⌥(Option) 拖拽，才把鼠标交还给程序（让其自身的点击/拖拽
    /// UI 仍可用）。⇧ 走本地选区扩展、⌘ 走链接/路径点击（见 mouseUp 的 ⌘-click
    /// 分支），二者都不转发。返回 true 表示「这一手势要交给程序上报」。
    /// （滚轮是另一套优先级——普通滚动转发给程序，见 mouseReportingBypassed。）
    @inline(__always)
    func mouseReportingRequested(with event: NSEvent) -> Bool {
        return event.modifierFlags.contains(.option)
    }

    /// Relay patch: ⌘-click 命中的「裸文件路径」回调（非 URL，与 OSC 8 超链接分开）。
    /// 取的是屏幕明文，所见即所点，不存在「显示文本≠真实目标」的伪装风险；由宿主
    /// （RelayTerminalView）负责展开 ~ / 拼接 cwd 解析相对路径，并在访达中定位。
    public var onRequestOpenLocalPath: ((String) -> Void)?

    /// Relay patch: 宿主回答「这个 token 是否解析为真实存在的本地文件」。仅在 ⌘-悬停时
    /// 调用（节流于鼠标移动），用于决定裸路径要不要高亮成可点链接。与打开同源解析。
    public var onResolveLocalPath: ((String) -> Bool)?

    /// Relay patch: 取格子所在行的屏幕明文「路径 token」及其列范围 —— 以空白为界向左右
    /// 扩展的连续非空白串。点在空白上返回 nil；含空格的路径不在覆盖范围（终端无法
    /// 无歧义界定其边界）。NUL 视作空白边界。range 为半开区间 [s, e+1)，供高亮用。
    func localPathTokenRange(at hit: Position) -> (token: String, range: Range<Int>)? {
        let buf = terminal.displayBuffer
        guard hit.row >= 0, hit.row < buf.lines.count else { return nil }
        let line = buf.lines[hit.row]
        let limit = min(terminal.cols, line.count)
        guard limit > 0, hit.col >= 0, hit.col < limit else { return nil }
        // 宽字符（CJK，width=2）的尾随格 code==0：属于前一字符，既非边界也不取字。
        // 不特判会让「发票…」这类中文路径在每个汉字后断开。
        func isTrailing(_ i: Int) -> Bool { i > 0 && line[i].code == 0 && line[i - 1].width == 2 }
        func isSep(_ i: Int) -> Bool {
            if isTrailing(i) { return false }
            let cd = line[i]
            if cd.isNull { return true }
            let c = cd.getCharacter()
            return c == " " || c == "\t"
        }
        guard !isSep(hit.col) else { return nil }
        var s = hit.col, e = hit.col
        while s > 0, !isSep(s - 1) { s -= 1 }
        while e + 1 < limit, !isSep(e + 1) { e += 1 }
        var out = ""
        out.reserveCapacity(e - s + 1)
        for i in s...e {
            if isTrailing(i) { continue }
            let cd = line[i]
            if cd.isNull { continue }
            out.append(cd.getCharacter())
        }
        let t = out.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : (t, s ..< (e + 1))
    }

    func localPathToken(at hit: Position) -> String? {
        localPathTokenRange(at: hit)?.token
    }

    public override func mouseDown(with event: NSEvent) {
        stopSelectionAutoScroll()
        if allowMouseReporting && terminal.mouseMode.sendButtonPress() && mouseReportingRequested(with: event) {
            sharedMouseEvent(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let hit = calculateMouseHit(with: event).grid

        // 新一次按下：拖拽尚未开始，复位标志（真正开始划选时由 mouseDragged 置 true）。
        isSelectionDragInProgress = false

        switch event.clickCount {
        case 1:
            if selection.active == true && event.modifierFlags.contains(.shift) {
                selection.shiftExtend(bufferPosition: selectionPosition(for: point))
            } else {
                // 清掉旧选区，并把「按下的格子」记为锚点：随后的拖拽划选从这里开始，
                // 而不是从拖动第一帧的采样点开始，否则选区起点会偏出最多一个字符。
                if selection.active { selection.active = false }
                pendingSelectionAnchor = selectionPosition(for: point)
            }
        case 2:
            let displayBuffer = terminal.displayBuffer
            selection.selectWordOrExpression(at: Position(col: hit.col, row: hit.row), in: displayBuffer)

        default:
            // 3 and higher

            selection.select(row: hit.row)
        }
        setNeedsDisplay(bounds)
    }
    
    func getPayload (for event: NSEvent) -> Any?
    {
        let hit = calculateMouseHit(with: event).grid
        let displayBuffer = terminal.displayBuffer
        let cd = displayBuffer.lines [hit.row][hit.col]
        return cd.getPayload()
    }
    
    var didSelectionDrag: Bool = false
    
    public override func mouseUp(with event: NSEvent) {
        stopSelectionAutoScroll()
        pendingSelectionAnchor = nil
        // 拖拽结束：恢复主屏「输出滚动时清选区」的原行为（备用屏由 feedPrepare/linefeed 自身判断保留）。
        isSelectionDragInProgress = false
        let hit = calculateMouseHit(with: event).grid
        updateHoverLink(at: hit, commandOverride: commandActive || event.modifierFlags.contains(.command))
        if let result = linkForClick(at: hit, hasCommandModifier: event.modifierFlags.contains(.command)) {
            terminalDelegate?.requestOpenLink(source: self, link: result.link, params: result.params)
            return
        }
        // Relay patch: ⌘-click 裸文件路径（OSC 8/URL 未命中时）。读屏幕明文，
        // 所见即所点；拖拽选择（didSelectionDrag）不算点击，跳过。
        if event.modifierFlags.contains(.command), !didSelectionDrag,
           let token = localPathToken(at: hit) {
            onRequestOpenLocalPath?(token)
            return
        }
        if allowMouseReporting && terminal.mouseMode.sendButtonRelease() && mouseReportingRequested(with: event) {
            sharedMouseEvent(with: event)
            return
        }
        
        #if DEBUG
        // let hit = calculateMouseHit(with: event)
        //print ("Up at col=\(hit.col) row=\(hit.row) count=\(event.clickCount) selection.active=\(selection.active) didSelectionDrag=\(didSelectionDrag) ")
        #endif
        
        didSelectionDrag = false
    }
    
    public override func mouseDragged(with event: NSEvent) {
        let displayBuffer = terminal.displayBuffer
        let point = convert(event.locationInWindow, from: nil)
        let mouseHit = calculateMouseHit(at: point)
        let hit = mouseHit.grid
        if allowMouseReporting && mouseReportingRequested(with: event) {
            stopSelectionAutoScroll()
            if terminal.mouseMode.sendMotionEvent() {
                let flags = encodeMouseEvent(with: event)
                let screenRow = max (0, min (displayBuffer.rows - 1, hit.row - displayBuffer.yDisp))
                terminal.sendMotion(buttonFlags: flags, x: hit.col, y: screenRow, pixelX: mouseHit.pixels.col, pixelY: mouseHit.pixels.row)
            
                return
            }
            if terminal.mouseMode != .off {
                return
            }
        }

        let rawSelectionHit = selectionPosition(for: point)
        let selectionHit = selectionDragPosition(for: point)
        if selection.active {
            selection.dragExtend(bufferPosition: selectionHit)
        } else {
            // 起点用 mouseDown 记录的锚点（真正按下的格子），缺省回退到当前点。
            let anchor = pendingSelectionAnchor ?? rawSelectionHit
            selection.setSoftStart(bufferPosition: anchor)
            selection.startSelection()
            selection.dragExtend(bufferPosition: selectionHit)
        }
        pendingSelectionAnchor = nil
        didSelectionDrag = true
        // 标记拖拽划选进行中：在此期间 feedPrepare/linefeed 不会因流式输出清掉选区，
        // 这是「下拖自动滚动选中」和「Claude Code 里流式划选」能成立的前提。
        isSelectionDragInProgress = true
        updateSelectionAutoScroll(at: point)
        setNeedsDisplay(bounds)
    }
    
    func tryUrlFont () -> NSFont
    {
        for x in ["Optima", "Helvetica", "Helvetica Neue"] {
            if let font = NSFont (name: x, size: 12) {
                return font
            }
        }
        return NSFont.systemFont(ofSize: 12)
    }
    
    var urlPreview: NSTextField?
    private var lastReportedLink: String?
    func previewUrl (payload: String)
    {
        if let (url, _) = urlAndParamsFrom(payload: payload) {
            if let up = urlPreview {
                up.stringValue = url
                up.sizeToFit()
            } else {
                let nup: NSTextField
                if #available(macOS 10.12, *) {
                    nup = NSTextField (string: url)
                } else {
                    nup = NSTextField ()
                }
                nup.isBezeled = false
                nup.font = tryUrlFont ()
                nup.backgroundColor = nativeForegroundColor
                nup.textColor = nativeBackgroundColor
                nup.sizeToFit()
                nup.frame = CGRect (x: 0, y: 0, width: nup.frame.width, height: nup.frame.height)
                addSubview(nup)
                urlPreview = nup
            }
        }
    }
    
    func removePreviewUrl ()
    {
        if let urlPreview = self.urlPreview {
            urlPreview.removeFromSuperview()
            self.urlPreview = nil
        }
    }

    func reportLink(at position: Position)
    {
        guard linkReporting != .none else {
            lastReportedLink = nil
            return
        }
        let mode: Terminal.LinkLookupMode = linkReporting == .explicit ? .explicitOnly : .explicitAndImplicit
        let link = terminal.link(at: .buffer(position), mode: mode)
        if link != lastReportedLink {
            lastReportedLink = link
        }
    }

    func updateHoverLink(at position: Position, commandOverride: Bool? = nil)
    {
        let hoverModes: [LinkHighlightMode] = [.hover, .hoverWithModifier]
        guard hoverModes.contains(linkHighlightMode) else {
            if linkHighlightRange != nil {
                let oldRange = linkHighlightRange
                linkHighlightRange = nil
                invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
                queuePendingDisplay()
            }
            return
        }
        let effectiveCommandActive = commandOverride ?? commandActive
        if linkHighlightMode == .hoverWithModifier && !effectiveCommandActive {
            if linkHighlightRange != nil {
                let oldRange = linkHighlightRange
                linkHighlightRange = nil
                invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
                queuePendingDisplay()
            }
            updatePathPointerCursor(active: false)
            return
        }
        let match = terminal.linkMatch(at: .buffer(position), mode: .explicitAndImplicit)
        var newRange = match?.rowRanges
        // Relay patch: OSC8/URL 未命中且 ⌘ 处于活动态时，若命中的裸 token 能解析为真实
        // 文件，则把它也高亮成链接（下划线 + 手型光标），让「⌘-点击打开」可被发现。
        if newRange == nil, effectiveCommandActive,
           let hit = localPathTokenRange(at: position),
           onResolveLocalPath?(hit.token) == true {
            newRange = [Terminal.LinkMatch.RowRange(row: position.row, range: hit.range)]
        }
        if newRange != linkHighlightRange {
            let oldRange = linkHighlightRange
            linkHighlightRange = newRange
            invalidateLinkHighlight(oldRange: oldRange, newRange: newRange)
            queuePendingDisplay()
        }
        updatePathPointerCursor(active: newRange != nil && effectiveCommandActive)
    }

    // Relay patch: 悬停在可点击链接/路径上时切手型光标，离开恢复 I-beam。只追踪自己设过
    // 的状态，避免和文本选择的 I-beam 互相打架。.set() 幂等，逐次 mouseMoved 调用无害。
    private var pathPointerActive = false
    func updatePathPointerCursor(active: Bool) {
        if active {
            pathPointerActive = true
            NSCursor.pointingHand.set()
        } else if pathPointerActive {
            pathPointerActive = false
            NSCursor.iBeam.set()
        }
    }

    func currentMouseHit() -> Position?
    {
        guard let window else {
            return nil
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return calculateMouseHit(at: point).grid
    }
    
    public override func mouseMoved(with event: NSEvent) {
        let hit = calculateMouseHit(with: event)
        if commandActive {
            if let payload = getPayload(for: event) as? String {
                previewUrl (payload: payload)
            }
            reportLink(at: hit.grid)
        }
        updateHoverLink(at: hit.grid)

        // Relay patch: 悬停上报同样只在按住 ⌥ 时才转发给程序，与拖拽划选一致——
        // 不按 ⌥ 时程序完全拿不到鼠标，终端这边专心做本地划选/链接悬停。
        if terminal.mouseMode.sendMotionEvent() && mouseReportingRequested(with: event) {
            let flags = encodeMouseEvent(with: event, overwriteRelease: true)
            terminal.sendMotion(buttonFlags: flags, x: hit.grid.col, y: hit.grid.row, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
        }
    }
    
    public override func scrollWheel(with event: NSEvent) {
        if event.deltaY == 0 {
            return
        }
        let goingUp = event.deltaY > 0
        // Relay patch（平滑滚动）：触控板/妙控鼠标(精确滚动增量)改用「像素累积逐行」——把连续的
        // 亚行手势按 cellHeight 攒成整行，替代 calcScrollingVelocity 的 1/3/10/20 离散档位。
        // 否则触控板慢滑也被量化成每个 event 跳 3 行（用户反馈「向上滚一次三行三行、不丝滑」）。
        // 累积未满一行 → velocity 0 → 本次不滚、纯攒，下个 event 满一行再逐行推进 = 连续跟手。
        // 鼠标滚轮(无精确增量)保持档位量化（notch 稀疏，量化合理）。
        let velocity = wheelVelocity(for: event)
        if velocity == 0 { return }

        // Relay patch（捕获式滚动）：备用屏(CC)普通滚轮——live 屏顶部上滚 → 进入收割态；收割态内
        // 上下滚在 banked 历史中浏览（选区保持），滚到 banked 底部再下滚 → 刻意回挂 live。
        // 收割未消费（idle / 顶部收割在途被吸收除外）则落到下面的通用本地/转发路径，绝不冻结滚轮。
        // DS3：primed 期间程序撤掉鼠标上报(mouseMode→.off / allowMouseReporting 变化)使 harvestEligible 翻假，
        // 否则下面的 harvestEligible 块被整体跳过、2*rows 的 primed 几何永远残留 → 这里先收口回 live。
        if harvestState == .primed, !harvestEligible { abortHarvest() }
        if harvestEligible, !mouseReportingBypassed(with: event) {
            let b = terminal.displayBuffer
            if goingUp, harvestState == .idle, b.yBase == 0, b.yDisp == 0 { _ = prime() }
            if harvestRouteScroll(goingUp: goingUp, velocity: velocity) {
                return
            }
        }

        // Relay patch: alternate-screen scroll. Fullscreen apps (vim, less,
        // htop, man, …) run on the alternate buffer, which has no scrollback —
        // local scrollUp/scrollDown are no-ops there, so the wheel did nothing.
        // Match iTerm2/Terminal.app/Ghostty and forward the gesture to the app:
        //   • app enabled mouse tracking (e.g. `vim` with `set mouse=a`) →
        //     send the wheel as SGR/X10 mouse reports (buttons 4/5);
        //   • otherwise → "alternate scroll mode": send cursor Up/Down keys
        //     (respecting DECCKM), so a plain `vim`/`less` scrolls its content.
        // A held modifier (shift/option/command) keeps falling through to the
        // local path, consistent with mouseReportingBypassed elsewhere.
        //
        // Relay patch: 备用屏现在自带 scrollback（见 Terminal init）。滚轮优先在 Relay 自己的
        // 历史里本地上下浏览，而不是把手势转发给程序——这样 Claude Code / codex 等会把旧输出
        // 滚出屏幕的 TUI，用户能像 iTerm2 那样向上滚回看历史并选中。判据天然放过 vim/less/htop
        // 这类「就地重绘、不产生 scrollback」的全屏程序：它们 yBase 恒为 0，两个条件都不成立，
        // 仍走下面的转发路径。
        let altBuf = terminal.displayBuffer
        let inScrollbackRegion = altBuf.yDisp < altBuf.yBase         // 已滚入历史区，继续上下浏览都本地处理
        let canEnterHistoryFromBottom = goingUp && altBuf.yBase > 0  // 在底部向上滚、且确有历史可看
        if terminal.isDisplayBufferAlternate && (inScrollbackRegion || canEnterHistoryFromBottom) {
            flashScroller()
            if goingUp {
                scrollUp (lines: velocity)
            } else {
                scrollDown(lines: velocity)
            }
            return
        }

        if terminal.isDisplayBufferAlternate && !mouseReportingBypassed(with: event) {
            // Relay patch: 走到这里 = 备用屏本地没有可滚的历史(yBase==0)，滚轮要转发给程序。
            // Claude Code / codex 这类 TUI 自管滚动、收到滚轮后就地重绘视口，并不把旧行吐进
            // Relay 的 scrollback（故上面的本地分支永不触发）。重绘后内容变了，而选区仍锚在
            // 固定的终端行号上：高亮块原地不动、内容从下面滑过 → 高亮与复制都会错位。因此程序
            // 驱动的滚动一旦开始就清掉本地选区，与 iTerm2/Terminal.app/Ghostty 一致。拖拽划选
            // (isSelectionDragInProgress) 不在此列：那条路由 performSelectionAutoScroll 走本地
            // scrollback 边缘滚动、滚尽即锁可见屏（不转发、不累积屏外文本），不经 scrollWheel。
            if selection.active && !isSelectionDragInProgress {
                selection.selectNone()
                setNeedsDisplay(bounds)
            }
            // Discrete notched wheels report one tick at a time (velocity 1);
            // give them the xterm `alternateScroll` convention of ~3 lines per
            // notch so vim/less scroll at the expected pace. Trackpads/Magic
            // Mouse (precise deltas) already stream smoothly, so keep their
            // velocity-based count to avoid over-accelerating the app.
            let lines = event.hasPreciseScrollingDeltas ? velocity : max (velocity, 3)
            if allowMouseReporting && terminal.mouseMode != .off {
                sendAlternateMouseWheel(up: goingUp, lines: lines, event: event)
            } else {
                sendAlternateScrollKeys(up: goingUp, lines: lines)
            }
            return
        }

        flashScroller()
        if goingUp {
            scrollUp (lines: velocity)
        } else {
            scrollDown(lines: velocity)
        }
    }

    // Relay patch: cap how many line-events one physical gesture forwards to the
    // app, so a fast trackpad flick (velocity up to `rows`) can't flood it.
    private static let alternateScrollLineCap = 10

    /// Relay patch: alternate-scroll — translate the wheel into cursor Up/Down
    /// key presses for apps that don't track the mouse (default `vim`, `less`,
    /// `man`). Honors DECCKM (applicationCursor) like real keystrokes do.
    private func sendAlternateScrollKeys(up: Bool, lines: Int) {
        let seq = up
            ? (terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
            : (terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
        let count = max (1, min (lines, Self.alternateScrollLineCap))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(seq.count * count)
        for _ in 0..<count { bytes.append(contentsOf: seq) }
        send(bytes)
    }

    /// Relay patch: send the wheel as mouse-button reports (button 4 = up,
    /// 5 = down) for apps that enabled mouse tracking, so e.g. `vim` with
    /// `set mouse=a` scrolls. One report per line, capped like the key path.
    private func sendAlternateMouseWheel(up: Bool, lines: Int, event: NSEvent) {
        sendAlternateMouseWheel(up: up, lines: lines, at: convert(event.locationInWindow, from: nil), modifierFlags: event.modifierFlags)
    }

    private func sendAlternateMouseWheel(up: Bool, lines: Int, at point: CGPoint, modifierFlags: NSEvent.ModifierFlags) {
        let displayBuffer = terminal.displayBuffer
        let hit = calculateMouseHit(at: point)
        let screenRow = max (0, min (displayBuffer.rows - 1, hit.grid.row - displayBuffer.yDisp))
        let buttonFlags = terminal.encodeButton(
            button: up ? 4 : 5, release: false,
            shift: modifierFlags.contains(.shift), meta: modifierFlags.contains(.option), control: modifierFlags.contains(.control))
        let count = max (1, min (lines, Self.alternateScrollLineCap))
        for _ in 0..<count {
            terminal.sendEvent(buttonFlags: buttonFlags, x: hit.grid.col, y: screenRow, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
        }
    }

    private func calcScrollingVelocity (delta: Int) -> Int
    {
        if delta > 9 {
            return max (terminal.rows, 20)
        }
        if delta > 5 {
            return 10
        }
        if delta > 1 {
            return 3
        }
        return 1
    }

    /// Relay patch（平滑滚动）：把一次滚轮 event 归一化成「本次该滚多少行」（非负，方向由调用方
    /// 据 event.deltaY 符号决定）。精确滚动设备(触控板/妙控鼠标)走像素累积——连续亚行手势攒满
    /// cellHeight 才进一行，实现逐行连续滚动；普通鼠标滚轮(无精确增量)沿用 calcScrollingVelocity
    /// 的档位量化（notch 稀疏，量化合理）。
    private func wheelVelocity (for event: NSEvent) -> Int {
        guard event.hasPreciseScrollingDeltas else {
            wheelPixelAccumY = 0                                  // 切回普通滚轮：丢弃精确累积，避免残留
            lastWheelTime = 0                                     // 改动H：重置行速基线
            return calcScrollingVelocity(delta: Int (abs (event.deltaY)))
        }
        let cellHeight = max (cellDimension?.height ?? 1, 1)
        let dy = event.scrollingDeltaY
        let sign = dy > 0 ? 1 : (dy < 0 ? -1 : 0)
        if sign != 0 && sign != wheelAccumSign {                 // 方向反转：清累积，避免上一方向余量把视口带回一帧
            wheelPixelAccumY = 0
            wheelAccumSign = sign
        }
        // 改动H(加速度)：按瞬时行速放大像素累积——慢滑 gain=1 保持 1:1 逐行跟手(消除当初的「跳3行」)，
        // 快滑/甩动 ease-in 超线性放大(恢复原 calcScrollingVelocity 被丢掉的加速档)，让一次手势翻一大片。
        let now = event.timestamp
        let dt = lastWheelTime > 0 ? min(max(now - lastWheelTime, 0.004), 0.1) : 0.016
        lastWheelTime = now
        let rowsPerSec = Double(abs (dy) / cellHeight) / dt
        wheelPixelAccumY += abs (dy) * CGFloat(Self.harvestAccelGain(rowsPerSec: rowsPerSec))
        let steps = Int (wheelPixelAccumY / cellHeight)          // 攒满整数行才滚，余数留待下个 event
        if steps > 0 {
            wheelPixelAccumY -= CGFloat (steps) * cellHeight
        }
        return steps
    }

    /// 改动H(加速度增益)：触控板上滚收割的速度自适应放大系数。慢滑(rowsPerSec<=slow)gain=1 保持
    /// 1:1 逐行跟手；快滑/甩动按 ease-in(t²) 超线性放大到 maxGain，恢复原 calcScrollingVelocity
    /// 被丢掉的加速档，让一次手势注入更多收割预算、翻动一大片。阈值用「行/秒」故与字号/分辨率无关；
    /// 常量按真机刷新率可微调(maxGain 过大→甩太多+拖尾，过小→无感)。
    static func harvestAccelGain (rowsPerSec: Double) -> Double {
        let slow = 8.0, fast = 90.0, maxGain = 6.0
        if rowsPerSec <= slow { return 1.0 }
        let t = min((rowsPerSec - slow) / (fast - slow), 1.0)
        return 1.0 + (maxGain - 1.0) * t * t
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
    
    public func resetFontSize ()
    {
        fontSet = FontSet (font: FontSet.defaultFont)
    }
    
    func getImageScale () -> CGFloat {
        self.window?.backingScaleFactor ?? 1
    }
    
    func scale (image: NSImage, size: CGSize) -> NSImage {
        
        let scaledImg = TTImage (size: CGSize (width: size.width, height: size.height))
        let srcRatio = image.size.height/image.size.width
        let scaledRatio = size.width/size.height
        scaledImg.lockFocus()
        let srcRect = CGRect(origin: CGPoint.zero, size: image.size)
        let dstRect: CGRect
        
        if srcRatio < scaledRatio {
            let nw = (size.height * image.size.width) / image.size.height
            dstRect = CGRect (x: (size.width-nw)/2, y: 0, width: nw, height: size.height)
        } else {
            let nh = (size.width * image.size.height) / image.size.width
            dstRect = CGRect (x: 0, y: (size.height-nh)/2, width: size.width, height: nh)
        }
        image.draw(in: dstRect, from: srcRect, operation: .copy, fraction: 1)
        
        scaledImg.unlockFocus()
        return scaledImg
    }
    
    func drawImageInStripe (image: TTImage, srcY: CGFloat, width: CGFloat, srcHeight: CGFloat, dstHeight: CGFloat, size: CGSize) -> TTImage? {
        guard let bitmapImage = NSBitmapImageRep (
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: NSColorSpaceName.calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        let stripe = NSImage (size: size)
        stripe.addRepresentation (bitmapImage)

        stripe.lockFocus()
        let srcRect = CGRect(x: 0, y: CGFloat(srcY), width: image.size.width, height: srcHeight)
        let destRect = CGRect(x: 0, y: 0, width: width, height: dstHeight)
        image.draw(in: destRect, from: srcRect, operation: .copy, fraction: 1.0)
        stripe.unlockFocus()
        return stripe
    }
    
    open func showCursor(source: Terminal) {
        if useMetalRenderer {
            queueMetalDisplay()
            return
        }
        if caretView.superview == nil {
            addSubview(caretView)
        }
    }

    open func hideCursor(source: Terminal) {
        if useMetalRenderer {
            queueMetalDisplay()
            return
        }
        caretView.removeFromSuperview()
    }
    
    open func cursorStyleChanged (source: Terminal, newStyle: CursorStyle) {
        caretView.style = newStyle
        updateCaretView()
        if useMetalRenderer {
            queueMetalDisplay()
        }
    }

    open func bell(source: Terminal) {
        terminalDelegate?.bell (source: self)
    }

    public func progressReport(source: Terminal, report: Terminal.ProgressReport) {
        if Thread.isMainThread {
            handleProgressReport(report)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.handleProgressReport(report)
            }
        }
    }

    public func isProcessTrusted(source: Terminal) -> Bool {
        true
    }

    public func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? {
        let scale = getImageScale()
        let width = Int(round(cellDimension.width * scale))
        let height = Int(round(cellDimension.height * scale))
        return (width, height)
    }
    
    public func mouseModeChanged(source: Terminal) {
        if source.mouseMode == .anyEvent {
            startTracking()
        } else {
            if terminal != nil {
                deregisterTrackingInterest()
            }
        }
    }
    
    public func setTerminalTitle(source: Terminal, title: String) {
        terminalDelegate?.setTerminalTitle(source: self, title: title)
    }
    
    public func sizeChanged(source: Terminal) {
        terminalDelegate?.sizeChanged(source: self, newCols: source.cols, newRows: source.rows)
        updateScroller ()
    }
    
    func ensureCaretIsVisible ()
    {
        let displayBuffer = terminal.displayBuffer
        let realCaret = displayBuffer.y + displayBuffer.yBase
        let viewportEnd = displayBuffer.yDisp + displayBuffer.rows
        
        if realCaret >= viewportEnd || realCaret < displayBuffer.yDisp {
            scrollTo (row: displayBuffer.yBase)
        }
    }
    
    public func setTerminalIconTitle(source: Terminal, title: String) {
        //
    }
    
    // Terminal.Delegate method implementation
    public func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        switch command {
        case .bringToFront:
            return nil
        case .deiconifyWindow:
            return nil
        case .iconifyWindow:
            return nil
        case .maximizeWindow:
            return nil
        case .maximizeWindowHorizontally:
            return nil
        case .maximizeWindowVertically:
            return nil
        case .moveWindowTo(_, _):
            return nil
        case .refreshWindow:
            return nil
        case .reportCellSizeInPixels:
            if let cellDimension {
                let h = Int(cellDimension.height * self.backingScaleFactor())
                let w = Int(cellDimension.width * self.backingScaleFactor())
                return terminal.cc.CSI + "6;\(h);\(w)t".utf8
            }
            return nil
        case .reportIconLabel:
            return nil
        case .reportScreenSizeCharacters:
            return nil
        case .resizeWindowTo(width: let width, height: let height):
            print("Request to resize to \(width)x\(height)")
            return nil
        case .sendToBack:
            return nil
        case .resizeTo(_):
            return nil
        case .resizeTerminal:
            return nil
        case .restoreMaximizedWindow:
            return nil
        case .undoFullScreen:
            return nil
        case .switchToFullScreen:
            return nil
        case .toggleFullScreen:
            return nil
        case .reportTerminalState:
            return nil
        case .reportTerminalPosition:
            return nil
        case .reportTextAreaPosition:
            return nil
        case .reportTextAreaPixelDimension:
            guard let cellDimension else { return nil }
            let factor = self.backingScaleFactor()
            let h = Int(round(cellDimension.height * factor * CGFloat(terminal.rows)))
            let w = Int(round(cellDimension.width * factor * CGFloat(terminal.cols)))
            return terminal.cc.CSI + "4;\(h);\(w)t".utf8
        case .reportSizeOfScreenInPixels:
            return nil
        case .reportTextAreaCharacters:
            // The base implementation is good enough
            return nil
        case .reportWindowTitle:
            return nil
        case .reportTerminalWindowPixelDimension:
            return nil
        }
    }
    
    public func iTermContent (source: Terminal, content: ArraySlice<UInt8>) {
        terminalDelegate?.iTermContent(source: self, content: content)
    }
}


// Default implementations for TerminalViewDelegate

extension TerminalViewDelegate {
    /// Relay patch: terminal output is untrusted. An OSC 8 hyperlink can display
    /// innocent text (e.g. "https://github.com/...") while the actual target is a
    /// `file://`, `x-apple-...`, or custom app scheme — a ⌘-click would then hand a
    /// dangerous URL to the OS. Only safe web/mail schemes are opened; anything else
    /// is silently ignored. (iTerm2/Ghostty apply the same kind of scheme gating.)
    public func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        let allowedSchemes: Set<String> = ["http", "https", "mailto", "ftp", "ftps"]
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
    
    public func bell (source: TerminalView)
    {
        NSSound.beep()
    }
    
    public func iTermContent (source: TerminalView, content: ArraySlice<UInt8>) {
    }
}
#endif
