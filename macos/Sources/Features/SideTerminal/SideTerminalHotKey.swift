import Carbon
import Cocoa
import GhosttyKit

/// Registers a system-wide hotkey using Carbon's RegisterEventHotKey API.
/// Unlike CGEvent taps, Carbon hotkeys are registered directly with the
/// Window Server and work in ALL apps (same mechanism as Alfred/Spotlight).
class SideTerminalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let callback: () -> Void

    /// The unique hotkey ID for this registration.
    private static let hotKeyID = EventHotKeyID(
        signature: OSType(0x5354_484B), // "STHK"
        id: 1
    )

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        register(keyCode: keyCode, modifiers: modifiers)
    }

    deinit {
        unregister()
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        // Install event handler for hotkey events
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        // Register the hotkey
        var hotKeyID = Self.hotKeyID
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    fileprivate func handleHotKey() {
        callback()
    }

    // MARK: - Key Code Conversion

    /// Convert a Ghostty key string (e.g. "grave_accent") to a Carbon virtual key code.
    static func carbonKeyCode(from keyEquivalent: String) -> UInt32? {
        // Map common key names to Carbon virtual key codes
        let map: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
            "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
            "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
            "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
            "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
            "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
            "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
            "9": UInt32(kVK_ANSI_9),
            "`": UInt32(kVK_ANSI_Grave), "grave_accent": UInt32(kVK_ANSI_Grave),
            "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal),
            "[": UInt32(kVK_ANSI_LeftBracket), "]": UInt32(kVK_ANSI_RightBracket),
            "\\": UInt32(kVK_ANSI_Backslash), ";": UInt32(kVK_ANSI_Semicolon),
            "'": UInt32(kVK_ANSI_Quote), ",": UInt32(kVK_ANSI_Comma),
            ".": UInt32(kVK_ANSI_Period), "/": UInt32(kVK_ANSI_Slash),
            "space": UInt32(kVK_Space), "return": UInt32(kVK_Return),
            "tab": UInt32(kVK_Tab), "escape": UInt32(kVK_Escape),
            "delete": UInt32(kVK_Delete), "backspace": UInt32(kVK_Delete),
            "f1": UInt32(kVK_F1), "f2": UInt32(kVK_F2), "f3": UInt32(kVK_F3),
            "f4": UInt32(kVK_F4), "f5": UInt32(kVK_F5), "f6": UInt32(kVK_F6),
            "f7": UInt32(kVK_F7), "f8": UInt32(kVK_F8), "f9": UInt32(kVK_F9),
            "f10": UInt32(kVK_F10), "f11": UInt32(kVK_F11), "f12": UInt32(kVK_F12),
        ]
        return map[keyEquivalent.lowercased()]
    }

    /// Convert a Ghostty physical key enum to Carbon virtual key code.
    static func carbonKeyCode(fromGhosttyKey key: ghostty_input_key_e) -> UInt32? {
        switch key {
        case GHOSTTY_KEY_BACKQUOTE:     return UInt32(kVK_ANSI_Grave)
        case GHOSTTY_KEY_A:             return UInt32(kVK_ANSI_A)
        case GHOSTTY_KEY_B:             return UInt32(kVK_ANSI_B)
        case GHOSTTY_KEY_C:             return UInt32(kVK_ANSI_C)
        case GHOSTTY_KEY_D:             return UInt32(kVK_ANSI_D)
        case GHOSTTY_KEY_E:             return UInt32(kVK_ANSI_E)
        case GHOSTTY_KEY_F:             return UInt32(kVK_ANSI_F)
        case GHOSTTY_KEY_G:             return UInt32(kVK_ANSI_G)
        case GHOSTTY_KEY_H:             return UInt32(kVK_ANSI_H)
        case GHOSTTY_KEY_I:             return UInt32(kVK_ANSI_I)
        case GHOSTTY_KEY_J:             return UInt32(kVK_ANSI_J)
        case GHOSTTY_KEY_K:             return UInt32(kVK_ANSI_K)
        case GHOSTTY_KEY_L:             return UInt32(kVK_ANSI_L)
        case GHOSTTY_KEY_M:             return UInt32(kVK_ANSI_M)
        case GHOSTTY_KEY_N:             return UInt32(kVK_ANSI_N)
        case GHOSTTY_KEY_O:             return UInt32(kVK_ANSI_O)
        case GHOSTTY_KEY_P:             return UInt32(kVK_ANSI_P)
        case GHOSTTY_KEY_Q:             return UInt32(kVK_ANSI_Q)
        case GHOSTTY_KEY_R:             return UInt32(kVK_ANSI_R)
        case GHOSTTY_KEY_S:             return UInt32(kVK_ANSI_S)
        case GHOSTTY_KEY_T:             return UInt32(kVK_ANSI_T)
        case GHOSTTY_KEY_U:             return UInt32(kVK_ANSI_U)
        case GHOSTTY_KEY_V:             return UInt32(kVK_ANSI_V)
        case GHOSTTY_KEY_W:             return UInt32(kVK_ANSI_W)
        case GHOSTTY_KEY_X:             return UInt32(kVK_ANSI_X)
        case GHOSTTY_KEY_Y:             return UInt32(kVK_ANSI_Y)
        case GHOSTTY_KEY_Z:             return UInt32(kVK_ANSI_Z)
        case GHOSTTY_KEY_DIGIT_0:       return UInt32(kVK_ANSI_0)
        case GHOSTTY_KEY_DIGIT_1:       return UInt32(kVK_ANSI_1)
        case GHOSTTY_KEY_DIGIT_2:       return UInt32(kVK_ANSI_2)
        case GHOSTTY_KEY_DIGIT_3:       return UInt32(kVK_ANSI_3)
        case GHOSTTY_KEY_DIGIT_4:       return UInt32(kVK_ANSI_4)
        case GHOSTTY_KEY_DIGIT_5:       return UInt32(kVK_ANSI_5)
        case GHOSTTY_KEY_DIGIT_6:       return UInt32(kVK_ANSI_6)
        case GHOSTTY_KEY_DIGIT_7:       return UInt32(kVK_ANSI_7)
        case GHOSTTY_KEY_DIGIT_8:       return UInt32(kVK_ANSI_8)
        case GHOSTTY_KEY_DIGIT_9:       return UInt32(kVK_ANSI_9)
        case GHOSTTY_KEY_MINUS:         return UInt32(kVK_ANSI_Minus)
        case GHOSTTY_KEY_EQUAL:         return UInt32(kVK_ANSI_Equal)
        case GHOSTTY_KEY_BRACKET_LEFT:  return UInt32(kVK_ANSI_LeftBracket)
        case GHOSTTY_KEY_BRACKET_RIGHT: return UInt32(kVK_ANSI_RightBracket)
        case GHOSTTY_KEY_BACKSLASH:     return UInt32(kVK_ANSI_Backslash)
        case GHOSTTY_KEY_SEMICOLON:     return UInt32(kVK_ANSI_Semicolon)
        case GHOSTTY_KEY_QUOTE:         return UInt32(kVK_ANSI_Quote)
        case GHOSTTY_KEY_COMMA:         return UInt32(kVK_ANSI_Comma)
        case GHOSTTY_KEY_PERIOD:        return UInt32(kVK_ANSI_Period)
        case GHOSTTY_KEY_SLASH:         return UInt32(kVK_ANSI_Slash)
        case GHOSTTY_KEY_SPACE:         return UInt32(kVK_Space)
        case GHOSTTY_KEY_ENTER:         return UInt32(kVK_Return)
        case GHOSTTY_KEY_TAB:           return UInt32(kVK_Tab)
        case GHOSTTY_KEY_BACKSPACE:     return UInt32(kVK_Delete)
        default:                        return nil
        }
    }

    /// Convert modifier strings to Carbon modifier mask.
    static func carbonModifiers(cmd: Bool = false, shift: Bool = false,
                                 alt: Bool = false, ctrl: Bool = false) -> UInt32 {
        var mods: UInt32 = 0
        if cmd   { mods |= UInt32(cmdKey) }
        if shift { mods |= UInt32(shiftKey) }
        if alt   { mods |= UInt32(optionKey) }
        if ctrl  { mods |= UInt32(controlKey) }
        return mods
    }
}

/// Carbon event handler callback.
private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<SideTerminalHotKey>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        hotKey.handleHotKey()
    }
    return noErr
}
