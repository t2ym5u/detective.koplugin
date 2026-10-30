-- ---------------------------------------------------------------------------
-- board.lua — a Detective case: generator, solver, the player's logic grid.
-- Pure Lua, no UI (wording lives in clues.lua, names in content_*.lua).
--
-- A case has N suspects and K categories: 1 = suspect, 2 = place,
-- 3 = object, 4 = time (ordered). Every value of every category belongs to
-- exactly one suspect; the solution is, per category, which suspect owns
-- each value. Clues constrain that, and the generator keeps adding true
-- clues until exactly one solution is left, then drops every clue the
-- solution doesn't need.
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

Board.LEVELS = {
    easy   = { n = 3, k = 3, weights = { same = 3,   diff = 4, either = 2 } },
    medium = { n = 4, k = 4, weights = { same = 1.5, diff = 4, either = 2,   before1 = 1.5, earlier = 1.5 } },
    hard   = { n = 5, k = 4, weights = { same = 0.6, diff = 4, either = 2.5, before1 = 2,   earlier = 2 } },
}
Board.LEVEL_ORDER = { "easy", "medium", "hard" }

-- Search budgets, in solver nodes. A case that needs more is thrown away and
-- drawn again, so generation time is bounded on any device.
Board.COUNT_BUDGET = 30000   -- one solution count
Board.PRUNE_BUDGET = 60000   -- one count while dropping unneeded clues
Board.TRY_BUDGET   = 120000  -- one drawn solution and its clues
Board.GEN_BUDGET   = 400000  -- the whole case; then one last plain try
Board.MAX_TRIES    = 12
Board.HARD_CAP     = 1500000 -- past this, pruning stops and keeps what is left
-- The last-resort clue mix: plain "same"/"diff" clues pin a solution down
-- fast, so this try practically always fits.
Board.FALLBACK_WEIGHTS = { same = 3, diff = 4, either = 1 }

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
    local kinds = {}
    for kind, list in pairs(pool) do
        if weights[kind] and #list > 0 then
            shuffle(list, rnd)
            kinds[#kinds + 1] = kind
        end
    end
    table.sort(kinds)
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
-- Returns a Board, or nil + "budget" if no case fitted the budgets.
function Board.generate(opts)
    local rnd = opts.rnd or math.random
    local lvl = Board.LEVELS[opts.level] or Board.LEVELS.medium
    local n, k = lvl.n, lvl.k
    local spent = 0
    for try = 1, Board.MAX_TRIES + 1 do
        local last = try > Board.MAX_TRIES or spent > Board.GEN_BUDGET
        local weights = last and Board.FALLBACK_WEIGHTS or lvl.weights
        local try_spent = 0
        -- The solution: owner[c][v] = suspect owning value v of category c.
        local owner = { {} }
        for s = 1, n do owner[1][s] = s end
        for c = 2, k do owner[c] = perm(n, rnd) end

        local order = drawOrder(cluePool(n, k, owner, rnd), weights, rnd)
        local clues, ok = {}, false
        for _, cl in ipairs(order) do
            clues[#clues + 1] = cl
            local cnt, used = Board.countSolutions(n, k, clues, 2)
            spent, try_spent = spent + used, try_spent + used
            if cnt == nil then break end
            if cnt == 1 then ok = true break end
            if try_spent > Board.TRY_BUDGET and not last then break end
        end
        if ok then
            -- Drop what the solution doesn't need: the plainest clues go
            -- first, so the case keeps its more interesting ones.
            local rank = { same = 1, diff = 2, either = 3, earlier = 4, before1 = 5 }
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
            for _, i in ipairs(idx) do
                if spent > Board.HARD_CAP then break end
                keep[i] = false
                local trial = {}
                for j = 1, #clues do if keep[j] then trial[#trial + 1] = clues[j] end end
                local cnt, used = Board.countSolutions(n, k, trial, 2, Board.PRUNE_BUDGET)
                spent = spent + used
                if cnt ~= 1 then keep[i] = true end
            end
            local final = {}
            for j = 1, #clues do if keep[j] then final[#final + 1] = clues[j] end end
            shuffle(final, rnd)

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
            b.gen_nodes = spent
            b.gen_tries = try
            return b
        end
        if last then break end
    end
    return nil, "budget"
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
