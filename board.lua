-- ---------------------------------------------------------------------------
-- board.lua — a Detective case: generator, solver, the player's logic grid.
-- Pure Lua, no UI (wording lives in clues.lua, names in content_*.lua).
--
-- A case has N suspects and K categories: 1 = suspect, 2 = place,
-- 3 = object, 4 = time (ordered). Every value of every category belongs to
-- exactly one suspect; the solution is, per category, which suspect owns
-- each value. Clues constrain that. The generator keeps adding true clues
-- until the logic solver below (the paper logic grid, never trial and
-- error) fills every grid, then drops every clue it can do without, and
-- grades the case by how much cross-grid and time reasoning it needs.
--
-- Clue kinds (a, b, b2 are entities { c = category, v = value index }):
--   same    a and b belong to the same suspect
--   diff    a and b belong to different suspects
--   either  a belongs to the owner of b or of b2 (b, b2 in one category)
--   before1 a's owner was there exactly one time slot before b's owner
--   earlier a's owner was there before b's owner
-- ---------------------------------------------------------------------------

local Board = {}
Board.__index = Board

Board.SUSPECT, Board.PLACE, Board.OBJECT, Board.TIME = 1, 2, 3, 4

-- What each level asks for (1.2.0). Before, a case only had to have one
-- solution, so most Medium and Hard cases could not be finished without
-- trying an answer to see if it breaks.
--   tier          the hardest reasoning allowed (see newLogic)
--   min/max_t2    how many cross-grid (tier-2) deductions it takes
--   min/max_t3    how many time-order (tier-3) deductions it takes
-- Easy: 3 x 3, a few cross-grid steps. Medium: 4 x 4 with times, at most
-- 25 cross-grid steps. Hard: 5 x 5 with times, at least 28 cross-grid and
-- 15 time-order steps.
Board.LEVELS = {
    easy   = { n = 3, k = 3, tier = 2, weights = { same = 3,   diff = 4, either = 2 },
               min_t2 = 0, max_t2 = 4, min_t3 = 0, max_t3 = 0 },
    medium = { n = 4, k = 4, tier = 3, weights = { same = 1.5, diff = 4, either = 2,   before1 = 1.5, earlier = 1.5 },
               min_t2 = 0, max_t2 = 25, min_t3 = 0, max_t3 = 20 },
    hard   = { n = 5, k = 4, tier = 3, weights = { same = 0.6, diff = 4, either = 2.5, before1 = 2,   earlier = 2 },
               min_t2 = 28, max_t2 = math.huge, min_t3 = 15, max_t3 = math.huge },
}
Board.LEVEL_ORDER = { "easy", "medium", "hard" }

-- Cases drawn per generation at most; the first one inside its level's
-- window is kept, else the closest (every one is checked by the solver).
Board.MAX_TRIES = 12
-- Node budget of one countSolutions call (a plain search, used by the
-- specs to cross-check the logic solver).
Board.COUNT_BUDGET = 30000

