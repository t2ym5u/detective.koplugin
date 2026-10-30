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

-- Does the stored solution satisfy a clue?
local function holds(b, cl)
    local own, inv = { {} }, { {} }
    for s = 1, b.n do own[1][s] = s; inv[1][s] = s end
    for c = 2, b.k do
        own[c], inv[c] = {}, {}
        for v = 1, b.n do own[c][v] = b.owner[c][v]; inv[c][b.owner[c][v]] = v end
    end
    return Board.evalClue(cl, own, inv)
end

describe("Detective generator", function()
    for _, level in ipairs(Board.LEVEL_ORDER) do
        it(level .. ": every case has exactly one solution, and it is the stored one", function()
            math.randomseed(101)
            for _ = 1, 25 do
                local b = gen(level)
                local cnt, _, sol = Board.countSolutions(b.n, b.k, b.clues, 3, 1e8)
                assert.are.equal(1, cnt)
                for c = 2, b.k do
                    for v = 1, b.n do assert.are.equal(b.owner[c][v], sol[c][v]) end
                end
                for _, cl in ipairs(b.clues) do assert.is_true(holds(b, cl)) end
            end
        end)

        it(level .. ": no clue is redundant", function()
            math.randomseed(202)
            for _ = 1, 10 do
                local b = gen(level)
                for i = 1, #b.clues do
                    local rest = {}
                    for j, cl in ipairs(b.clues) do if j ~= i then rest[#rest + 1] = cl end end
                    local cnt = Board.countSolutions(b.n, b.k, rest, 2, 1e8)
                    assert.are.equal(2, cnt)
                end
            end
        end)
    end

    it("sizes: easy 3x3 (3 categories), medium 4x4, hard 5x5 (4 categories)", function()
        local e, m, h = gen("easy"), gen("medium"), gen("hard")
        assert.are.same({ 3, 3 }, { e.n, e.k })
        assert.are.same({ 4, 4 }, { m.n, m.k })
        assert.are.same({ 5, 4 }, { h.n, h.k })
        assert.are.equal(2, e.key.c)   -- easy: where it happened
        assert.are.equal(4, h.key.c)   -- with times: when it happened
    end)

    it("hard generation stays within its work budget and is fast", function()
        math.randomseed(303)
        local worst_t, worst_w = 0, 0
        for _ = 1, 40 do
            local t0 = os.clock()
            local b = gen("hard")
            worst_t = math.max(worst_t, os.clock() - t0)
            worst_w = math.max(worst_w, b.gen_nodes)
        end
        -- Budget: GEN_BUDGET for the normal tries plus one last plain try
        -- (each solution count is capped at COUNT_BUDGET).
        assert.is_true(worst_w < Board.GEN_BUDGET + 60 * Board.COUNT_BUDGET)
        -- Plain Lua on a desktop; a slow e-reader runs LuaJIT, so this leaves a
        -- wide margin under the 3 s target.
        print(string.format("\n  hard: worst %.0f ms, worst work %d", worst_t * 1000, worst_w))
        assert.is_true(worst_t < 1.0)
    end)

    it("the same seed gives the same case (daily challenge)", function()
        math.randomseed(20261030)
        local a = gen("hard")
        math.randomseed(20261030)
        local b = gen("hard")
        assert.are.same(a:serialize(), b:serialize())
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
