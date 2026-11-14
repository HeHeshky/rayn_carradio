-- Translation helper. Falls back to English, then to the key itself.
Locales = Locales or {}

function L(key, ...)
    local lang = Locales[Config.Locale] or Locales.en or {}
    local str = lang[key] or (Locales.en and Locales.en[key]) or key
    if select('#', ...) > 0 then
        return str:format(...)
    end
    return str
end

-- UI strings for the NUI page (selected language merged over English)
function GetUiLocale()
    local out = {}
    for k, v in pairs((Locales.en and Locales.en.ui) or {}) do out[k] = v end
    local lang = Locales[Config.Locale]
    if lang and lang.ui then
        for k, v in pairs(lang.ui) do out[k] = v end
    end
    return out
end
