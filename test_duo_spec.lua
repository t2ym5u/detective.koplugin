-- Case for Two: both readers deal the same case from a game code, and each
-- shows half of its clues (odd ones / even ones). A case's clues are pruned
-- to the bare minimum, so neither half can be enough on its own.
package.path = "./?.lua;./common/?.lua;" .. package.path
local Board = dofile("board.lua")
local Duo = require("duo")

local function deal(seed, level)
    return Board.generate{ level = level, rnd = Duo.rng(seed, "detective"):fn(),
        pools = { suspects = 20, places = 20, objects = 20, crimes = 5 } }
end

describe("Case for Two", function()
    it("deals the same case on both readers", function()
        for _, level in ipairs(Board.LEVEL_ORDER) do
            for seed = 1, 3 do
                assert.same(deal(seed, level):serialize(), deal(seed, level):serialize())
            end
        end
    end)

    it("needs both halves of the clues", function()
        for _, level in ipairs({ "easy", "medium" }) do
            for seed = 1, 4 do
                local b = deal(seed, level)
                local tier = Board.LEVELS[level].tier
                local odd, even = {}, {}
                for i, cl in ipairs(b.clues) do
                    if i % 2 == 1 then odd[#odd + 1] = cl else even[#even + 1] = cl end
                end
                assert.is_truthy(Board.logicSolve(b.n, b.k, b.clues, tier))
                assert.is_falsy(Board.logicSolve(b.n, b.k, odd, tier))
                assert.is_falsy(Board.logicSolve(b.n, b.k, even, tier))
            end
        end
    end)
end)
