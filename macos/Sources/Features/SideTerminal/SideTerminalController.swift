import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// A SideNotes-like terminal anchored to the right (or left) edge of the screen.
///
/// Two display states, toggled via `toggle_side_terminal`:
///   visible ↔ hidden
///
/// When visible and unfocused, the background and text opacity transition to
/// their configured unfocused values. See the `side-terminal-*` configuration
/// options for details.
class SideTerminalController: BaseTerminalController {
    override var windowNibName: NSNib.Name? { "SideTerminal" }

    /// Whether the side terminal is currently on screen.
    private(set) var visible: Bool = false

    // MARK: - State

    /// The width to use when animating in. Updated on manual resize.
    private var expandedWidth: CGFloat = 0

    /// The previously running application when the terminal is shown.
    private var previousApp: NSRunningApplication?

    /// True while a frame animation is in progress, suppresses geometry saves.
    private var isAnimating: Bool = false

    /// The configuration derived from the Ghostty config.
    private var derivedConfig: DerivedConfig

    // MARK: - Constants

    private let sideWidthFraction: CGFloat = 0.25
    private let animationDuration: Double = 0.2

    // MARK: - Geometry Persistence

    private static let savedGeometryKey = "SideTerminalGeometry"

    /// Saved geometry encoded as screen-edge margins so it adapts to different
    /// screen sizes (e.g. switching between laptop and external monitor).
    private struct SavedGeometry: Codable {
        let width: CGFloat
        let topMargin: CGFloat
        let bottomMargin: CGFloat
    }

    // MARK: - Init

