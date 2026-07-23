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
| `color_label_dim` | `Blitbuffer.Color8(40)` | High-contrast secondary text labels and subtitles (E-ink sharp) |
| `border_line_h` | `sc(1)` | Divider line thickness (`LineWidget`) |
| `border_window` | `sc(2)` | Card window border thickness |
| `border_btn` | `sc(2)` | Selected option / button border thickness |
| `radius_window` | `sc(12)` | Rounded corner radius for modals & cards |
| `radius_btn` | `sc(18)` | Pill/button corner radius |
| `gap` | `sc(8)` | Standard vertical/horizontal spacing |
| `face_label_size` | `18` | Standard body / setting row font size (`cfont`) |
| `title_font_size` | `22` | Modal card header title font size (`cfont`) |
| `subtext_font_size` | `16` | Secondary values, status indicators, and subtitles |
| `section_header_font_size` | `16` | Category / section header font size (`cfont`, bold) |

---

## 1.1 E-Ink Readability & Typography Standards

To guarantee high legibility across E-ink devices (e.g. Kindle, Kobo, Onyx Boox):

1. **Eliminate Faint Gray Text (No Dithering Noise)**:
   - E-ink hardware renders mid-level grays (e.g. `Color8(120)`) using dithered pixel patterns, making text appear blurry, fuzzy, and unreadable.
   - Text labels, titles, and subtext MUST use high-contrast dark values (`Blitbuffer.COLOR_BLACK` or dark gray `Blitbuffer.Color8(40)` minimum).
2. **Setting Row Label Contrast**:
   - Setting row text labels MUST remain solid black (`COLOR_BLACK`) regardless of whether the row is interactive or non-interactive/informational. Never gray out setting row titles.
3. **Font Scale Minimums**:
   - **Modal Header Titles**: `22pt` bold (`title_font_size`).
   - **Row Labels**: `18pt` (`face_label_size`).
   - **Section Headers**: `16pt` bold uppercase (`section_header_font_size`).
   - **Subtext & Secondary Indicators**: `16pt` minimum (`subtext_font_size`).

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

### 2.1 Setting Rows Right-Alignment Math

In settings cards where rows have left labels and optional right-aligned values/widgets (e.g., version tags, status indicators, timestamps):
- **Never hardcode fixed left label widths** (such as `dialog_w - sc(150)`), as long right-side strings will exceed card bounds and overflow off the right edge.
- **Dynamic Right Alignment**: Measure available width `avail_w = dialog_w - (frame_padding * 2) - sc(4)` and right widget width `right_w = right_widget:getSize().w`.
- **Label Constraint**: Limit left text width to `max_left_w = avail_w - icon_w - right_w - sc(8)` so text wraps cleanly if localized or long.
- **Dynamic Spacer**: Insert a flexible `HorizontalSpan` with width `spacer_w = avail_w - icon_w - left_used_w - right_w` between the left label and right widget.
- **Result**: All right-side values align vertically to the exact same right padding line with zero border overflow.

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

---

## 6. Icons & SVG Assets

Storefront uses vector SVG icons from the **Feather Icons** library stored under `storefront.koplugin/assets/`.

### Available SVG Icon Set

| Icon Asset | Visual Concept | Usage in Storefront |
|---|---|---|
| `zap.svg` | Lightning Bolt | Storefront plugin header branding logo |
| `settings.svg` | Gear / Cog | Open main settings card |
| `search.svg` | Magnifying Glass | Search input & filter actions |
| `rotate-cw.svg` / `refresh-cw.svg` | Refresh Arrow | Refresh cache button (browser header & settings) |
| `info.svg` | Info Circle | "About Storefront" settings row & info popups |
| `square.svg` / `check-square.svg` | Checkboxes | Unchecked / checked list filter states |

### Asset Resolution & Rendering Rules

1. **Dynamic Asset Path Resolution**: Always locate asset files relative to the current Lua module using `debug.getinfo(1, "S")`:
   ```lua
   local function getAssetPath(filename)
       local info = debug.getinfo(1, "S")
       local dir = info.source:match("^@(.*[/\\])") or ""
       return dir .. "assets/" .. filename
   end
   ```

2. **Render with `ImageWidget`**: KOReader's `IconWidget`/`IconButton` cannot load custom plugin asset paths (it only resolves bare icon names against KOReader's internal core resources). Always use `ImageWidget` with `scale_factor = 0` and `alpha = true` for SVG transparency:
   ```lua
   local icon = ImageWidget:new{
       file = getAssetPath("info.svg"),
       width = sc(20),
       height = sc(20),
       scale_factor = 0,
       alpha = true,
   }
   ```

3. **Icon Sizing Standard**:
   - Header logos / major icons: `sc(24)`
   - Setting row & button icons: `sc(20)`
