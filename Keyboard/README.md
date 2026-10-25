# Keyboard Preference Pane

This preference pane lets you select up to 4 XKB keyboard layouts (each with an optional variant) in a list, using the + and - buttons below it, plus a keyboard type selector for ANSI, ISO or JIS physical layouts. The + button opens a sheet with all available layouts and variants. Changes apply instantly with `setxkbmap`, the selection is saved to user defaults, and a small autostart helper restores it when you log in again. If `sudo -E -A` is available it also attempts to update `/etc/default/keyboard` for system-wide persistence.

## Features

- Select up to 4 keyboard layouts and variants (applied as XKB groups)
- Switch between ANSI, ISO and JIS physical keyboard types
- Optionally swap command key (for Apple keyboards)
- Instant preview with a test text field
- Settings persist across user sessions

## Notes

- Layout and variant data are parsed from `/usr/share/X11/xkb/rules/base.lst` or `/usr/local/share/X11/xkb/rules/base.lst` (e.g., for FreeBSD); a small fallback list is used if neither file is found.
- Keyboard type is stored in user defaults and affects the XKBMODEL setting (pc104 for ANSI, pc105 for ISO, pc106 for JIS).
- If the "Apple keyboard" checkbox is checked the preference pane will use Apple keyboard models (`applealu_ansi`, `applealu_iso`, `applealu_jis`) instead of PC models.
- User-level persistence lives in `~/.local/bin/gershwin-apply-keyboard.sh`.
- System-wide persistence uses `/etc/default/keyboard` and requires `sudo -E -A`.
- The selected layouts are stored as `inputSources` (layout, variant, name) in the `KeyboardPreferences` domain, in XKB group order.

## Apple ISO Keyboard Fix

Apple ISO keyboards have a hardware difference compared to standard PC ISO keyboards: two keys are physically swapped.

**The Problem:**

On PC ISO keyboards:
- Top-left key (keycode 49, TLDE): `^` circumflex
- Left-of-Z key (keycode 94, LSGT): `<` less-than
  
On Apple ISO keyboards:
- Top-left key (same keycode 49): physically has `<` printed on it
- Left-of-Z key (same keycode 94): physically has `^` printed on it

The XKB `applealu_iso` model correctly identifies Apple keyboards but does **not** remap these keycodes, causing the symbols to appear wrong regardless of the layout or checkbox state.

**The Solution:**

When all of the following conditions are true:
1. "Apple keyboard" checkbox is checked
2. Keyboard type is set to "ISO"
3. Only one layout is selected

The preference pane generates an autostart script that:
1. Configures the keyboard layout with `setxkbmap`
2. Uses `xmodmap` to swap the symbol mappings for keycodes 49 and 94

This ensures the symbols match the physical key labels on Apple ISO keyboards.

With several layouts selected the fix is not applied, because the xmodmap commands would overwrite the symbols of every layout (XKB group).

**Technical Details:**
- Keycode 49 (TLDE) is remapped to produce: `< >` (less/greater)
- Keycode 94 (LSGT) is remapped to produce: `^ °` (circumflex/degree)
- The fix is automatically applied in the generated `~/.local/bin/gershwin-apply-keyboard.sh` script
- The xmodmap commands are safe and only execute if xmodmap is available