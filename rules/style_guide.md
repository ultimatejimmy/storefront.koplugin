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
| `border_btn` | `sc(1)` | Standard action button border thickness |
| `radius_window` | `0` | Clean sharp corner radius for modals & cards |
| `radius_btn` | `sc(4)` | Pill/button corner radius |
| `gap` | `sc(8)` | Standard vertical/horizontal spacing |
| `face_label_size` | `18` | Standard body / setting row font size (`cfont`) |
| `title_font_size` | `22` | Modal card header title font size (`NotoSerif-Regular.ttf` or `cfont`) |
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

## 1.2 Copywriting & Punctuation Standards (UI Text, Placeholders & Labels)

To ensure clean, professional, and consistent typography across UI components, settings, and web catalog interfaces:

1. **No Spaces Around Slashes (`/`)**:
   - **Strict Rule**: NEVER place spaces around a slash in UI labels, option lists, button titles, headers, or technical copy.
   - **Correct**: `Creator/Artist`, `Tags/Keywords`, `Import/Export`, `Enable/Disable`, `Ctrl+V/Cmd+V`, `Reason/Additional Notes`, `Report/Change Type`.
   - **Incorrect**: `Creator / Artist`, `Tags / Keywords`, `Import / Export`.
   - *Exception*: Spaces around slashes are reserved strictly for poetry line breaks (e.g. *"Roses are red / Violets are blue"*).

2. **Colons & Key-Value Pairs**:
   - Never place a space before a colon; place exactly one space after (`Key: Value`, never `Key : Value`).

3. **Ellipses (`...`)**:
   - Use three dots `...` (or `…`) directly attached to text in placeholders and truncation indicators (`e.g. anime, landscape, dark...`). Avoid trailing punctuation after an ellipsis.

4. **Ampersands (`&`) vs. "and"**:
   - Use `&` only in space-constrained UI badges, chips, or short button titles (`Edit & Crop`, `Save & Exit`).
   - Use spelled-out `"and"` in full sentences, dialog prompts, confirmations, and error descriptions.

5. **Dashes (Hyphen vs. En-Dash vs. Em-Dash)**:
   - **Hyphen (`-`)**: Used for compound modifiers (`high-contrast`, `single-select`, `e-ink`).
   - **Em-Dash (`—`) or Spaced En-Dash (` – `)**: Used for parenthetical pauses or catalog subtitles (e.g. `Storefront Screensavers — E-Reader Wallpaper Catalog`). Never use loose space-hyphen-space (` - `) in place of an em-dash.

6. **Casing Conventions**:
   - **Title Case**: Modal headers, section titles, table headers, and action button labels (`Batch Actions`, `Clear Queue`, `Submit All Wallpapers`).
   - **Sentence Case**: Descriptive hints, tooltips, placeholders, and error messages (`Select all that apply to batch`, `Explain the change or infringement details...`).

---

## 2. Modal Dialog & Card Architecture

All dialog boxes and cards in Storefront follow a unified container structure:

```lua
local FocusManager = require("ui/widget/focusmanager")

local card = FrameContainer:new{
    padding = 0, -- (or card_padding = sc(12)-sc(14) for confirmation modals)
    radius = storefront_theme.radius_window or 0,
    bordersize = storefront_theme.border_window or sc(2),
    color = Blitbuffer.COLOR_BLACK,
    background = storefront_theme.color_bg or Blitbuffer.COLOR_WHITE,
    width = dialog_w,
    content_vg
}

local overlay = FocusManager:new{
    align = "center",
    vertical_align = "center",
    dimen = Geom:new{ w = sw, h = sh },
    layout = layout, -- 2D array of focusable rows/buttons e.g. { { row1 }, { row2 }, { cancel_btn, confirm_btn } }
    selected = { x = 1, y = 1 },
    key_events = {
        Close = { { "Back" } }
    },
    card
}

overlay.onClose = function()
    UIManager:close(overlay, "ui")
    if on_close_callback then on_close_callback() end
    return true
end

UIManager:show(overlay, "ui")
```

### 2.1 Dialog Header Standard
- Title label uses `NotoSerif-Regular.ttf` or `cfont` with `title_font_size` (22pt), bold, `COLOR_BLACK`.
- Full-width divider line underneath: `LineWidget:new{ dimen = Geom:new{ w = dialog_w - sc(4), h = sc(1) }, background = Blitbuffer.COLOR_BLACK }`.

