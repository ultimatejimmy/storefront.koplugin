local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")

local function sc(val)
    return Device.screen:scaleBySize(val)
end

local storefront_theme = {
    border_line_h = sc(2),
    border_window = sc(2),
    border_btn = sc(2),
    border_preview = sc(2),
    color_border = Blitbuffer.COLOR_DARK_GRAY,
    color_bg = Blitbuffer.COLOR_WHITE,
    color_bg_dim = Blitbuffer.COLOR_LIGHT_GRAY,
    color_label_dim = Blitbuffer.Color8(40),
    color_section_rule = Blitbuffer.COLOR_DARK_GRAY,
    radius_window = 0,
    radius_btn = sc(4),
    radius_spec_btn = sc(8), -- specific to redesign (8px)
    gap = sc(8),
    face_label_size = 18,
    title_font_size = 22,
    subtext_font_size = 16,
    section_header_font_size = 16,
}

return storefront_theme
