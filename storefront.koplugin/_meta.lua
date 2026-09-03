local ok_loc, Localization = pcall(require, "localization_storefront")
if ok_loc and Localization then
    Localization:init()
end
local _ = function(key, ...)
    if ok_loc and Localization then
        return Localization:t(key, ...)
    end
    return key
end

return {
    fullname = _("menu_storefront"),
    description = _("menu_storefront_desc"),
    version = "26.9.3",
    author = "ultimatejimmy",
}
