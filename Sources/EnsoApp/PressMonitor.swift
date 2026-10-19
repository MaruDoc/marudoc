import AppKit
import CoreGraphics
import EnsoShared

/// Watches the left mouse button system-wide and turns a still, held press on a Finder item into the radial menu.
///
/// The event tap runs on its own thread so that nothing MaruDoc does on the main thread can ever delay the
/// user's mouse. Ordinary clicks, double-clicks, drags and right-clicks pass through untouched: the press only
/// counts when the pointer stays within `slop` points for `delay` seconds. When the menu opens, Finder receives
/// a synthetic mouse-up (so it sees a plain click and never starts dragging the icon) and the real drag and
/// release are consumed until the menu closes.
final class PressMonitor {

    enum Phase { case idle, pressed, menu, sticky }

    struct Opened {
        var session: RadialSession
        var target: FinderAX.Target
    }

    // Main-thread callbacks.
    var onOpen: ((Opened) -> Void)?
    var onUpdate: ((RadialGeometry.Hit, Int?, Bool) -> Void)?
    var onChoose: ((String, FinderAX.Target) -> Void)?
    var onClose: (() -> Void)?

    // Settings, read on the tap thread.
    private let lock = NSLock()
    private var _delay: TimeInterval = 0.5
    private var _allowWindows = true
    var delay: TimeInterval { get { lock.withLock { _delay } } set { lock.withLock { _delay = newValue } } }
    var allowWindows: Bool { get { lock.withLock { _allowWindows } } set { lock.withLock { _allowWindows = newValue } } }

    let slop: CGFloat = 5
    /// `defaults write app.marudoc.MaruDoc verboseLog -bool true` logs each step of press detection.
    private let verbose = UserDefaults.standard.bool(forKey: "verboseLog")
    private func trace(_ s: @autoclosure () -> String) { if verbose { Log.info("press: " + s()) } }
    private static let syntheticMarker: Int64 = 0x454E534F // "ENSO"

    // Tap-thread state.
    private var phase: Phase = .idle
    private var pressPoint = CGPoint.zero
    private var pressTimer: Timer?
    private var dwellTimer: Timer?
    private var session: RadialSession?
    private var target: FinderAX.Target?
    private var tap: CFMachPort?
    private var moveTap: CFMachPort?
    private var keyTap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private(set) var canModifyEvents = false

    private let stateLock = NSLock()
    private var _running = false
    var isRunning: Bool { stateLock.withLock { _running } }
    var currentPhase: Phase { stateLock.withLock { phase } }

    private var _liveTap: CFMachPort?
    /// True only while the event tap exists and the system really has it switched on (not merely "Accessibility granted").
    /// Safe from any thread.
    var isActive: Bool {
        guard let t = stateLock.withLock({ _running ? _liveTap : nil }) else { return false }
        return CGEvent.tapIsEnabled(tap: t)
    }

