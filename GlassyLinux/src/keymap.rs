//! Maps SDL keycodes to the X11/RFB keysyms Glassy Desk for Mac accepts.
//!
//! Printable keys send their unshifted keysym; the host combines them with the
//! modifier keysyms it has seen pressed (Shift, Control, Option, Command), just
//! like a VNC client. Super maps to Command and Alt maps to Option.

use sdl2::keyboard::Keycode;

pub const SHIFT_L: u32 = 0xFFE1;
pub const CONTROL_L: u32 = 0xFFE3;
pub const META_L: u32 = 0xFFE7; // Command on the host
pub const SUPER_L: u32 = 0xFFEB; // Command on the host
pub const ALT_L: u32 = 0xFFE9; // Option on the host

#[derive(Clone, Copy, Default)]
pub struct Options {
    /// Send Linux Control as Command (and Super as Control), for users who
    /// prefer PC-style Ctrl+C / Ctrl+V to act as Mac shortcuts.
    pub ctrl_as_command: bool,
}

pub fn keysym(keycode: Keycode, options: Options) -> Option<u32> {
    let code = keycode.into_i32();
    // SDL keycodes for printable keys are the (layout-mapped) unshifted
    // Unicode character, which equals the X11 keysym in the ASCII range.
    if (0x20..=0x7E).contains(&code) {
        return Some(code as u32);
    }

    let keysym = match keycode {
        Keycode::RETURN | Keycode::RETURN2 => 0xFF0D,
        Keycode::ESCAPE => 0xFF1B,
        Keycode::BACKSPACE => 0xFF08,
        Keycode::TAB => 0xFF09,
        Keycode::DELETE => 0xFFFF,
        Keycode::INSERT | Keycode::HELP => 0xFF63,
        Keycode::HOME => 0xFF50,
        Keycode::END => 0xFF57,
        Keycode::PAGEUP => 0xFF55,
        Keycode::PAGEDOWN => 0xFF56,
        Keycode::LEFT => 0xFF51,
        Keycode::UP => 0xFF52,
        Keycode::RIGHT => 0xFF53,
        Keycode::DOWN => 0xFF54,
        Keycode::F1 => 0xFFBE,
        Keycode::F2 => 0xFFBF,
        Keycode::F3 => 0xFFC0,
        Keycode::F4 => 0xFFC1,
        Keycode::F5 => 0xFFC2,
        Keycode::F6 => 0xFFC3,
        Keycode::F7 => 0xFFC4,
        Keycode::F8 => 0xFFC5,
        Keycode::F9 => 0xFFC6,
        Keycode::F10 => 0xFFC7,
        Keycode::F11 => 0xFFC8,
        Keycode::F12 => 0xFFC9,
        Keycode::F13 => 0xFFCA,
        Keycode::F14 => 0xFFCB,
        Keycode::F15 => 0xFFCC,
        Keycode::F16 => 0xFFCD,
        Keycode::F17 => 0xFFCE,
        Keycode::F18 => 0xFFCF,
        Keycode::F19 => 0xFFD0,
        Keycode::F20 => 0xFFD1,
        Keycode::KP_ENTER => 0xFF8D,
        Keycode::KP_MULTIPLY => 0xFFAA,
        Keycode::KP_PLUS => 0xFFAB,
        Keycode::KP_MINUS => 0xFFAD,
        Keycode::KP_PERIOD => 0xFFAE,
        Keycode::KP_DIVIDE => 0xFFAF,
        Keycode::KP_0 => 0xFFB0,
        Keycode::KP_1 => 0xFFB1,
        Keycode::KP_2 => 0xFFB2,
        Keycode::KP_3 => 0xFFB3,
        Keycode::KP_4 => 0xFFB4,
        Keycode::KP_5 => 0xFFB5,
        Keycode::KP_6 => 0xFFB6,
        Keycode::KP_7 => 0xFFB7,
        Keycode::KP_8 => 0xFFB8,
        Keycode::KP_9 => 0xFFB9,
        Keycode::KP_EQUALS => '=' as u32,
        Keycode::CAPSLOCK => 0xFFE5,
        Keycode::LSHIFT => SHIFT_L,
        Keycode::RSHIFT => 0xFFE2,
        Keycode::LCTRL if options.ctrl_as_command => META_L,
        Keycode::RCTRL if options.ctrl_as_command => 0xFFE8,
        Keycode::LGUI if options.ctrl_as_command => CONTROL_L,
        Keycode::RGUI if options.ctrl_as_command => 0xFFE4,
        Keycode::LCTRL => CONTROL_L,
        Keycode::RCTRL => 0xFFE4,
        Keycode::LGUI => SUPER_L,
        Keycode::RGUI => 0xFFEC,
        Keycode::LALT => ALT_L,
        Keycode::RALT => 0xFFEA,
        _ => {
            // Non-ASCII characters from international layouts are sent as
            // Unicode keysyms, which the host types directly.
            let scancode_mask = 1 << 30;
            if code > 0x7F && code & scancode_mask == 0 && char::from_u32(code as u32).is_some() {
                return Some(0x0100_0000 | code as u32);
            }
            return None;
        }
    };
    Some(keysym)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn printable_and_special_keys() {
        let o = Options::default();
        assert_eq!(keysym(Keycode::A, o), Some(0x61));
        assert_eq!(keysym(Keycode::NUM_1, o), Some(0x31));
        assert_eq!(keysym(Keycode::RETURN, o), Some(0xFF0D));
        assert_eq!(keysym(Keycode::LGUI, o), Some(SUPER_L));
        assert_eq!(keysym(Keycode::LCTRL, Options { ctrl_as_command: true }), Some(META_L));
    }
}
