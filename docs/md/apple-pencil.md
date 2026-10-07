# Apple Pencil

On iPad, Apple Pencil works as a precise pointer on the remote desktop with both connection types:

- **Points where it touches.** Pencil always uses direct pointing, even in trackpad mode. It presses immediately (no debounce or long-press wait), drags while touching, and releases when lifted, so drawing, selecting text, and dragging windows land exactly under the tip.
- **Ignores your hand.** While the Pencil is down, finger and palm touches are ignored, and the Pencil never takes part in pinch or two-finger secondary-click gestures. A finger interaction already started when the Pencil lands is released first.
- **Hover.** On iPads with Pencil hover, holding the tip above the screen moves the Mac's pointer.
- **Double-tap and squeeze.** Choose **Settings › Apple Pencil › Double-Tap and Squeeze**: Secondary Click (default) at the hovering tip or the last stroke, Undo (⌘Z), Escape, or Nothing. If the system's Apple Pencil setting says to ignore double-tap or squeeze, Glassy Desk ignores it too.
- **Scribble** works in the "Type to send to the Mac…" field because it is a standard text field.

The Mac receives ordinary pointer events; Pencil pressure and tilt are not sent.

## Implementation

`RemoteDesktopView.ScreenView` routes a `.pencil` touch through the same immediate-press path as hardware pointers and tracks it separately (`pencilTouchActive`), so `touchesMoved`, `touchesEnded`, and `touchesCancelled` follow only the Pencil while it is down. The pinch recognizer allows direct and indirect-pointer touches, and the two-finger tap allows direct touches only. A `UIPencilInteraction` delivers taps and squeezes (phase `.ended`) to `PencilShortcutAction`, which maps each choice to a transport-independent command.

## Verification

`ApplePencilTests` cover immediate pressing and releasing at the touched point in direct and trackpad modes, each double-tap action at the hover location, the cursor fallback, and the stored preference.

Before release, verify on an iPad with Apple Pencil Pro or Apple Pencil (2nd generation):

1. In trackpad mode, draw in a Mac drawing app and drag a window by its title bar with the Pencil while your palm rests on the screen.
2. Hover above a menu and confirm the pointer follows; double-tap and squeeze with each setting.
3. Set the system double-tap action to Ignore and confirm nothing is sent.
4. Use fingers to pinch, scroll, and secondary-click immediately after a Pencil stroke.
