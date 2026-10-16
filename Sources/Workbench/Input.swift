import AppKit
@preconcurrency import GhosttyKit

extension NSEvent {
    /// Create a Ghostty key event for a given keyboard action.
    ///
    /// This will not set the "text" or "composing" fields since these can't safely be set
    /// with the information or lifetimes given.
    ///
    /// The translationMods should be set to the modifiers used for actual character
    /// translation if available.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key_ev: ghostty_input_key_s = .init()
        key_ev.action = action
        key_ev.keycode = UInt32(keyCode)

        // We can't infer or set these safely from this method. Since text is
        // a cString, we can't use self.characters because of garbage collection.
        // We have to let the caller handle this.
        key_ev.text = nil
        key_ev.composing = false

        // macOS provides no easy way to determine the consumed modifiers for
        // producing text. We apply a simple heuristic here that has worked for years
        // so far: control and command never contribute to the translation of text,
        // assume everything else did.
        key_ev.mods = GhosttyInput.ghosttyMods(modifierFlags)
        key_ev.consumed_mods = GhosttyInput.ghosttyMods(
            (translationMods ?? modifierFlags)
                .subtracting([.control, .command]))

        // Our unshifted codepoint is the codepoint with no modifiers. We
        // ignore multi-codepoint values. We have to use `byApplyingModifiers`
        // instead of `charactersIgnoringModifiers` because the latter changes
        // behavior with ctrl pressed and we don't want any of that.
        key_ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key_ev.unshifted_codepoint = codepoint.value
            }
        }

        return key_ev
    }

    /// Returns the text to set for a key event for Ghostty.
    ///
    /// This namely contains logic to avoid control characters, since we handle control character
    /// mapping manually within Ghostty.
    var ghosttyCharacters: String? {
        // If we have no characters associated with this event we do nothing.
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            // If we have a single control character, then we return the characters
            // without control pressed. We do this because we handle control character
            // encoding directly within Ghostty's KeyEncoder.
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            // If we have a single value in the PUA, then it's a function key and
            // we don't want to send PUA ranges down to Ghostty.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}

enum GhosttyInput {
    /// Returns the event modifier flags set for the Ghostty mods enum.
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// Translate event modifier flags to a ghostty mods enum.
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // Handle sided input. We can't tell that both are pressed in the
        // Ghostty structure but that's okay -- we don't use that information.
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    static func mouseButton(_ event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    /// Packed bitmask: bit 0 = precision, bits 1..3 = momentum.
    static func scrollMods(precision: Bool, momentum: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var value: Int32 = 0
        if precision { value |= 0b0000_0001 }
        let m: Int32
        switch momentum {
        case .began: m = 1
        case .stationary: m = 2
        case .changed: m = 3
        case .ended: m = 4
        case .cancelled: m = 5
        case .mayBegin: m = 6
        default: m = 0
        }
        value |= m << 1
        return value
    }
}
