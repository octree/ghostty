import Cocoa

class SideTerminalWindow: NSPanel {
    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func awakeFromNib() {
        super.awakeFromNib()

        self.identifier = .init(rawValue: "com.mitchellh.ghostty.sideTerminal")
        self.setAccessibilitySubrole(.floatingWindow)
        self.styleMask.remove(.titled)
        self.styleMask.insert(.nonactivatingPanel)
    }

    /// This is set to the frame prior to setting `contentView`. This is purely a hack
    /// to workaround bugs in older macOS versions where SwiftUI corrupts the frame.
    var initialFrame: NSRect?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(initialFrame ?? frameRect, display: flag)
    }
}