### 2.2 Setting Rows Right-Alignment Math
In settings cards and list dialogs where rows have left labels and optional right-aligned values/widgets:
- **Never hardcode fixed left label widths** (such as `dialog_w - sc(150)`).
- **Dynamic Right Alignment**: Measure available width `avail_w = dialog_w - (frame_padding * 2) - sc(4)` and right widget width `right_w = right_widget:getSize().w`.
- **Label Constraint**: Limit left text width to `max_left_w = avail_w - icon_w - right_w - sc(8)`.
- **Dynamic Spacer**: Insert a flexible `HorizontalSpan` with width `spacer_w = avail_w - icon_w - left_used_w - right_w`.

---

## 3. Button Styles & Visual Hierarchy

Dialog action buttons must follow a clear primary vs. secondary visual hierarchy. Use the unified `StorefrontUtils.createButton(opts)` helper to ensure perfect 4-sided high-contrast borders and touch event handling across all KOReader devices.

### 3.1 Primary Action Buttons (Confirm / Delete / Apply / Update All / Restart now)
- **Background**: `Blitbuffer.COLOR_BLACK`
- **Text Color**: `Blitbuffer.COLOR_WHITE`
- **Typography**: `Font:getFace("cfont", ui_font_size)`, `bold = true`
- **Border**: `bordersize = storefront_theme.border_btn or sc(1)`, `color = Blitbuffer.COLOR_BLACK`
- **Radius**: `storefront_theme.radius_btn or sc(4)`

```lua
local StorefrontUtils = require("storefront_utils")
local primary_btn = StorefrontUtils.createButton{
    text = _("Apply"),
    face = Font:getFace("cfont", 18),
    bold = true,
    bordersize = storefront_theme.border_btn or sc(1),
    radius = storefront_theme.radius_btn or sc(4),
    width = btn_w,
    height = sc(38),
    background = Blitbuffer.COLOR_BLACK,
    text_font_color = Blitbuffer.COLOR_WHITE,
    callback = on_apply,
}
```

### 3.2 Secondary Action Buttons (Cancel / Settings / Back / Close / Restart later)
- **Background**: `Blitbuffer.COLOR_WHITE`
- **Text Color**: `Blitbuffer.COLOR_BLACK`
- **Typography**: `Font:getFace("cfont", ui_font_size)`, `bold = true`
- **Border**: `bordersize = storefront_theme.border_btn or sc(1)`, `color = Blitbuffer.COLOR_BLACK`
- **Radius**: `storefront_theme.radius_btn or sc(4)`

```lua
local StorefrontUtils = require("storefront_utils")
local cancel_btn = StorefrontUtils.createButton{
    text = _("Cancel"),
    face = Font:getFace("cfont", 18),
    bold = true,
    bordersize = storefront_theme.border_btn or sc(1),
    radius = storefront_theme.radius_btn or sc(4),
    width = btn_w,
    height = sc(38),
    background = Blitbuffer.COLOR_WHITE,
    text_font_color = Blitbuffer.COLOR_BLACK,
    callback = on_cancel,
}
```

### 3.3 Multi-Button Action Rows
When placing buttons side-by-side:
- Use `HorizontalGroup` with `align = "center"`.
- Split width equally: `btn_w = math.floor((inner_w - btn_gap) / 2)` with `HorizontalSpan:new{ width = btn_gap }` (`btn_gap = sc(8)` to `sc(12)`).

---

## 4. Option Picker / Radio Button Groups

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

## 5. Overlay Dismissal Behavior & Toast Stacking

- Modals and settings cards should require deliberate actions to close (clicking an explicit "Close" / "Back" button or pressing the hardware Back key).
- Avoid full-screen `Tap` event catchers on modal background overlays, preventing accidental background taps from misfiring onto underlying e-ink hit targets.
- **Toast Stacking Order**: When an action in a modal refreshes the dialog (e.g. removing an item or setting a wallpaper), ALWAYS call `refresh()` FIRST to rebuild the dialog overlay, and THEN call `Toast.show(...)`. Calling `Toast.show(...)` before `refresh()` will place the toast behind the newly shown dialog overlay.

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

---

## 7. E-Ink Lifecycle, Toasts, and Batch Progress Operations

