import Foundation
import IOKit.hidsystem

/// System media keys use a separate namespace from macOS virtual key codes.
/// In particular, NX_KEYTYPE_SOUND_UP is zero, which is also the A key's code.
enum PetMediaKey: UInt16, Sendable {
    case volumeUp = 0x100
    case volumeDown = 0x101
    case mute = 0x107
    case playPause = 0x110
    case nextTrack = 0x111
    case previousTrack = 0x112

    init?(systemKeyType: Int) {
        switch systemKeyType {
        case Int(NX_KEYTYPE_SOUND_UP): self = .volumeUp
        case Int(NX_KEYTYPE_SOUND_DOWN): self = .volumeDown
        case Int(NX_KEYTYPE_MUTE): self = .mute
        case Int(NX_KEYTYPE_PLAY): self = .playPause
        // Apple transport keys can report fast/rewind instead of next/previous.
        case Int(NX_KEYTYPE_NEXT), Int(NX_KEYTYPE_FAST): self = .nextTrack
        case Int(NX_KEYTYPE_PREVIOUS), Int(NX_KEYTYPE_REWIND): self = .previousTrack
        default: return nil
        }
    }

    var token: String {
        switch self {
        case .volumeUp: "volumeup"
        case .volumeDown: "volumedown"
        case .mute: "mute"
        case .playPause: "playpause"
        case .nextTrack: "next"
        case .previousTrack: "previous"
        }
    }
}

/// Adapts macOS virtual key codes to KeyPet's token system.
///
/// All tokens produced here are final tokens: key names are lowercased and every
/// character outside [a-z0-9] is stripped, and every entry below already satisfies
/// that rule, so no further normalization is needed on this side.
enum PetKeyMapping {
    /// macOS virtual key code (kVK_*, decimal) -> base token. Codes absent from the
    /// table resolve to nil, which the state machine treats as unclassified
    /// (alternating paw fallback).
    private static let baseTokens: [UInt16: String] = [
        // ANSI letter keys.
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        // ANSI digit row.
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        // Punctuation (kVK_ANSI_* from HIToolbox Events.h).
        27: "minus", 24: "equals", 33: "openbracket", 30: "closebracket", 42: "backslash",
        41: "semicolon", 39: "quote", 43: "comma", 47: "period", 44: "slash", 50: "backquote",
        // Editing keys. Return is named "enter" and Delete "backspace".
        36: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "escape", 57: "capslock",
        // Left/right modifiers have distinct tokens for dedicated art and paw fallback.
        56: "shift", 60: "rightshift", 59: "control", 62: "rightcontrol",
        58: "option", 61: "rightoption", 55: "command", 54: "rightcommand", 63: "fn",
        // Function keys.
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15",
        106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
        // Navigation cluster and arrows.
        114: "insert", 115: "home", 119: "end", 116: "pageup", 121: "pagedown", 117: "delete",
        126: "up", 125: "down", 123: "left", 124: "right",
        // Numpad. kVK_ANSI_KeypadClear is the numlock-equivalent key and is
        // deliberately unclassified (it alternates left/right).
        65: "numpaddecimal", 67: "numpadmultiply", 69: "numpadplus", 71: "numpadclear",
        75: "numpaddivide", 76: "numpadenter", 78: "numpadminus", 81: "numpadequals",
        82: "numpad0", 83: "numpad1", 84: "numpad2", 85: "numpad3", 86: "numpad4", 87: "numpad5",
        88: "numpad6", 89: "numpad7", 91: "numpad8", 92: "numpad9",
        // Some keyboards emit ordinary virtual key codes for volume controls.
        72: "volumeup", 73: "volumedown", 74: "mute",
        // ISO-only key between left Shift and Z.
        10: "section",
    ]

    /// pet-right partition: QWERT/ASDFG/ZXCVB letters plus B, digits 1-5,
    /// the left hand's editing/modifier keys, F1-F6 and Space. Next/volume up
    /// use this paw so each media pair has opposing actions.
    private static let rightTokens: Set<String> = [
        "q", "w", "e", "r", "t", "a", "s", "d", "f", "g", "z", "x", "c", "v", "b",
        "1", "2", "3", "4", "5",
        "tab", "escape", "capslock", "backquote", "space",
        "shift", "control", "option", "command",
        "f1", "f2", "f3", "f4", "f5", "f6",
        "next", "volumeup",
    ]

    /// pet-left partition: the remaining letters, digits 6-0, everything
    /// numpad-prefixed except numpadclear, navigation/editing keys, the remaining
    /// punctuation, right-side modifiers and F7-F12. Previous/volume down use
    /// this paw; play/pause and mute retain their existing fallback.
    private static let leftTokens: Set<String> = [
        "y", "u", "i", "o", "p", "h", "j", "k", "l", "n", "m",
        "6", "7", "8", "9", "0",
        "enter", "backspace", "delete", "home", "end", "pageup", "pagedown", "insert",
        "up", "down", "left", "right",
        "openbracket", "closebracket", "semicolon", "quote", "comma", "period",
        "slash", "minus", "equals", "backslash",
        "rightshift", "rightcontrol", "rightoption", "rightcommand",
        "f7", "f8", "f9", "f10", "f11", "f12",
        "playpause", "previous", "volumedown", "mute",
        "numpad0", "numpad1", "numpad2", "numpad3", "numpad4",
        "numpad5", "numpad6", "numpad7", "numpad8", "numpad9",
        "numpadplus", "numpadminus", "numpadmultiply", "numpaddivide",
        "numpaddecimal", "numpadequals", "numpadenter",
    ]

    /// nil means the key code has no token mapping.
    static func baseToken(for keyCode: UInt16) -> String? {
        PetMediaKey(rawValue: keyCode)?.token ?? baseTokens[keyCode]
    }

    /// nil means the key is unclassified, so the caller alternates left/right
    /// starting from left.
    static func defaultSide(forBaseToken token: String) -> PawSide? {
        if rightTokens.contains(token) { return .right }
        if leftTokens.contains(token) { return .left }
        return nil
    }
}
