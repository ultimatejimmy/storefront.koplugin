local ok_loc, Localization = pcall(require, "localization_storefront")
if ok_loc and Localization then
    Localization:ensureInit()
end
local _ = function(key, ...)
    if ok_loc and Localization then
        return Localization:t(key, ...)
    end
    return key
end

return {
    fullname = "Storefront",
    description = _("menu_storefront_desc"),
    version = "26.10.7-beta2",
    author = "ultimatejimmy",
}
