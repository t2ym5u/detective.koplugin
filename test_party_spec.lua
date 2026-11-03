local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. DIR .. "common/?.lua;" .. package.path

-- party.lua needs i18n and ffi/util only for its wording.
package.loaded["i18n"] = package.loaded["i18n"] or setmetatable({}, { __call = function(_, s) return s end })
package.loaded["ffi/util"] = package.loaded["ffi/util"] or {
    template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end,
}

local PartyCase = require("party_case")
local Party     = require("party")
local Board     = require("board")
local Packs     = require("packs")

describe("Detective multiplayer case", function()
    it("opens with one clue and reveals the rest one at a time", function()
        local c = PartyCase.new(5, 3)
        assert.are.equal(1, c.revealed)
        assert.are.equal(4, PartyCase.hidden(c))
        for _ = 1, 4 do assert.is_true(PartyCase.revealNext(c)) end
        assert.are.equal(5, c.revealed)
        assert.is_false(PartyCase.revealNext(c))
    end)

    it("a right accusation scores 1 + the clues still hidden", function()
        local c = PartyCase.new(6, 2)
        PartyCase.revealNext(c)                     -- 2 shown, 4 hidden
        assert.are.equal(5, PartyCase.worth(c))
        assert.are.equal("win", PartyCase.accuse(c, 2, true))
        assert.are.equal(2, c.winner)
        assert.are.equal(5, c.points)
        assert.is_true(PartyCase.isOver(c))
        assert.is_false(PartyCase.revealNext(c))
        assert.is_nil(PartyCase.accuse(c, 1, true))   -- closed
    end)

    it("all clues out is still worth 1", function()
        local c = PartyCase.new(3, 2)
        while PartyCase.revealNext(c) do end
        assert.are.equal(1, PartyCase.worth(c))
    end)

    it("a wrong accusation rules that player out, the others go on", function()
        local c = PartyCase.new(5, 3)
        assert.are.equal("wrong", PartyCase.accuse(c, 1, false))
        assert.is_false(PartyCase.canAccuse(c, 1))
        assert.is_nil(PartyCase.accuse(c, 1, true))    -- once per case
        assert.are.same({ 2, 3 }, PartyCase.accusers(c))
        assert.are.equal("wrong", PartyCase.accuse(c, 3, false))
        assert.are.equal("win", PartyCase.accuse(c, 2, true))
        assert.are.equal(2, c.winner)
    end)

    it("the case is lost when everyone accused wrongly", function()
        local c = PartyCase.new(5, 2)
        assert.are.equal("wrong", PartyCase.accuse(c, 1, false))
        assert.are.equal("lost", PartyCase.accuse(c, 2, false))
        assert.is_true(c.lost)
        assert.is_nil(c.winner)
        assert.are.same({}, PartyCase.accusers(c))
    end)

    it("giving up closes the case with no winner", function()
        local c = PartyCase.new(5, 2)
        PartyCase.giveUp(c)
        assert.is_true(PartyCase.isOver(c))
        assert.is_nil(c.winner)
    end)

    it("copy / restore round-trips and rejects a mismatch", function()
        local c = PartyCase.new(7, 3)
        PartyCase.revealNext(c); PartyCase.revealNext(c)
        PartyCase.accuse(c, 2, false)
        local t = PartyCase.copy(c)
        c.out[3] = true                               -- the copy doesn't follow
        local r = PartyCase.restore(t, 7, 3)
        assert.are.equal(3, r.revealed)
        assert.are.same({ false, true, false }, r.out)
        assert.is_false(r.lost)
        assert.is_nil(PartyCase.restore(t, 8, 3))      -- another case
        assert.is_nil(PartyCase.restore(t, 7, 4))      -- other players
        assert.is_nil(PartyCase.restore(nil, 7, 3))
        local won = PartyCase.copy(r)
        PartyCase.accuse(won, 1, true)
        local w = PartyCase.restore(PartyCase.copy(won), 7, 3)
        assert.are.equal(1, w.winner)
        assert.are.equal(5, w.points)
        assert.is_true(PartyCase.isOver(w))
    end)

    it("the match ends with its last case", function()
        assert.is_false(PartyCase.matchOver(2, 3, true))
        assert.is_false(PartyCase.matchOver(3, 3, false))
        assert.is_true(PartyCase.matchOver(3, 3, true))
    end)

    it("plays a match on real cases: scores add up over the rounds", function()
        math.randomseed(5)
        local ct = dofile(DIR .. "content_en.lua")
        local scores = Party.newScores({ "Ann", "Bob" })
        local rounds = 3
        for _r = 1, rounds do
            Party.nextRound(scores)
            local pools, victim = Packs.pools(ct, "all")
            local b = assert(Board.generate{ level = "easy", pools = pools, excluded_suspect = victim })
            local c = PartyCase.new(#b.clues, 2)
            local s, pl, ob = b:culprit()
            -- Ann guesses wrong straight away, Bob waits for one more clue.
            assert.are.equal("wrong", PartyCase.accuse(c, 1, (s % b.n) + 1 == s))
            PartyCase.revealNext(c)
            local worth = PartyCase.worth(c)
            assert.are.equal("win", PartyCase.accuse(c, 2, b:accuse(s, pl, ob)))
            Party.award(scores, c.winner, c.points)
            assert.are.equal(#b.clues - 2 + 1, worth)
            assert.is_true(PartyCase.matchOver(scores.round, rounds, b.over ~= nil) == (scores.round == rounds))
        end
        assert.are.equal(0, scores.points[1])
        assert.is_true(scores.points[2] >= 3)
        assert.are.same({ 2 }, Party.leaders(scores))
        local back = Party.restoreScores(Party.copyScores(scores))
        assert.are.equal(scores.points[2], back.points[2])
        assert.are.equal(3, back.round)
    end)
end)
