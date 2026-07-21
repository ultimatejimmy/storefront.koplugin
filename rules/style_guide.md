---
trigger: always_on
---

# Storefront Plugin UI Style Guide

This style guide establishes consistent layout, typography, borders, and colors for all dialogs, cards, popups, and UI widgets in the Storefront plugin. It defines reusable design tokens from `storefront_theme.lua` and KOReader UI widgets.

---

## 1. Design System & Theme Tokens

Always reference design tokens from `storefront_theme` and `Screen:scaleBySize(val)` (aliased as `sc(val)`) to maintain visual consistency across all e-ink screen sizes and DPIs:

| Token / Property | Reference Value | Description / Usage |
|---|---|---|
| `sc(val)` | `Device.screen:scaleBySize(val)` | Scales pixel sizes dynamically to device DPI |
| `color_bg` | `Blitbuffer.COLOR_WHITE` | Card and modal background color |
| `color_border` | `Blitbuffer.COLOR_BLACK` | Main high-contrast border color |
| `color_label_dim` | `Blitbuffer.Color8(120)` | Faded/secondary text labels and subtitles |
| `border_line_h` | `sc(1)` | Divider line thickness (`LineWidget`) |
| `border_window` | `sc(2)` | Card window border thickness |
| `border_btn` | `sc(2)` | Selected option / button border thickness |
| `radius_window` | `sc(12)` | Rounded corner radius for modals & cards |
| `radius_btn` | `sc(18)` | Pill/button corner radius |
| `gap` | `sc(8)` | Standard vertical/horizontal spacing |
| `face_label_size` | `16` | Standard body / row font size (`cfont`) |
| `title_font_size` | `18` | Section & modal header font size (`cfont`) |

---

## 2. Modal Card Layout

Storefront uses a clean, single-border modal card container (`bordersize = sc(2)`) with rounded corners (`radius = sc(12)`):

```lua
local card = FrameContainer:new{
    padding = 0,
    radius = storefront_theme.radius_window, -- sc(12)
    bordersize = storefront_theme.border_window, -- sc(2)
    color = Blitbuffer.COLOR_BLACK,
    background = storefront_theme.color_bg,
    width = dialog_w,
    content_vg
}

local overlay = InputContainer:new{
    align = "center",
    vertical_align = "center",
    dimen = Geom:new{ w = sw, h = sh },
    key_events = {
        Close = { { "Back" } }
    },
    card
}
```

---

## 3. Option Picker / Radio Button Groups

Radio button groups and single-select pickers use structured horizontal rows with visual selection indicators:

### Visual Indicators
- **Selected**: Solid border (`bordersize = sc(2)`), solid bullet indicator (`●`).
- **Unselected**: Light gray border (`bordersize = sc(1)`), empty circle indicator (`○`).

### Layout & Hit-Testing Rules
1. Use `TextBoxWidget` for option text labels (constrained width `dialog_w - sc(72)`) to allow text wrapping for translations without clipping.
2. Measure hit-testing regions using explicit `GestureRange` with `getSize()` or `dimen` bounding boxes:
```lua
local item = InputContainer:new{ frame }
local row_size = frame:getSize() or { w = dialog_w - sc(4), h = 0 }
item.ges_events = {
    Tap = {
        GestureRange:new{
            ges = "tap",
            range = function()
                local dim = item.dimen
                if not dim then
                    return Geom:new{ x = -1, y = -1, w = 1, h = 1 }
                end
                return Geom:new{
                    x = dim.x or 0,
                    y = dim.y or 0,
                    w = row_size.w or (dialog_w - sc(4)),
                    h = row_size.h or 0,
                }
            end
        }
    }
}
item.onTap = function()
    callback()
    return true
end
```

---

## 4. Multi-Button Bottom Action Rows

When laying out bottom action buttons (e.g., "About" and "Close" or "Save" and "Cancel"):
- Position buttons side-by-side using `HorizontalGroup`.
- Distribute width equally as `(dialog_w - sc(40)) / 2` per button.
- Insert a horizontal spacer `HorizontalSpan:new{ width = sc(8) }` between buttons.
- Use explicit button height `sc(42)` and radius `sc(8)`.

```lua
local btn_row = HorizontalGroup:new{
    align = "center",
    about_btn,
    HorizontalSpan:new{ width = sc(8) },
    close_btn,
}
```

---

## 5. Overlay Dismissal Behavior

- Modals and settings cards should require deliberate actions to close (clicking an explicit "Close" / "Back" button or pressing the hardware Back key).
- Avoid full-screen `Tap` event catchers on modal background overlays, preventing accidental background taps from misfiring onto underlying e-ink hit targets.