    init(_ ghostty: Ghostty.App) {
        self.derivedConfig = DerivedConfig(ghostty.config)
        super.init(ghostty, baseConfig: nil, surfaceTree: .init())

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(ghosttyConfigDidChange(_:)),
                           name: .ghosttyConfigDidChange, object: nil)
        center.addObserver(self, selector: #selector(closeWindow(_:)),
                           name: .ghosttyCloseWindow, object: nil)
        center.addObserver(self, selector: #selector(onNewTab),
                           name: Ghostty.Notification.ghosttyNewTab, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - NSWindowController

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window = self.window else { return }

        window.delegate = self
        window.isRestorable = false
        window.minSize = NSSize(width: 100, height: 100)
        syncAppearance()

        // Restore saved geometry or compute defaults.
        let geo = Self.loadGeometry()
        if let screen = NSScreen.main {
            expandedWidth = geo?.width ?? (screen.visibleFrame.width * sideWidthFraction)
            window.setFrame(sideFrame(on: screen, geometry: geo), display: false)
        }

        // Workaround for SwiftUI frame corruption on older macOS: hold the
        // frame steady while the hosting view is attached.
        if let w = window as? SideTerminalWindow { w.initialFrame = window.frame }
        let container = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
        }
        container.initialContentSize = window.frame.size
        window.contentView = container
        if let w = window as? SideTerminalWindow { w.initialFrame = nil }
    }

    // MARK: - NSWindowDelegate

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        guard visible else { return }
        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: true)
        restoreFocusedAppearance()
    }

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)
        guard visible else { return }
        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: false)
        guard window?.attachedSheet == nil else { return }
        if NSApp.isActive { self.previousApp = nil }
        applyUnfocusedAppearance()
    }

    override func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window, visible, !isAnimating else { return }
        expandedWidth = window.frame.width
        saveGeometry()
    }

    override func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window, visible, !isAnimating else { return }
        saveGeometry()
    }

    // MARK: - Base Controller Overrides

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)
        if to.isEmpty { animateOut(); return }
        if !from.isEmpty && !visible { animateIn() }
    }

    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }
        guard case .leaf(let surface) = node else {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }
        if surface.processExited { surfaceTree = .init(); return }
        animateOut()
    }

    // MARK: - Toggle

    func toggle() {
        if visible { animateOut() } else { animateIn() }
    }

    // MARK: - Frame Helpers

    private var isLeftSide: Bool { derivedConfig.position == .left }

    private func sideFrame(on screen: NSScreen, geometry: SavedGeometry? = nil) -> NSRect {
        let sv = screen.visibleFrame
        let geo = geometry ?? Self.loadGeometry()

        var w = expandedWidth > 0 ? expandedWidth : sv.width * sideWidthFraction
        w = min(w, sv.width)

        var y = sv.minY
        var h = sv.height

        if let geo {
            h = max(200, sv.height - geo.topMargin - geo.bottomMargin)
            y = sv.minY + geo.bottomMargin
            y = max(sv.minY, min(y, sv.maxY - h))
        }

        let x = isLeftSide ? sv.minX : sv.maxX - w
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func offscreenFrame(for window: NSWindow, on screen: NSScreen) -> NSRect {
        let x = isLeftSide
            ? screen.visibleFrame.minX - window.frame.width
            : screen.visibleFrame.maxX
        return NSRect(x: x, y: window.frame.minY,
                      width: window.frame.width, height: window.frame.height)
    }

    // MARK: - Animations

    private func animateIn() {
        guard let window = self.window else { return }
        guard !visible else { return }
        visible = true

        NotificationCenter.default.post(
            name: .sideTerminalDidChangeVisibility, object: self)

        savePreviousApp()
        ensureSurfaceTree()
        guard let screen = NSScreen.main else { return }

        let geo = Self.loadGeometry()
        if expandedWidth <= 0 {
            expandedWidth = geo?.width ?? (screen.visibleFrame.width * sideWidthFraction)
        }

        let target = sideFrame(on: screen, geometry: geo)
        terminalViewContainer?.initialContentSize = target.size

        // Position offscreen at the correct size before showing.
        let startX = isLeftSide
            ? screen.visibleFrame.minX - target.width
            : screen.visibleFrame.maxX
        window.setFrame(NSRect(x: startX, y: target.minY,
                               width: target.width, height: target.height), display: false)
        window.alphaValue = 0
        window.level = .popUpMenu

        // Defer ordering to avoid SwiftUI layout fighting the frame.
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
        }

        animate(frame: target, alpha: 1) {
            guard self.visible else { return }

            // Lower to floating so IME candidate windows render above us.
            window.level = .floating
            self.terminalViewContainer?.initialContentSize = nil
            self.syncAppearance()
            self.makeWindowKey(window)
            self.activateAppIfNeeded(window)
        }
    }

    private func animateOut() {
        guard let window = self.window else { return }
        guard visible else { return }
        visible = false

        NotificationCenter.default.post(
            name: .sideTerminalDidChangeVisibility, object: self)

        saveGeometry()
        restorePreviousApp()
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.level = .popUpMenu

        animate(frame: offscreenFrame(for: window, on: screen), alpha: 0) {
            window.orderOut(self)
        }
    }

    private func animate(frame: NSRect, alpha: CGFloat, completion: @escaping () -> Void) {
        guard let window = self.window else { return }
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = .init(name: .easeIn)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = alpha
        }, completionHandler: {
            self.isAnimating = false
            DispatchQueue.main.async(execute: completion)
        })
    }

    // MARK: - Focus / Unfocus Appearance

    private func applyUnfocusedAppearance() {
        guard let window = self.window else { return }

        updateSurfaceBackground(
            opacity: derivedConfig.unfocusedBackgroundOpacity,
            color: derivedConfig.unfocusedBackgroundColor
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = .init(name: .easeIn)
            window.animator().alphaValue = CGFloat(derivedConfig.unfocusedTextOpacity)
        }
    }

    private func restoreFocusedAppearance() {
        guard let window = self.window else { return }

        let focusedOpacity = derivedConfig.focusedBackgroundOpacity > 0
            ? derivedConfig.focusedBackgroundOpacity
            : derivedConfig.backgroundOpacity
        updateSurfaceBackground(
            opacity: focusedOpacity,
            color: derivedConfig.focusedBackgroundColor
        )

        window.hasShadow = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = .init(name: .easeIn)
            window.animator().alphaValue = CGFloat(derivedConfig.focusedTextOpacity)
        }
        syncAppearance()
    }

    /// Clone the current config with modified background opacity/color and
    /// apply to all surfaces in this controller.
    private func updateSurfaceBackground(opacity: Double, color: NSColor?) {
        guard let cfg = ghostty_config_clone(ghostty.config.config!) else { return }
        defer { ghostty_config_free(cfg) }

        ghostty_config_set_background_opacity(cfg, opacity)
        if let color {
            let c = color.usingColorSpace(.sRGB) ?? color
            ghostty_config_set_background(
                cfg,
                UInt8(c.redComponent * 255),
                UInt8(c.greenComponent * 255),
                UInt8(c.blueComponent * 255))
        }

        for surface in surfaceTree {
            ghostty_surface_update_config(surface.surface!, cfg)
        }
    }

    // MARK: - Geometry Persistence

    private func saveGeometry() {
        guard visible, !isAnimating,
              let window = self.window,
              let screen = window.screen,
              window.isVisible,
              window.frame.width > 100, window.frame.height > 100 else { return }

        let sv = screen.visibleFrame
        let topMargin = sv.maxY - window.frame.maxY
        let bottomMargin = window.frame.minY - sv.minY

        guard topMargin >= 0, bottomMargin >= 0,
              topMargin + bottomMargin < sv.height - 200 else { return }

        let geo = SavedGeometry(width: window.frame.width,
                                topMargin: topMargin, bottomMargin: bottomMargin)
        if let data = try? JSONEncoder().encode(geo) {
            UserDefaults.standard.set(data, forKey: Self.savedGeometryKey)
        }
    }

    private static func loadGeometry() -> SavedGeometry? {
        guard let data = UserDefaults.standard.data(forKey: savedGeometryKey) else { return nil }
        return try? JSONDecoder().decode(SavedGeometry.self, from: data)
    }

    // MARK: - Helpers

    private func savePreviousApp() {
        guard !NSApp.isActive,
              let prev = NSWorkspace.shared.frontmostApplication,
              prev.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        self.previousApp = prev
    }

    private func restorePreviousApp() {
        guard let prev = self.previousApp, !prev.isTerminated else {
            previousApp = nil
            return
        }
        _ = prev.activate(options: [])
        previousApp = nil
    }

    private func ensureSurfaceTree() {
        guard surfaceTree.isEmpty, let app = ghostty.app else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables["GHOSTTY_SIDE_TERMINAL"] = "1"
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        surfaceTree = SplitTree(view: view)
        focusedSurface = view
    }

    /// Attempt to make the window key, supporting retries if necessary.
    private func makeWindowKey(_ window: NSWindow, retries: UInt8 = 0) {
        guard visible,
              let focusedSurface, focusedSurface.window == window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(focusedSurface)
        guard !window.isKeyWindow, retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) {
            self.makeWindowKey(window, retries: retries - 1)
        }
    }

    private func activateAppIfNeeded(_ window: NSWindow) {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            guard !window.isKeyWindow else { return }
            self.makeWindowKey(window, retries: 10)
        }
    }

    // MARK: - Appearance

    override func syncAppearance() {
        guard let window else { return }
        defer { updateColorSchemeForSurfaceTree() }
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard window.isVisible else { return }

        // The side terminal may need transparency even when the global
        // background-opacity is 1, if the focused opacity override is set.
        let effectiveOpacity = derivedConfig.focusedBackgroundOpacity > 0
            ? derivedConfig.focusedBackgroundOpacity
            : derivedConfig.backgroundOpacity
        let needsTransparency = !isBackgroundOpaque
            && (effectiveOpacity < 1 || derivedConfig.backgroundBlur.isGlassStyle)

        if needsTransparency {
            window.isOpaque = false
            window.backgroundColor = .white.withAlphaComponent(0.001)
            if !derivedConfig.backgroundBlur.isGlassStyle {
                ghostty_set_window_background_blur(
                    ghostty.app, Unmanaged.passUnretained(window).toOpaque())
            }
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
        terminalViewContainer?.ghosttyConfigDidChange(ghostty.config, preferredBackgroundColor: nil)
    }

    // MARK: - First Responder

    @IBAction override func closeWindow(_ sender: Any) { animateOut() }

    @IBAction func toggleSideTerminal(_ sender: Any) { toggle() }

    @IBAction func newTab(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Cannot Create New Tab"
        alert.informativeText = "Tabs aren't supported in the Side Terminal."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    // MARK: - Notifications

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        guard notification.object == nil,
              let config = notification.userInfo?[
                  Notification.Name.GhosttyConfigChangeKey
              ] as? Ghostty.Config else { return }
        self.derivedConfig = DerivedConfig(config)
        syncAppearance()
        terminalViewContainer?.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
    }

    @objc private func onNewTab(notification: SwiftUI.Notification) {
        guard let sv = notification.object as? Ghostty.SurfaceView,
              sv.window?.windowController is SideTerminalController else { return }
        self.newTab(nil)
    }

    // MARK: - DerivedConfig

    private struct DerivedConfig {
        let position: Ghostty.Config.SideTerminalPosition
        let backgroundOpacity: Double
        let backgroundBlur: Ghostty.Config.BackgroundBlur

        let focusedBackgroundOpacity: Double
        let focusedBackgroundColor: NSColor?
        let focusedTextOpacity: Double

        let unfocusedBackgroundOpacity: Double
        let unfocusedBackgroundColor: NSColor?
        let unfocusedTextOpacity: Double

        init() {
            self.position = .right
            self.backgroundOpacity = 1.0
            self.backgroundBlur = .disabled
            self.focusedBackgroundOpacity = 0
            self.focusedBackgroundColor = nil
            self.focusedTextOpacity = 1.0
            self.unfocusedBackgroundOpacity = 0.0
            self.unfocusedBackgroundColor = nil
            self.unfocusedTextOpacity = 0.75
        }

        init(_ config: Ghostty.Config) {
            self.position = config.sideTerminalPosition
            self.backgroundOpacity = config.backgroundOpacity
            self.backgroundBlur = config.backgroundBlur
            self.focusedBackgroundOpacity = config.sideTerminalFocusedBackgroundOpacity
            self.focusedBackgroundColor = config.sideTerminalFocusedBackgroundColor
            self.focusedTextOpacity = config.sideTerminalFocusedTextOpacity
            self.unfocusedBackgroundOpacity = config.sideTerminalUnfocusedBackgroundOpacity
            self.unfocusedBackgroundColor = config.sideTerminalUnfocusedBackgroundColor
            self.unfocusedTextOpacity = config.sideTerminalUnfocusedTextOpacity
        }
    }
}

extension Notification.Name {
    static let sideTerminalDidChangeVisibility = Notification.Name(
        "com.mitchellh.ghostty.sideTerminalDidChangeVisibility")
}