### 7.1 Toast Lifecycle on E-Ink Devices
To guarantee instant and glitch-free rendering across e-ink screens:
1. **Dirty Rectangle Registration**: Custom toast widgets (`StorefrontToastWidget`) must implement `onShow` and `onCloseWidget` methods calling `UIManager:setDirty(self, ...)` with the precise card bounding geometry.
2. **Immediate Paint Invocations**: `StorefrontToast.show(...)` and `StorefrontToastWidget:show()` must call `UIManager:forceRePaint()` to push the rasterized frame immediately to the e-ink display controller rather than waiting for an ambient event tick.

### 7.2 Zero-Flash Rule for Batch Operations
When executing multi-step or queue-based operations (such as "Update All", multi-plugin downloads, or bulk scans):
- **Never recreate modals per item**: Creating, displaying, closing, and destroying separate toast/dialog windows for each queue item causes violent full-screen e-ink refresh flashes.
- **Single Persistent Progress Toast**: Show a single `StorefrontToast` instance at the start of the queue with `timeout = 0, dismissable = false`.
- **In-Place Label Updates**: For each queue item (and intermediate steps like downloading and extracting), update progress text in-place using `batch_toast:setText(...)`. `setText` invalidates only the inner text bounding area, resulting in smooth text changes without screen-tearing or full-screen flashing.
- **Single Completion Dismissal**: Close the persistent batch toast only once when the queue reaches completion or is cancelled.

---

## 8. Non-Touch & Hardware Button Support Standards

All dialogs, views, modals, cards, and list views in Storefront MUST be 100% accessible on non-touch e-ink devices (e.g. Kindle 4 Non-Touch, Kindle Keyboard, Sony PRS, button-only readers) and when operated via external keyboard or D-pad controllers.

### 8.1 FocusManager Protocol for Modals & Views
- **Base Architecture**: Use `FocusManager:new` (or `FocusManager:extend`) for all modals, dialogs, and interactive fullscreen views.
- **2D Layout Array (`layout`)**: Build an explicit 2D table `self.layout` representing the navigable grid of interactive elements:
  ```lua
  self.layout = {
      { back_btn },                                 -- Row 1: Header navigation
      { primary_action_btn, toggle_btn, delete_btn }, -- Row 2: Action buttons
      { item_1 },                                   -- Row 3: First list item
      { item_2 },                                   -- Row 4: Second list item
      { cancel_btn, confirm_btn },                  -- Row 5: Footer action buttons
  }
  ```
- **Initial Focus**: Always initialize `selected = { x = 1, y = 1 }` (or point to the primary action/row) so hardware focus starts in a predictable, valid location.

### 8.2 Focusable Component Protocol
Any custom row, toggle card, or list item placed into a `layout` array MUST implement the focus protocol:
1. **`:isFocusable()`**: Return `true` when interactive; return `false` if disabled or pure static label.
2. **`:onFocus()`**: Provide immediate, high-contrast visual feedback:
   ```lua
   function ItemWidget:onFocus()
       if self.frame then
           self.frame.invert = true -- or high-contrast focus border
           UIManager:setDirty(self.show_parent or self, "fast")
       end
       return true
   end
   ```
3. **`:onUnfocus()`**: Revert focus visual feedback:
   ```lua
   function ItemWidget:onUnfocus()
       if self.frame then
           self.frame.invert = false
           UIManager:setDirty(self.show_parent or self, "fast")
       end
       return true
   end
   ```
4. **`:onTapSelect()` / `:onPress()`**: Execute the item's primary action when the user presses `Enter` / `Press` on the hardware D-pad / keyboard:
   ```lua
   function ItemWidget:onTapSelect()
       if self.callback then
           self.callback()
       end
       return true
   end
   ```

### 8.3 Separation of D-Pad Traversal vs. Pagination
- **D-Pad Directional Keys**: `Up`, `Down`, `Left`, `Right` must strictly navigate focus across elements within the current view/page.
- **Pagination Keys**: Page flips must be triggered strictly by dedicated page turn keys (`Input.group.PgFwd`, `Input.group.PgBack`, `PageUp`, `PageDown`) or explicit navigation buttons in the footer.
- **Strict Rule**: NEVER bind `{ "Down" }` / `{ "Up" }` to `NextPage` / `PrevPage` on list dialogs or folder pickers, as this intercepts vertical item navigation.

### 8.4 Auto-Scrolling on Focus Change
In scrollable dialogs (`ScrollableContainer`), when focus moves to an element positioned outside the current visible viewport, the container's scroll offset must automatically adjust to bring the focused widget fully into view.

