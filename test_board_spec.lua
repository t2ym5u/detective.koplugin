local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. DIR .. "common/?.lua;" .. package.path

local Board = require("board")
local Clues = require("clues")
local Packs = require("packs")

local CONTENT = {
    fr = dofile(DIR .. "content_fr.lua"),
    en = dofile(DIR .. "content_en.lua"),
}

local function gen(level, lang, pack)
    local pools, victim = Packs.pools(CONTENT[lang or "en"], pack or "all")
    return assert(Board.generate{ level = level, pools = pools, excluded_suspect = victim })
end

local function suspectName(ct, i)
    local e = ct.suspects[i]
    return type(e) == "table" and e.name or e
end

describe("Detective generator", function()
    for _, level in ipairs(Board.LEVEL_ORDER) do
        it(level .. ": no clue can be dropped while the solver still finishes", function()
            local tier = Board.LEVELS[level].tier
            math.randomseed(202)
            for _ = 1, 10 do
                local b = gen(level)
                for i = 1, #b.clues do
                    local rest = {}
                    for j, cl in ipairs(b.clues) do if j ~= i then rest[#rest + 1] = cl end end
                    assert.is_false((Board.logicSolve(b.n, b.k, rest, tier)))
                end
            end
        end)
    end

    it("the logic solver never marks a cell wrongly, and agrees with the search", function()
        -- Random subsets of real clues: whatever it marks matches the stored
        -- solution, and when it finishes the search finds one solution.
        math.randomseed(31)
        for t = 1, 150 do
            local level = Board.LEVEL_ORDER[t % 3 + 1]
            local b = gen(level)
            local sub = {}
            for _, cl in ipairs(b.clues) do if math.random(4) > 1 then sub[#sub + 1] = cl end end
            local ok, _, _, L = Board.logicSolve(b.n, b.k, sub, 3)
            assert.is_false(L.broken())
            for c1 = 1, b.k do for v1 = 1, b.n do for c2 = 1, b.k do for v2 = 1, b.n do
                if c1 ~= c2 then
                    local m = L.mark((c1 - 1) * b.n + v1, (c2 - 1) * b.n + v2)
                    if m ~= nil then
                        assert.are.equal(b.owner[c1][v1] == b.owner[c2][v2], m)
                    end
                end
            end end end end
            if ok then assert.are.equal(1, (Board.countSolutions(b.n, b.k, sub, 2, 1e8))) end
        end
    end)

    it("a case saved by 1.1.x still loads and plays", function()
        local old = { names = { { 4, 2, 3, 1 }, { 4, 3, 2, 1 }, { 2, 3, 4, 1 } }, level = "medium",
            key = { c = 4, v = 1 }, owner = { { 1, 2, 3, 4 }, { 3, 4, 1, 2 }, { 1, 4, 3, 2 }, { 3, 1, 4, 2 } },
            k = 4, hints_used = 0, struck = {}, crime = 1, n = 4,
            clues = { { a = { c = 3, v = 3 }, b2 = { c = 1, v = 4 }, kind = "either", b = { c = 1, v = 3 } },
                { a = { c = 3, v = 1 }, kind = "same", b = { c = 4, v = 2 } },
                { a = { c = 2, v = 1 }, kind = "same", b = { c = 3, v = 3 } },
                { a = { c = 1, v = 4 }, kind = "diff", b = { c = 2, v = 4 } },
                { a = { c = 1, v = 2 }, kind = "diff", b = { c = 4, v = 3 } },
                { a = { c = 1, v = 4 }, b2 = { c = 3, v = 1 }, kind = "either", b = { c = 3, v = 2 } },
                { a = { c = 1, v = 1 }, kind = "earlier", b = { c = 3, v = 4 } },
                { a = { c = 4, v = 3 }, b2 = { c = 1, v = 4 }, kind = "either", b = { c = 1, v = 2 } },
                { a = { c = 2, v = 3 }, b2 = { c = 4, v = 2 }, kind = "either", b = { c = 4, v = 1 } } } }
        local b = assert(Board.load(old))
        assert.are.equal(0, b:getMark(1, 1, 1))
        b:cycle(1, 1, 1)
        local s, p, o = b:culprit()
        assert.is_true(b:accuse(s, p, o))
    end)

    it("victims are never suspects in their own case", function()
        for _, lang in ipairs({ "fr", "en" }) do
            local ct = CONTENT[lang]
            math.randomseed(404)
            for _ = 1, 60 do
                local b = gen("hard", lang)
                local victim = ct.crimes[b.crime].victim
                for _, i in ipairs(b.names[1]) do
                    assert.are_not.equal(victim, suspectName(ct, i))
                end
            end
        end
    end)
end)

describe("Detective grid", function()
    it("cycles empty -> cross -> dot -> empty, a dot crosses its row and column, undo restores", function()
        math.randomseed(5)
        local b = gen("medium")
        assert.are.equal(0, b:getMark(1, 1, 1))
        b:cycle(1, 1, 1)
        assert.are.equal(Board.NO, b:getMark(1, 1, 1))
        b:cycle(1, 1, 1)
        assert.are.equal(Board.YES, b:getMark(1, 1, 1))
        for i = 2, b.n do
            assert.are.equal(Board.NO, b:getMark(1, 1, i))
            assert.are.equal(Board.NO, b:getMark(1, i, 1))
        end
        assert.are.equal(Board.EMPTY, b:getMark(1, 2, 2))
        b:undoStep()
        assert.are.equal(Board.NO, b:getMark(1, 1, 1))
        assert.are.equal(Board.EMPTY, b:getMark(1, 1, 2))
        b:cycle(1, 1, 1); b:cycle(1, 1, 1)
        assert.are.equal(Board.EMPTY, b:getMark(1, 1, 1))
    end)

    it("hints point at a wrong mark first, then fill cells until the grid is complete", function()
        math.randomseed(6)
        local b = gen("easy")
        -- A wrong mark.
        local wrong
        for c = 1, b.n do if not b:truth(1, 1, c) then wrong = c end end
        b:setMark(1, 1, wrong, Board.YES)
        local step = b:findHint()
        assert.are.equal("mistake", step.kind)
        assert.are.same({ 1, 1, wrong }, { step.tag, step.r, step.c })
        local guard = 0
        while true do
            local st = b:findHint()
            if not st then break end
            assert.is_true(b:applyHint(st))
            b:noteHintUsed()
            guard = guard + 1
            assert.is_true(guard < 200)
        end
        assert.are.equal(0, b:mistakes())
        assert.is_true(b:getHintsUsed() > 0)
    end)

    it("accusing right solves, wrong fails; reveal closes the case", function()
        math.randomseed(7)
        local b = gen("hard")
        local s, p, o = b:culprit()
        assert.is_true(b:accuse(s, p, o))
        assert.are.equal("solved", b.over)
        assert.is_false(b:cycle(1, 1, 1))
        local b2 = gen("hard")
        local s2, p2, o2 = b2:culprit()
        assert.is_false(b2:accuse(s2, p2, (o2 % b2.n) + 1))
        assert.are.equal("failed", b2.over)
        local b3 = gen("medium")
        b3:reveal()
        assert.are.equal("revealed", b3.over)
        assert.are.equal(0, b3:mistakes())
    end)

    it("serializes and loads a case in progress", function()
        math.randomseed(8)
        local b = gen("medium")
        b:cycle(2, 1, 1); b:toggleStruck(1)
        local c = Board.load(b:serialize())
        assert.are.same(b:serialize(), c:serialize())
        assert.is_nil(Board.load({ junk = true }))
    end)
end)

describe("Detective wording", function()
    for _, lang in ipairs({ "fr", "en" }) do
        it(lang .. ": every clue and case reads as a sentence, in every phrasing", function()
            math.randomseed(9)
            for _, level in ipairs(Board.LEVEL_ORDER) do
                for _ = 1, 15 do
                    local b = gen(level, lang)
                    local w = Clues.new(CONTENT[lang], lang, b)
                    local texts = { w:caseText(), w:answer(b:culprit()) }
                    for i, cl in ipairs(b.clues) do
                        texts[#texts + 1] = w:text(cl, i)
                        for v = 1, #Clues.WORDING[lang][cl.kind] do texts[#texts + 1] = w:text(cl, nil, v) end
                    end
                    for _, t in ipairs(texts) do
                        assert.is_nil(t:find("[%%{}]"), t)
                        assert.is_truthy(t:find("[%.%?!]$"), t)
                        assert.is_truthy(t:sub(1, 1):match("[%u\195]"), t)
                    end
                end
            end
        end)

        it(lang .. ": at least three phrasings per clue kind", function()
            for _, kind in ipairs({ "same", "diff", "either", "before1", "earlier" }) do
                assert.is_true(#Clues.WORDING[lang][kind] >= 3, kind)
            end
        end)

        it(lang .. ": content is big enough, packs are full, family-friendly", function()
            local ct = CONTENT[lang]
            assert.is_true(#ct.crimes >= 60 and #ct.suspects >= 120 and #ct.places >= 80 and #ct.objects >= 80)
            for _, pack in ipairs(Packs.IDS) do
                local c = Packs.count(ct, pack)
                assert.is_true(c.crimes >= 12 and c.suspects >= 25 and c.places >= 18 and c.objects >= 18, pack)
            end
            local names = {}
            for i = 1, #ct.suspects do names[suspectName(ct, i)] = true end
            for _, cr in ipairs(ct.crimes) do
                if cr.victim then assert.is_true(names[cr.victim], cr.victim) end
            end
            local banned = { "hitler", "staline", "stalin", "pol pot", "mussolini", "ben laden", "bin laden",
                             "franco", "mao ", "gengis", "genghis", "attila", "ripper", "éventreur", "landru" }
            for i = 1, #ct.suspects do
                local n = suspectName(ct, i):lower()
                for _, ban in ipairs(banned) do assert.is_nil(n:find(ban, 1, true), n) end
            end
            local function ulen(x) local _, k = x:gsub("[^\128-\191]", "") return k end
            for _, sp in ipairs(ct.suspects) do assert.is_true(ulen(sp.short or sp.name) <= 14, sp.short) end
            for _, p in ipairs(ct.places) do assert.is_true(ulen(p.label) <= 12, p.label) end
            for _, o in ipairs(ct.objects) do assert.is_true(ulen(o.label) <= 12, o.label) end
        end)

        it(lang .. ": every pack makes unique cases", function()
            math.randomseed(11)
            for _, pack in ipairs(Packs.IDS) do
                local b = gen("hard", lang, pack)
                assert.are.equal(1, (Board.countSolutions(b.n, b.k, b.clues, 3, 1e8)))
                local pools = Packs.pools(CONTENT[lang], pack)
                local inpool = {}
                for _, i in ipairs(pools.suspects) do inpool[i] = true end
                for _, i in ipairs(b.names[1]) do assert.is_true(inpool[i]) end
            end
        end)
    end
end)
