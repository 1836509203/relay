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
    // mouseDown 记录的选区锚点：保证拖拽划选从「真正按下的格子」开始，而非拖动第一帧的采样点。
    private var pendingSelectionAnchor: Position?

    // 拖拽划选进行中标志：为 true 时，流式输出（feedPrepare / linefeed）不得清掉选区，
    // 否则在 Claude Code/codex 等持续刷新的程序里，用户刚划下的选区会被下一帧抹掉，根本选不中。
    // mouseDragged 置 true，mouseDown / mouseUp 复位。非 private：feedPrepare 在
    // AppleTerminalView.swift 的同模块扩展里需读取它。
    var isSelectionDragInProgress = false

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

        // 锁可见屏（用户拍板）：选区自动滚动只读真实缓冲行——读到哪复制到哪，高亮逐字节 == 复制。
        // 备用屏分两路（由 selectionAutoScrollDelta 的 gate 决定，见上）：① CC/codex 用 CUP 就地
        // 重绘时 yBase 保持 0、本地无历史可滚 → delta 归零、停在可见边缘 = 锁可见屏；② 若程序改用
        // 真实换行让旧行进入 alt-scrollback（yBase>0）→ 本地滚动连续选中。两路都绝不把滚轮转发给
        // 程序、绝不累积屏外文本——那条老路会让高亮与复制错位、且物理上不可信（屏外内容不在任何
        // 终端缓冲）。与 iTerm2/Terminal.app/Ghostty 全屏程序一致：要选屏外内容，先滚程序自身再划选。
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

    func selectedTextForCopy () -> String
    {
        // 单一数据源：复制永远返回当前真实选区文本，保证「看到的高亮 == 复制的内容」。
        return selection.getSelectedText()
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
        let velocity = calcScrollingVelocity(delta: Int (abs (event.deltaY)))
        let goingUp = event.deltaY > 0

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