    // MARK: Lifecycle

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "MaruDoc event tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        guard let rl = runLoop else { thread = nil; return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
            if let mt = self.moveTap { CGEvent.tapEnable(tap: mt, enable: false); CFMachPortInvalidate(mt) }
            if let kt = self.keyTap { CGEvent.tapEnable(tap: kt, enable: false); CFMachPortInvalidate(kt) }
            self.tap = nil; self.moveTap = nil; self.keyTap = nil
            self.stateLock.withLock { self._running = false; self._liveTap = nil }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(rl)
        runLoop = nil
        thread = nil
    }

    private func threadMain() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<PressMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
        }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // Prefer an active tap (can consume events). Fall back to listen-only, where the menu works in click mode.
        if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: callback, userInfo: refcon) {
            tap = t; canModifyEvents = true
        } else if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                            eventsOfInterest: mask, callback: callback, userInfo: refcon) {
            tap = t; canModifyEvents = false
        }
        guard let tap else {
            Log.error("event tap unavailable")
            DispatchQueue.main.async { [weak self] in
                // Allow a later start() (e.g. after Accessibility is granted) to try again.
                self?.thread = nil
                NotificationCenter.default.post(name: .ensoTapFailed, object: nil)
            }
            return
        }
        // Pointer movement is only needed while a menu sits open after release; this tap stays disabled otherwise.
        moveTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                    eventsOfInterest: CGEventMask(1) << CGEventType.mouseMoved.rawValue, callback: callback, userInfo: refcon)
        // Key presses are only needed (for Esc) while a menu is open; this tap also stays disabled otherwise, so
        // MaruDoc does not see typing system-wide.
        keyTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: canModifyEvents ? .defaultTap : .listenOnly,
                                   eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue, callback: callback, userInfo: refcon)
        let rl = CFRunLoopGetCurrent()
        runLoop = rl
        CFRunLoopAddSource(rl, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        if let mt = moveTap {
            CFRunLoopAddSource(rl, CFMachPortCreateRunLoopSource(nil, mt, 0), .commonModes)
            CGEvent.tapEnable(tap: mt, enable: false)
        }
        if let kt = keyTap {
            CFRunLoopAddSource(rl, CFMachPortCreateRunLoopSource(nil, kt, 0), .commonModes)
            CGEvent.tapEnable(tap: kt, enable: false)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        // Health check: the system can switch the tap off without telling us.
        let health = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            Log.info("event tap was disabled; re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        RunLoop.current.add(health, forMode: .common)
        stateLock.withLock { _running = true; _liveTap = tap }
        Log.info("press monitor started (active=\(canModifyEvents))")
        CFRunLoopRun()
    }

    // MARK: Event handling (tap thread)

    private func setPhase(_ p: Phase) {
        let wasOpen = phase == .menu || phase == .sticky
        stateLock.withLock { phase = p }
        let isOpen = p == .menu || p == .sticky
        // Plain pointer movement matters only while a menu is open (some input paths send it instead of drags).
        if let mt = moveTap, wasOpen != isOpen { CGEvent.tapEnable(tap: mt, enable: isOpen) }
        // Same for the keyboard tap (Esc closes the menu).
        if let kt = keyTap, wasOpen != isOpen { CGEvent.tapEnable(tap: kt, enable: isOpen) }
    }

    /// The move and key taps should be on exactly while a menu is open. MaruDoc's own disabling of it is ignored.
    private func reenableMoveTapIfWanted() {
        guard phase == .menu || phase == .sticky else { return }
        if let mt = moveTap, !CGEvent.tapIsEnabled(tap: mt) { CGEvent.tapEnable(tap: mt, enable: true) }
        if let kt = keyTap, !CGEvent.tapIsEnabled(tap: kt) { CGEvent.tapEnable(tap: kt, enable: true) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reenableMoveTapIfWanted()
            // Never stay in a state that swallows events after the system interrupted us.
            if phase != .idle { closeMenu() }
            return pass
        case .tapDisabledByUserInput:
            // Also sent when MaruDoc switches the move tap off itself. The callback does not say which tap it was,
            // so re-enable the main tap if it is off, and the move and key taps only while MaruDoc wants it on.
            if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            reenableMoveTapIfWanted()
            return pass
        default: break
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }
        let loc = event.location
        let swallow: Unmanaged<CGEvent>? = canModifyEvents ? nil : pass
        // Every ordinary click (also Cmd/Shift-clicks and drag selections) may have changed Finder's selection;
        // the tracker reads it later, off this thread. A release that belongs to the radial menu does not count.
        if type == .leftMouseUp, phase == .idle || phase == .pressed { SelectionOrderTracker.shared.noteMouseUp(at: loc) }

        switch (type, phase) {
        case (.leftMouseDown, .idle):
            let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
            let clicks = event.getIntegerValueField(.mouseEventClickState)
            trace("down at \(Int(loc.x)),\(Int(loc.y)) clicks=\(clicks) flags=\(flags.rawValue)")
            guard flags.isEmpty, clicks <= 1 else { return pass }
            setPhase(.pressed)
            pressPoint = loc
            pressTimer?.invalidate()
            pressTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.pressTimerFired() }
            return pass

        case (.leftMouseDragged, .pressed):
            if hypot(loc.x - pressPoint.x, loc.y - pressPoint.y) > slop { cancelPress() }
            return pass

        case (.leftMouseUp, .pressed):
            cancelPress()
            return pass

        case (.leftMouseDragged, .menu):
            pointerMoved(loc)
            return swallow

        case (.mouseMoved, .menu):
            pointerMoved(loc)
            return pass

        case (.leftMouseUp, .menu):
            released(at: loc)
            return swallow

        case (.mouseMoved, .sticky), (.leftMouseDragged, .sticky):
            pointerMoved(loc)
            return pass

        case (.leftMouseDown, .sticky):
            if session?.contains(loc) == true {
                setPhase(.menu)      // the matching mouse-up chooses
                pointerMoved(loc)
                return swallow
            }
            closeMenu()
            return pass

        case (.rightMouseDown, .menu), (.rightMouseDown, .sticky), (.otherMouseDown, .menu), (.otherMouseDown, .sticky):
            closeMenu()
            return pass

        case (.keyDown, .menu), (.keyDown, .sticky):
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { // Esc
                closeMenu()
                return swallow
            }
            return pass

        default:
            return pass
        }
    }

    private func cancelPress() {
        pressTimer?.invalidate(); pressTimer = nil
        setPhase(.idle)
    }

    private func pressTimerFired() {
        pressTimer = nil
        trace("timer fired phase=\(phase)")
        guard phase == .pressed else { return }
        guard CGEventSource.buttonState(.combinedSessionState, button: .left) else { trace("button up"); setPhase(.idle); return }
        let current = CGEvent(source: nil)?.location ?? pressPoint
        guard hypot(current.x - pressPoint.x, current.y - pressPoint.y) <= slop else { trace("moved"); setPhase(.idle); return }

        guard let found = FinderAX.target(at: pressPoint, allowWindows: allowWindows) else { trace("no Finder item"); setPhase(.idle); return }
        let nodes = ActionCatalog.ringMenu(for: found.urls)
        guard !nodes.isEmpty else { setPhase(.idle); return }
        let center = RadialSession.clampedCenter(for: pressPoint)
        let s = RadialSession(nodes: nodes, center: center)
        session = s
        target = found
        setPhase(.menu)
        if canModifyEvents { postSyntheticMouseUp(at: pressPoint) }
        if hypot(center.x - pressPoint.x, center.y - pressPoint.y) > 1 {
            CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
            CGWarpMouseCursorPosition(center)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if found.selectedElements.count > 1 {
            let elements = found.selectedElements
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { FinderAX.restoreSelection(elements) }
        }
        Log.info("radial open items=\(found.urls.count) desktop=\(found.onDesktop)")
        DispatchQueue.main.async { [weak self] in self?.onOpen?(Opened(session: s, target: found)) }
    }

    private func pointerMoved(_ p: CGPoint) {
        guard var s = session else { return }
        let changed = s.move(to: p)
        session = s
        guard changed else { return }
        publish(s)
        dwellTimer?.invalidate(); dwellTimer = nil
        if case .inner(let i) = s.hit, !s.nodes[i].children.isEmpty, s.openParent != i {
            dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
                guard let self, var s = self.session, s.dwell(on: i) else { return }
                self.session = s
                self.publish(s)
            }
        }
    }

    private func publish(_ s: RadialSession) {
        let hit = s.hit, open = s.openParent, sticky = s.sticky
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(hit, open, sticky) }
    }

    private func released(at p: CGPoint) {
        guard var s = session, let t = target else { closeMenu(); return }
        let decision = s.release(at: p)
        session = s
        switch decision {
        case .choose(let action):
            Log.info("radial chose \(action)")
            finish()
            DispatchQueue.main.async { [weak self] in
                self?.onClose?()
                self?.onChoose?(action, t)
            }
        case .keepOpen:
            setPhase(.sticky)
            publish(s)
        case .cancel:
            closeMenu()
        }
    }

    private func finish() {
        dwellTimer?.invalidate(); dwellTimer = nil
        session = nil
        setPhase(.idle)
    }

    private func closeMenu() {
        finish()
        target = nil
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }

    /// Ends Finder's click tracking so it doesn't start dragging the icon.
    private func postSyntheticMouseUp(at p: CGPoint) {
        guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left) else { return }
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        up.post(tap: .cgSessionEventTap)
    }

    /// Closes an open menu from the main thread (e.g. the app is being disabled).
    func cancelFromMain() {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self, self.phase != .idle else { return }
            self.closeMenu()
        }
        CFRunLoopWakeUp(rl)
    }
}

extension Notification.Name {
    static let ensoTapFailed = Notification.Name("EnsoTapFailed")
}
