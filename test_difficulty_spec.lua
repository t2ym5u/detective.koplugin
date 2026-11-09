-- Difficulty guarantees for Detective (see docs/dev/TESTING.md, "Difficulty
-- specs"). Cases are graded by the board's logic solver (Board.logicSolve):
-- tier 2 = cross-grid deductions, tier 3 = time-order deductions, never
-- trial. Easy 3x3 with a few cross-grid steps, Medium 4x4 with times, Hard
-- 5x5 with many cross-grid and time-order steps.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. DIR .. "common/?.lua;" .. package.path

local Board = require("board")
local Packs = require("packs")

local CONTENT = {
    fr = dofile(DIR .. "content_fr.lua"),
    en = dofile(DIR .. "content_en.lua"),
}

local function gen(level, lang, pack)
    local pools, victim = Packs.pools(CONTENT[lang or "en"], pack or "all")
    return assert(Board.generate{ level = level, pools = pools, excluded_suspect = victim })
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

describe("Detective difficulty", function()
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

        it(level .. ": the logic solver finishes every case within the level's tier, no trial", function()
            local lvl = Board.LEVELS[level]
            for seed = 1, 30 do
                math.randomseed(seed * 211)
                local b = gen(level)
                local ok, t2, t3 = Board.logicSolve(b.n, b.k, b.clues, lvl.tier, true)
                assert.is_true(ok, level .. " seed " .. seed)
                assert.are.equal(b.gen_t2, t2)
                assert.are.equal(b.gen_t3, t3)
            end
        end)
    end

    it("levels differ: cross-grid and time steps grow from Easy to Hard", function()
        local med = {}
        for _, level in ipairs(Board.LEVEL_ORDER) do
            local lvl, t2s, t3s = Board.LEVELS[level], {}, {}
            for seed = 1, 30 do
                math.randomseed(seed * 211)
                local b = gen(level)
                assert.is_true(b.gen_t2 >= lvl.min_t2 and b.gen_t2 <= lvl.max_t2, level)
                assert.is_true(b.gen_t3 >= lvl.min_t3 and b.gen_t3 <= lvl.max_t3, level)
                t2s[#t2s + 1], t3s[#t3s + 1] = b.gen_t2, b.gen_t3
            end
            table.sort(t2s); table.sort(t3s)
            med[level] = { t2s[15], t3s[15], t2s[1], t2s[30] }
            print(string.format("\n  %s: tier-2 steps %d..%d (median %d), tier-3 median %d",
                level, t2s[1], t2s[30], t2s[15], t3s[15]))
        end
        assert.is_true(med.easy[4] < med.medium[3])     -- every Medium above every Easy
        assert.is_true(med.medium[4] < med.hard[3])     -- every Hard above every Medium
        assert.is_true(med.easy[2] < med.medium[2] and med.medium[2] < med.hard[2])
    end)

    it("sizes: easy 3x3 (3 categories), medium 4x4, hard 5x5 (4 categories)", function()
        local e, m, h = gen("easy"), gen("medium"), gen("hard")
        assert.are.same({ 3, 3 }, { e.n, e.k })
        assert.are.same({ 4, 4 }, { m.n, m.k })
        assert.are.same({ 5, 4 }, { h.n, h.k })
        assert.are.equal(2, e.key.c)   -- easy: where it happened
        assert.are.equal(4, h.key.c)   -- with times: when it happened
    end)

    it("generation is fast at every level", function()
        for _, level in ipairs(Board.LEVEL_ORDER) do
            local worst = 0
            for seed = 1, 30 do
                local best = math.huge
                for _ = 1, 3 do
                    math.randomseed(seed * 977)
                    local t0 = os.clock()
                    gen(level)
                    best = math.min(best, os.clock() - t0)
                end
                worst = math.max(worst, best)
            end
            print(string.format("\n  %s: worst %.1f ms", level, worst * 1000))
            -- About 40 ms is the target on a desktop (an e-reader is ~25x
            -- slower and shows the progress bar); a wide margin here.
            assert.is_true(worst < 0.25)
        end
    end)

    it("the same seed gives the same case (daily challenge)", function()
        for _, level in ipairs(Board.LEVEL_ORDER) do
            math.randomseed(20261030)
            local a = gen(level)
            math.randomseed(20261030)
            local b = gen(level)
            assert.are.same(a:serialize(), b:serialize())
        end
    end)

    it("the level table is ordered: size, tier, step windows", function()
        local e, m, h = Board.LEVELS.easy, Board.LEVELS.medium, Board.LEVELS.hard
        assert.is_true(e.n < m.n and m.n < h.n)
        assert.is_true(e.k <= m.k and m.k <= h.k)
        assert.is_true(e.tier <= m.tier and m.tier <= h.tier)
        assert.are.equal(0, e.max_t3)          -- easy: no time-order steps
        assert.is_true(e.max_t2 < h.min_t2 and m.max_t2 < h.min_t2)
        assert.is_true(m.max_t3 >= h.min_t3)   -- windows may overlap on t3
    end)

    -- Generation is bounded by MAX_TRIES, never by time: with a clock that
    -- jumps 1000 s at every read, a seed still gives the same case.
    it("generation never reads the clock", function()
        local oc, ot = os.clock, os.time
        for _, level in ipairs(Board.LEVEL_ORDER) do
            math.randomseed(77)
            local a = gen(level):serialize()
            local t = 0
            os.clock = function() t = t + 1000; return t end
            os.time = function(x) if x then return ot(x) end; t = t + 1000; return t end
            local ok, b = pcall(function() math.randomseed(77); return gen(level):serialize() end)
            os.clock, os.time = oc, ot
            assert.is_true(ok, tostring(b))
            assert.are.same(a, b)
        end
        for _, f in ipairs({ "board.lua", "clues.lua", "logic_grid.lua", "packs.lua" }) do
            local src = assert(io.open(DIR .. f)):read("*a")
            assert.is_nil(src:find("os%.clock"), f)
            assert.is_nil(src:find("os%.time"), f)
        end
    end)
end)
