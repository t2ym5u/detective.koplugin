local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Case content memory", function()
    it("loads only the language asked for, and release() drops it", function()
        local Content = dofile(DIR .. "content.lua")
        assert.are.same({}, Content.loadedLanguages())
        local fr = Content.get("fr")
        assert.are.same({ "fr" }, Content.loadedLanguages())
        assert.are.equal(fr, Content.get("fr"))
        assert.are.same(dofile(DIR .. "content_fr.lua"), fr)
        -- Switching language drops the previous one.
        local en = Content.get("en")
        assert.are.same({ "en" }, Content.loadedLanguages())
        assert.are.same(dofile(DIR .. "content_en.lua"), en)
        Content.release()
        assert.are.same({}, Content.loadedLanguages())
        -- Unknown languages fall back to English.
        Content.get("de")
        assert.are.same({ "en" }, Content.loadedLanguages())
    end)
end)