local function shuffle(t, rnd)
    for i = #t, 2, -1 do
        local j = rnd(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

local function perm(n, rnd)
    local t = {}
    for i = 1, n do t[i] = i end
    return shuffle(t, rnd)
end

-- ---------------------------------------------------------------------------
-- Solver
--
-- A solution is one permutation per category (place, object, time), so the
-- solver joins categories one at a time: each category's permutations are
-- filtered by the clues that only involve it, and a clue spanning several
-- categories is checked as soon as the last of them is placed. With five
-- suspects that is at most 120 permutations per category, and the clues cut
-- the join down long before the 120^3 worst case.
-- ---------------------------------------------------------------------------

-- Category masks are 0..7: a lookup table does the bit work the same way
-- on LuaJIT and on plain Lua 5.3+ (the specs).
local AND = {}
for x = 0, 7 do
    AND[x] = {}
    for y = 0, 7 do
        local r, w, a, b = 0, 1, x, y
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then r = r + w end
            a, b, w = math.floor(a / 2), math.floor(b / 2), w * 2
        end
        AND[x][y] = r
    end
end
local function bit_and(a, b) return AND[a][b] end
local function bit_or(a, b) return a + b - AND[a][b] end

local PERMS = {}

local function permutations(n)
    if PERMS[n] then return PERMS[n] end
    local out, cur, used = {}, {}, {}
    local function rec(i)
        if i > n then
            local p, q = {}, {}
            for j = 1, n do p[j] = cur[j]; q[cur[j]] = j end
            out[#out + 1] = { own = p, inv = q }
            return
        end
        for s = 1, n do
            if not used[s] then
                used[s] = true; cur[i] = s
                rec(i + 1)
                used[s] = false
            end
        end
    end
    rec(1)
    PERMS[n] = out
    return out
end

-- Evaluates a clue once every category it involves is placed.
-- own[c][v] = suspect, inv[c][s] = value (category 1 is the identity).
local function evalClue(cl, own, inv)
    local a, b = cl.a, cl.b
    local oa, ob = own[a.c][a.v], own[b.c][b.v]
    local kind = cl.kind
    if kind == "same" then return oa == ob end
    if kind == "diff" then return oa ~= ob end
    if kind == "either" then
        return oa == ob or oa == own[cl.b2.c][cl.b2.v]
    end
    if oa == ob then return false end
    local ta, tb = inv[4][oa], inv[4][ob]
    if kind == "before1" then return ta + 1 == tb end
    return ta < tb
end
Board.evalClue = evalClue

-- Bit mask of the categories (2..4) a clue needs placed to be checked.
local BIT = { [2] = 1, [3] = 2, [4] = 4 }

local function clueMask(cl)
    local m = 0
    local function add(c) if c ~= 1 then m = bit_or(m, BIT[c]) end end
    add(cl.a.c); add(cl.b.c)
    if cl.b2 then add(cl.b2.c) end
    if cl.kind == "before1" or cl.kind == "earlier" then m = bit_or(m, BIT[4]) end
    return m
end

-- Counts solutions up to `limit`. Returns count, work, solution (the first
-- found, as own[c][v]). count is nil if the budget (clue checks) ran out.
--
-- Forward checking over whole categories: each unplaced category keeps the
-- list of its permutations still compatible with what is placed. Placing a
-- permutation filters the others' lists by the clues that link them; the
-- category with the shortest list goes next.
function Board.countSolutions(n, k, clues, limit, budget)
    limit  = limit or 2
    budget = budget or Board.COUNT_BUDGET
    local perms = permutations(n)
    local ident = {}
    for s = 1, n do ident[s] = s end
    local own, inv = { ident }, { ident }
    local masks = {}
    for i, cl in ipairs(clues) do masks[i] = clueMask(cl) end

    local work, count, first, aborted = 0, 0, nil, false

    -- Keeps the permutations of category c that pass every clue whose mask
    -- is inside `allowed` and contains `need` (c's bit, plus the bit of the
    -- category just placed).
    local function filter(list, c, need, allowed)
        local checks = {}
        for i, m in ipairs(masks) do
            if bit_and(m, need) == need and bit_and(m, allowed) == m then checks[#checks + 1] = clues[i] end
        end
        if #checks == 0 then return list end
        local out = {}
        for _, p in ipairs(list) do
            own[c], inv[c] = p.own, p.inv
            local ok = true
            for j = 1, #checks do
                work = work + 1
                if not evalClue(checks[j], own, inv) then ok = false break end
            end
            if ok then out[#out + 1] = p end
        end
        own[c], inv[c] = nil, nil
        return out
    end

    local function rec(lists, placed)
        if work > budget then aborted = true return end
        local best, bc = nil, nil
        for c = 2, k do
            if lists[c] and (not best or #lists[c] < best) then best, bc = #lists[c], c end
        end
        if not bc then
            count = count + 1
            if not first then
                first = {}
                for c = 2, k do
                    first[c] = {}
                    for v = 1, n do first[c][v] = own[c][v] end
                end
            end
            return
        end
        if best == 0 then return end
        local mine = lists[bc]
        local now = bit_or(placed, BIT[bc])
        for _, p in ipairs(mine) do
            own[bc], inv[bc] = p.own, p.inv
            local nl, dead = {}, false
            for d = 2, k do
                if lists[d] and d ~= bc then
                    nl[d] = filter(lists[d], d, bit_or(BIT[d], BIT[bc]), bit_or(now, BIT[d]))
                    own[bc], inv[bc] = p.own, p.inv
                    if #nl[d] == 0 then dead = true break end
                end
            end
            if not dead then
                rec(nl, now)
                if aborted or count >= limit then break end
            end
        end
        own[bc], inv[bc] = nil, nil
    end

    local lists = {}
    for c = 2, k do lists[c] = filter(perms, c, BIT[c], BIT[c]) end
    rec(lists, 0)
    if aborted then return nil, work end
    return count, work, first
end

-- ---------------------------------------------------------------------------
-- Logic solver (1.2.0): the paper logic grid, no trial and error.
--
-- It works on the same pair grids the player fills: for every two entities
-- of different categories, "same suspect" (yes), "different" (no) or not
-- known yet. Every deduction follows from the clues and from what is
-- already marked; it never assumes a mark to see what breaks. The case is
-- solved when every cell of every grid is marked, so a case it finishes
-- has exactly one solution.
--
--   tier 1  what a beginner does inside one grid: the "is / is not" clues,
--           an "either b or b2" clue crosses a out of every other value of
--           b's category (and gives the other one once one is crossed), a
--           dot crosses out its row and column, the last empty cell of a
--           row or column is a dot.
--   tier 2  across grids: a dot copies the row of one entity onto the
--           other ("Mozart is at the Louvre, the Louvre is not where the
--           teapot was, so Mozart did not have the teapot"); two entities
--           that can't share any value of a third category are different
--           people; and someone ruled out of both b and b2 can't be a of
--           "a is b or b2".
--   tier 3  time order: "one hour before" / "earlier than" keep only the
--           time slots each side can still have.
-- Tier 2 and 3 run one deduction at a time, and only when the lower tiers
-- are stuck, so their counts measure how much of the case needs them.
-- ---------------------------------------------------------------------------

local YES, NO = 1, 2

-- A solver for an n x k case. :add(clue) records a clue (a clue only ever
-- adds deductions, so the generator adds them one by one on the same
-- solver); :run(max_tier) deduces until stuck and returns true when every
-- grid is filled. :stats() gives the tier-2 and tier-3 step counts.
local function newLogic(n, k)
    local E = n * k
    local R, cat, off = {}, {}, {}
    for x = 1, E * E do R[x] = 0 end
    for i = 1, E do
        cat[i] = math.floor((i - 1) / n) + 1
        off[i] = (i - 1) * E
    end
    local unknown = n * n * k * (k - 1) / 2
    local fixed, either, timed = {}, {}, {}
    local t2, t3 = 0, 0
    local bad, single = false, false

    local function id(e) return (e.c - 1) * n + e.v end
    -- Marks (i, j) as v (YES or NO); true if it is new.
    local function set(i, j, v)
        if cat[i] == cat[j] then
            if (i == j) ~= (v == YES) then bad = true end
            return false
        end
        local x = off[i] + j
        local cur = R[x]
        if cur == v then return false end
        if cur ~= 0 then bad = true return false end
        R[x] = v
        R[off[j] + i] = v
        unknown = unknown - 1
        return true
    end

    -- Tier 1, all at once: returns true if anything changed.
    local function tier1()
        local ch = false
        for _, cl in ipairs(fixed) do
            if set(cl[1], cl[2], cl[3]) then ch = true end
        end
        for _, cl in ipairs(either) do
            local a, b, b2, base = cl[1], cl[2], cl[3], cl[4]
            for x = base + 1, base + n do
                if x ~= b and x ~= b2 and set(a, x, NO) then ch = true end
            end
            if R[off[a] + b] == NO and set(a, b2, YES) then ch = true end
            if R[off[a] + b2] == NO and set(a, b, YES) then ch = true end
        end
        for i = 1, E do
            local oi, ci = off[i], cat[i]
            for c = 1, k do
                if c ~= ci then
                    local base = (c - 1) * n
                    local yes, open, last = nil, 0, nil
                    for j = base + 1, base + n do
                        local r = R[oi + j]
                        if r == YES then yes = j end
                        if r ~= NO then open = open + 1; last = j end
                    end
                    if open == 0 then bad = true end
                    if yes then
                        if open > 1 then
                            for j = base + 1, base + n do
                                if j ~= yes and set(i, j, NO) then ch = true end
                            end
                        end
                    elseif open == 1 then
                        if set(i, last, YES) then ch = true end
                    end
                end
            end
        end
        return ch
    end

    -- Tier 2: one deduction when counting (single), else all it finds.
    -- A dot copies one entity's marks onto the other.
    local function dots()
        local any = false
        for i = 1, E do
            local oi, ci = off[i], cat[i]
            for c = 1, k do
                if c ~= ci then
                    local base, j = (c - 1) * n, nil
                    for x = base + 1, base + n do
                        if R[oi + x] == YES then j = x break end
                    end
                    if j then
                        local oj = off[j]
                        for l = 1, E do
                            local cl = cat[l]
                            if cl ~= ci and cl ~= c then
                                local r = R[oj + l]
                                if r ~= 0 and R[oi + l] == 0 then
                                    set(i, l, r)
                                    if single then return true end
                                    any = true
                                end
                            end
                        end
                    end
                end
            end
        end
        return any
    end
    -- No value of a third category left in common: different people.
    -- "a is b or b2": whoever is neither b nor b2 is not a.
    local function apart()
        local any = false
        for i = 1, E do
            local oi, ci = off[i], cat[i]
            for l = i + 1, E do
                local cl = cat[l]
                if cl ~= ci and R[oi + l] == 0 then
                    local ol = off[l]
                    for c = 1, k do
                        if c ~= ci and c ~= cl then
                            local base, shared = (c - 1) * n, false
                            for x = base + 1, base + n do
                                if R[oi + x] ~= NO and R[ol + x] ~= NO then shared = true break end
                            end
                            if not shared then
                                set(i, l, NO)
                                if single then return true end
                                any = true
                                break
                            end
                        end
                    end
                end
            end
        end
        for _, cl in ipairs(either) do
            local a, b, b2 = cl[1], cl[2], cl[3]
            local ca, cb = cat[a], cat[b]
            for x = 1, E do
                local cx = cat[x]
                if cx ~= ca and cx ~= cb then
                    local ox = off[x]
                    if R[ox + a] == 0 and R[ox + b] == NO and R[ox + b2] == NO then
                        set(x, a, NO)
                        if single then return true end
                        any = true
                    end
                end
            end
        end
        return any
    end

    local function tier2()
        if single then return dots() or apart() end
        local any = dots()
        return apart() or any
    end

    -- Tier 3: time order (same counting rule as tier 2).
    local tbase = 3 * n
    local ta, tb = {}, {}
    local function tier3()
        local any = false
        for _, cl in ipairs(timed) do
            local a, b, one = cl[1], cl[2], cl[3]
            if cat[a] ~= cat[b] and R[off[a] + b] == 0 then
                set(a, b, NO)
                if single then return true end
                any = true
            end
            local oa, ob = off[a], off[b]
            for t = 1, n do
                ta[t] = R[oa + tbase + t] ~= NO
                tb[t] = R[ob + tbase + t] ~= NO
            end
            for t = 1, n do
                local okA, okB = false, false
                if one then
                    okA = t < n and tb[t + 1]
                    okB = t > 1 and ta[t - 1]
                else
                    for u = t + 1, n do if tb[u] then okA = true break end end
                    for u = 1, t - 1 do if ta[u] then okB = true break end end
                end
                if ta[t] and not okA then
                    set(a, tbase + t, NO)
                    if single then return true end
                    any = true
                end
                if tb[t] and not okB then
                    set(b, tbase + t, NO)
                    if single then return true end
                    any = true
                end
            end
        end
        return any
    end

    local L = {}
    function L.add(cl)
        local a, b = id(cl.a), id(cl.b)
        if cl.kind == "same" then
            fixed[#fixed + 1] = { a, b, YES }
        elseif cl.kind == "diff" then
            fixed[#fixed + 1] = { a, b, NO }
        elseif cl.kind == "either" then
            either[#either + 1] = { a, b, id(cl.b2), (cl.b.c - 1) * n }
        else
            timed[#timed + 1] = { a, b, cl.kind == "before1" }
        end
    end
    -- single: tier 2 and 3 make one deduction per call (to count them);
    -- otherwise every one they find (the same end result, faster).
    function L.run(max_tier, one_by_one)
        single = one_by_one
        if not single then
            -- Same end result, cheapest rules first.
            while unknown > 0 and not bad do
                if not (tier1() or (max_tier >= 2 and dots())
                        or (max_tier >= 3 and k >= 4 and tier3())
                        or (max_tier >= 2 and apart())) then
                    break
                end
            end
            return unknown == 0 and not bad
        end
        while unknown > 0 and not bad do
            if not tier1() then
                if max_tier >= 2 and tier2() then
                    t2 = t2 + 1
                elseif max_tier >= 3 and k >= 4 and tier3() then
                    t3 = t3 + 1
                else
                    break
                end
            end
        end
        return unknown == 0 and not bad
    end
    function L.stats() return t2, t3 end
    -- Entities i and j ((category - 1) * n + value): true if the same
    -- suspect, false if not, nil while unknown.
    function L.mark(i, j)
        local r = R[off[i] + j]
        if r == 0 then return nil end
        return r == YES
    end
    function L.broken() return bad end
    -- Does an "is / is not" clue only state what is already marked?
    function L.known(cl)
        if cl.kind ~= "same" and cl.kind ~= "diff" then return false end
        local a, b = id(cl.a), id(cl.b)
        return cat[a] ~= cat[b] and R[off[a] + b] ~= 0
    end
    return L
end

-- Solves a whole case with the logic solver, up to max_tier (default 3).
-- Returns solved, tier-2 steps, tier-3 steps (counted one deduction at a
-- time when `count` is true, otherwise one pass at a time).
function Board.logicSolve(n, k, clues, max_tier, count)
    local L = newLogic(n, k)
    for _, cl in ipairs(clues) do L.add(cl) end
    local ok = L.run(max_tier or 3, count)
    local t2, t3 = L.stats()
    return ok, t2, t3, L
end

-- ---------------------------------------------------------------------------
-- Generator
-- ---------------------------------------------------------------------------

-- Every true clue about the solution, by kind.
local function cluePool(n, k, owner, rnd)
    local pool = { same = {}, diff = {}, either = {}, before1 = {}, earlier = {} }
    local ents = {}
    for c = 1, k do
        for v = 1, n do ents[#ents + 1] = { c = c, v = v } end
    end
    local function own(e) return owner[e.c][e.v] end
    for i = 1, #ents do
        for j = i + 1, #ents do
            local a, b = ents[i], ents[j]
            if a.c ~= b.c then
                -- Put the suspect (if any) first: "Mozart was at the Louvre".
                if b.c == 1 then a, b = b, a end
                if own(a) == own(b) then
                    pool.same[#pool.same + 1] = { kind = "same", a = a, b = b }
                else
                    pool.diff[#pool.diff + 1] = { kind = "diff", a = a, b = b }
                end
            end
        end
    end
    for _, a in ipairs(ents) do
        for cb = 1, k do
            if cb ~= a.c then
                local truth = nil
                for v = 1, n do if owner[cb][v] == own(a) then truth = v end end
                for v = 1, n do
                    if v ~= truth then
                        local b, b2 = { c = cb, v = truth }, { c = cb, v = v }
                        -- Times read in order ("at 3 pm or at 4 pm"); the
                        -- rest in random order, so the first isn't the answer.
                        if (cb == 4 and b.v > b2.v) or (cb ~= 4 and rnd(2) == 1) then b, b2 = b2, b end
                        pool.either[#pool.either + 1] = { kind = "either", a = a, b = b, b2 = b2 }
                    end
                end
            end
        end
    end
    if k >= 4 then
        local timeOf = {}
        for v = 1, n do timeOf[owner[4][v]] = v end
        for _, a in ipairs(ents) do
            for _, b in ipairs(ents) do
                if a.c ~= 4 and b.c ~= 4 and own(a) ~= own(b) then
                    local ta, tb = timeOf[own(a)], timeOf[own(b)]
                    if ta + 1 == tb then
                        pool.before1[#pool.before1 + 1] = { kind = "before1", a = a, b = b }
                    elseif ta < tb then
                        pool.earlier[#pool.earlier + 1] = { kind = "earlier", a = a, b = b }
                    end
                end
            end
        end
    end
    return pool
end

-- Draws clues from the pool by kind weight until it is empty.
local function drawOrder(pool, weights, rnd)
    -- Kinds in a fixed order before any draw: pairs() order may differ
    -- between LuaJIT builds, and two readers must deal the same case from
    -- the same seed (two-reader mode, daily challenge).
    local kinds = {}
    for kind, list in pairs(pool) do
        if weights[kind] and #list > 0 then kinds[#kinds + 1] = kind end
    end
    table.sort(kinds)
    for _, kind in ipairs(kinds) do shuffle(pool[kind], rnd) end
    local out = {}
    while true do
        local total = 0
        for _, kind in ipairs(kinds) do
            if #pool[kind] > 0 then total = total + weights[kind] end
        end
        if total == 0 then break end
        local r = (rnd(100000) / 100000) * total
        for _, kind in ipairs(kinds) do
            local list = pool[kind]
            if #list > 0 then
                r = r - weights[kind]
                if r <= 0 then
                    out[#out + 1] = table.remove(list)
                    break
                end
            end
        end
    end
    return out
end

-- Picks `n` distinct entries of `pool` (a list of content indices, or a
-- count meaning 1..count), leaving out those in `exclude`.
local function pick(pool, n, rnd, exclude)
    if type(pool) == "number" then
        local t = {}
        for i = 1, pool do t[i] = i end
        pool = t
    end
    local idx = {}
    for _, i in ipairs(pool) do
        if not (exclude and exclude[i]) then idx[#idx + 1] = i end
    end
    shuffle(idx, rnd)
    local out = {}
    for i = 1, n do out[i] = idx[i] end
    return out
end
Board.pick = pick

-- Builds a case. opts: level ("easy"|"medium"|"hard"), pools = { suspects,
-- places, objects, crimes } (each a list of content indices to draw from —
-- a theme pack — or a count meaning "1..count"; `sizes` is the old name),
-- excluded_suspect(crime_index) -> suspect index to leave out (the victim),
-- rnd (function(m) -> 1..m, default math.random).
-- opts.on_progress(fraction), optional: called before each drawn case.
-- Always returns a Board (every case it can return is solver-checked).
function Board.generate(opts)
    local rnd = opts.rnd or math.random
    local lvl = Board.LEVELS[opts.level] or Board.LEVELS.medium
    local n, k, tier = lvl.n, lvl.k, lvl.tier
    local rank = { same = 1, diff = 2, either = 3, earlier = 4, before1 = 5 }
    local best, best_miss, owner_best, best_t2, best_t3
    local tries = 0
    for try = 1, Board.MAX_TRIES do
        tries = try
        if opts.on_progress then opts.on_progress((try - 1) / Board.MAX_TRIES) end
        -- The solution: owner[c][v] = suspect owning value v of category c.
        local owner = { {} }
        for s = 1, n do owner[1][s] = s end
        for c = 2, k do owner[c] = perm(n, rnd) end

        -- True clues, one at a time, until the logic solver (limited to the
        -- level's tier) fills every grid. Every "same" clue is in the pool,
        -- so this always ends.
        local order = drawOrder(cluePool(n, k, owner, rnd), lvl.weights, rnd)
        local L = newLogic(n, k)
        local clues = {}
        -- An "is / is not" clue whose cell is already marked adds nothing,
        -- now or later, so it is skipped (fewer clues to prune).
        for _, cl in ipairs(order) do
            if not L.known(cl) then
                clues[#clues + 1] = cl
                L.add(cl)
                if L.run(tier) then break end
            end
        end

        -- Drop every clue the solver can do without: the plainest first, so
        -- the case keeps its more interesting ones. A drop is kept only if
        -- the solver, still limited to the level's tier, finishes.
        local idx = {}
        for i = 1, #clues do idx[i] = i end
        shuffle(idx, rnd)
        table.sort(idx, function(x, y)
            local rx, ry = rank[clues[x].kind], rank[clues[y].kind]
            if rx ~= ry then return rx < ry end
            return x < y
        end)
        local keep = {}
        for i = 1, #clues do keep[i] = true end
        local function kept()
            local t = {}
            for j = 1, #clues do if keep[j] then t[#t + 1] = clues[j] end end
            return t
        end
        for _, i in ipairs(idx) do
            keep[i] = false
            if not Board.logicSolve(n, k, kept(), tier) then keep[i] = true end
        end
        local final = kept()
        -- The order the case lists its clues in; the step counts below
        -- read them in that order, as a player would.
        shuffle(final, rnd)
        local _, t2, t3 = Board.logicSolve(n, k, final, tier, true)
        -- How far the case is from the level's window (0 = inside).
        local miss = math.max(0, lvl.min_t2 - t2) + math.max(0, t2 - lvl.max_t2)
                   + math.max(0, lvl.min_t3 - t3) + math.max(0, t3 - lvl.max_t3)
        if not best or miss < best_miss then
            best, best_miss, owner_best = final, miss, owner
            best_t2, best_t3 = t2, t3
        end
        if miss == 0 then break end
    end

    local final, owner = best, owner_best
    local sizes = opts.pools or opts.sizes or {}
    local crime = pick(sizes.crimes or 1, 1, rnd)[1]
    local exclude = {}
    local victim = opts.excluded_suspect and opts.excluded_suspect(crime)
    if victim then exclude[victim] = true end
    local b = Board.new{
        n = n, k = k, level = opts.level, owner = owner, clues = final, crime = crime,
        names = {
            pick(sizes.suspects or n, n, rnd, exclude),
            pick(sizes.places or n, n, rnd),
            pick(sizes.objects or n, n, rnd),
        },
        -- The key fact the case opens with: the time of the crime,
        -- or, with no times, where it happened.
        key = { c = k >= 4 and 4 or 2, v = rnd(n) },
    }
    b.gen_tries = tries
    b.gen_t2, b.gen_t3 = best_t2, best_t3
    return b
end

-- ---------------------------------------------------------------------------
-- The case being played
-- ---------------------------------------------------------------------------

function Board.new(o)
    local self = setmetatable({}, Board)
    self.n, self.k   = o.n, o.k
    self.level       = o.level or "medium"
    self.owner       = o.owner
    self.clues       = o.clues
    self.crime       = o.crime or 1
    self.names       = o.names
    self.key         = o.key
    self.marks       = o.marks or {}
    self.struck      = o.struck or {}
    self.hints_used  = o.hints_used or 0
    self.over        = o.over     -- nil | "solved" | "failed" | "revealed"
    self.accused     = o.accused
    self.undo        = {}
    self.pairs = {}
    for a = 1, self.k do
        for b = a + 1, self.k do self.pairs[#self.pairs + 1] = { a, b } end
    end
    for p = 1, #self.pairs do
        self.marks[p] = self.marks[p] or {}
        for r = 1, self.n do
            self.marks[p][r] = self.marks[p][r] or {}
            for c = 1, self.n do self.marks[p][r][c] = self.marks[p][r][c] or 0 end
        end
    end
    return self
end

function Board:serialize()
    return {
        n = self.n, k = self.k, level = self.level, owner = self.owner, clues = self.clues,
        crime = self.crime, names = self.names, key = self.key, marks = self.marks,
        struck = self.struck, hints_used = self.hints_used, over = self.over, accused = self.accused,
    }
end

function Board.load(t)
    if type(t) ~= "table" or type(t.owner) ~= "table" or type(t.clues) ~= "table" then return nil end
    return Board.new(t)
end

-- Suspect owning value v of category c.
function Board:ownerOf(c, v)
    return self.owner[c][v]
end

-- Value of category c held by suspect s.
function Board:valueOf(c, s)
    for v = 1, self.n do
        if self.owner[c][v] == s then return v end
    end
end

-- The answer: the suspect behind the key fact, and their place and object.
function Board:culprit()
    local s = self.owner[self.key.c][self.key.v]
    return s, self:valueOf(2, s), self:valueOf(3, s)
end

-- Is cell (r, c) of pair p a "yes" in the solution?
function Board:truth(p, r, c)
    local pa, pb = self.pairs[p][1], self.pairs[p][2]
    return self.owner[pa][r] == self.owner[pb][c]
end

-- Marks: 0 empty, 1 cross (no), 2 dot (yes).
Board.EMPTY, Board.NO, Board.YES = 0, 1, 2

function Board:getMark(p, r, c)
    return self.marks[p][r][c]
end

-- Tap: empty -> cross -> dot -> empty. A dot crosses out the rest of its row
-- and column (only empty cells), as on paper; one tap is one Undo step.
function Board:cycle(p, r, c)
    if self.over then return false end
    local m = self.marks[p]
    local step = {}
    local function set(rr, cc, v)
        step[#step + 1] = { p = p, r = rr, c = cc, old = m[rr][cc] }
        m[rr][cc] = v
    end
    local nextv = (m[r][c] + 1) % 3
    set(r, c, nextv)
    if nextv == Board.YES then
        for i = 1, self.n do
            if i ~= c and m[r][i] == Board.EMPTY then set(r, i, Board.NO) end
            if i ~= r and m[i][c] == Board.EMPTY then set(i, c, Board.NO) end
        end
    end
    self.undo[#self.undo + 1] = step
    return true
end

function Board:setMark(p, r, c, v)
    local m = self.marks[p]
    self.undo[#self.undo + 1] = { { p = p, r = r, c = c, old = m[r][c] } }
    m[r][c] = v
end

function Board:canUndo()
    return #self.undo > 0 and not self.over
end

function Board:undoStep()
    local step = table.remove(self.undo)
    if not step then return false end
    for i = #step, 1, -1 do
        local s = step[i]
        self.marks[s.p][s.r][s.c] = s.old
    end
    return true
end

function Board:toggleStruck(i)
    self.struck[i] = not self.struck[i] or nil
end

-- Accuse: right on all three counts solves the case; anything else fails it.
function Board:accuse(s, place, object)
    local cs, cp, co = self:culprit()
    self.accused = { s, place, object }
    self.over = (s == cs and place == cp and object == co) and "solved" or "failed"
    return self.over == "solved"
end

-- One-way: fills the grids with the answer and closes the case.
function Board:reveal()
    for p = 1, #self.pairs do
        for r = 1, self.n do
            for c = 1, self.n do
                self.marks[p][r][c] = self:truth(p, r, c) and Board.YES or Board.NO
            end
        end
    end
    self.over = "revealed"
end

-- Number of wrong marks (a dot on a no, a cross on a yes).
function Board:mistakes()
    local n = 0
    for p = 1, #self.pairs do
        for r = 1, self.n do
            for c = 1, self.n do
                local m = self.marks[p][r][c]
                if m ~= 0 and (m == Board.YES) ~= self:truth(p, r, c) then n = n + 1 end
            end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Hints (game-common convention: findHint / applyHint / noteHintUsed /
-- getHintsUsed, steps carry r, c and a tag — here the pair grid)
-- ---------------------------------------------------------------------------

-- The clue (index) that states cell (p, r, c) directly, if one does.
function Board:directClue(p, r, c)
    local pa, pb = self.pairs[p][1], self.pairs[p][2]
    local function is(e, cat, v) return e.c == cat and e.v == v end
    for i, cl in ipairs(self.clues) do
        if cl.kind == "same" or cl.kind == "diff" then
            if (is(cl.a, pa, r) and is(cl.b, pb, c)) or (is(cl.a, pb, c) and is(cl.b, pa, r)) then
                return i
            end
        end
    end
end

function Board:findHint()
    if self.over then return nil, "complete" end
    local mistakes, direct, yes, no = {}, {}, {}, {}
    for p = 1, #self.pairs do
        for r = 1, self.n do
            for c = 1, self.n do
                local m, t = self.marks[p][r][c], self:truth(p, r, c)
                local want = t and Board.YES or Board.NO
                if m ~= 0 and m ~= want then
                    mistakes[#mistakes + 1] = { kind = "mistake", r = r, c = c, tag = p, value = want }
                elseif m == 0 then
                    local step = { kind = "fill", r = r, c = c, tag = p, value = want }
                    step.clue = self:directClue(p, r, c)
                    if step.clue then
                        direct[#direct + 1] = step
                    elseif t then
                        yes[#yes + 1] = step
                    else
                        no[#no + 1] = step
                    end
                end
            end
        end
    end
    local pickFrom = (#mistakes > 0 and mistakes) or (#direct > 0 and direct) or (#yes > 0 and yes) or no
    if #pickFrom == 0 then return nil, "complete" end
    return pickFrom[1]
end

function Board:applyHint(step)
    if not step or self.over then return false end
    self:setMark(step.tag, step.r, step.c, step.value)
    return true
end

function Board:noteHintUsed()
    self.hints_used = self.hints_used + 1
end

function Board:getHintsUsed()
    return self.hints_used
end

return Board
