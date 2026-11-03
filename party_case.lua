-- ---------------------------------------------------------------------------
-- party_case.lua — one case of a "· multiplayer" match (pure Lua, no UI).
--
-- The players investigate together around one reader. The clues come out one
-- at a time ("Next clue"); anyone may accuse at any moment, once per case:
--   * right on all three counts: that player wins the case and scores
--     1 point + 1 per clue still hidden (accusing early pays);
--   * wrong: that player may not accuse again in this case (they keep
--     helping the others);
--   * when every player has accused wrongly, the case is lost for all.
-- The scores themselves live in game-common's party.lua tables.
-- ---------------------------------------------------------------------------

local PartyCase = {}

PartyCase.FIRST_CLUES = 1  -- clues shown when a case opens

-- total: the case's number of clues; players: number of seats.
function PartyCase.new(total, players)
    local c = {
        total    = total,
        revealed = math.min(PartyCase.FIRST_CLUES, total),
        out      = {},   -- out[i] == true: player i accused wrongly
        winner   = nil,  -- seat of the player who solved it
        points   = 0,    -- what the winner scored
        lost     = false,
    }
    for i = 1, players do c.out[i] = false end
    return c
end

function PartyCase.hidden(c)
    return c.total - c.revealed
end

-- Reveals one more clue; false when they are all out already.
function PartyCase.revealNext(c)
    if c.revealed >= c.total or PartyCase.isOver(c) then return false end
    c.revealed = c.revealed + 1
    return true
end

-- What a right accusation is worth right now.
function PartyCase.worth(c)
    return 1 + PartyCase.hidden(c)
end

function PartyCase.isOver(c)
    return c.winner ~= nil or c.lost
end

function PartyCase.canAccuse(c, i)
    return not PartyCase.isOver(c) and c.out[i] == false
end

-- Seats still allowed to accuse, in seat order.
function PartyCase.accusers(c)
    local list = {}
    for i = 1, #c.out do
        if PartyCase.canAccuse(c, i) then list[#list + 1] = i end
    end
    return list
end

-- Player i accuses; correct says whether all three counts were right.
-- Returns "win" (c.points is what i scored), "wrong" (i is out, others may
-- still accuse) or "lost" (that was the last player allowed to accuse).
function PartyCase.accuse(c, i, correct)
    if not PartyCase.canAccuse(c, i) then return nil end
    if correct then
        c.winner = i
        c.points = PartyCase.worth(c)
        return "win"
    end
    c.out[i] = true
    if #PartyCase.accusers(c) == 0 then
        c.lost = true
        return "lost"
    end
    return "wrong"
end

-- Show solution / give up: nobody scores.
function PartyCase.giveUp(c)
    if not PartyCase.isOver(c) then c.lost = true end
end

function PartyCase.copy(c)
    local t = {}
    for k, v in pairs(c) do t[k] = v end
    t.out = {}
    for i, v in ipairs(c.out) do t.out[i] = v end
    return t
end

-- Validates a restored case against the board and the seats; nil if unusable.
function PartyCase.restore(t, total, players)
    if type(t) ~= "table" or type(t.out) ~= "table" or #t.out ~= players then return nil end
    if tonumber(t.total) ~= total then return nil end
    local c = PartyCase.new(total, players)
    c.revealed = math.max(0, math.min(total, tonumber(t.revealed) or c.revealed))
    for i = 1, players do c.out[i] = t.out[i] == true end
    if type(t.winner) == "number" and t.winner >= 1 and t.winner <= players then
        c.winner = t.winner
        c.points = tonumber(t.points) or 0
    end
    c.lost = t.lost == true and c.winner == nil
    return c
end

-- The match is over once its last case is.
function PartyCase.matchOver(round, rounds, case_over)
    return case_over and round >= rounds
end

return PartyCase
