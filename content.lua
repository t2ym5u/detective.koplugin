-- ---------------------------------------------------------------------------
-- content.lua — the case content (content_en.lua / content_fr.lua), loaded
-- for one language at a time and dropped when the game screen closes.
-- ---------------------------------------------------------------------------

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local Content = {}

local LANGS = { en = true, fr = true }

-- lang -> content table; holds at most the language in use.
local DATA = {}

-- The content of `lang` ("en" when unknown), read on first use. Asking for
-- another language drops the previous one.
function Content.get(lang)
    lang = LANGS[lang] and lang or "en"
    local data = DATA[lang]
    if not data then
        data = assert(loadfile(_dir .. "content_" .. lang .. ".lua"))()
        DATA = { [lang] = data }
    end
    return data
end

-- Languages currently loaded, sorted (for tests).
function Content.loadedLanguages()
    local list = {}
    for lang in pairs(DATA) do list[#list + 1] = lang end
    table.sort(list)
    return list
end

-- Drops the loaded content; the next case reads its language again (~1 ms).
function Content.release()
    DATA = {}
end

return Content
