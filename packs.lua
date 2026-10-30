-- ---------------------------------------------------------------------------
-- packs.lua — theme packs (no UI): which crimes, suspects, places and
-- objects of a content file a case may draw from.
-- ---------------------------------------------------------------------------

local Packs = {}

Packs.IDS = { "all", "history", "art", "science", "fiction", "world" }

-- Below this many entries a pack can't fill a hard case with variety, and
-- falls back to the whole content.
Packs.MIN = { crimes = 1, suspects = 8, places = 6, objects = 6 }

local function inPack(e, pack)
    if pack == "all" or type(e) ~= "table" or not e.packs then return true end
    for _, p in ipairs(e.packs) do
        if p == pack then return true end
    end
    return false
end

-- Returns pools = { crimes, suspects, places, objects } (lists of indices
-- into the content lists) and the victim lookup for Board.generate.
function Packs.pools(content, pack)
    pack = pack or "all"
    local pools = {}
    for _, key in ipairs({ "crimes", "suspects", "places", "objects" }) do
        local list = {}
        for i, e in ipairs(content[key]) do
            if inPack(e, pack) then list[#list + 1] = i end
        end
        if #list < Packs.MIN[key] then
            list = {}
            for i = 1, #content[key] do list[i] = i end
        end
        pools[key] = list
    end
    local index = {}
    for i, e in ipairs(content.suspects) do
        index[type(e) == "table" and e.name or e] = i
    end
    local function victim(crime)
        local c = content.crimes[crime]
        return c and c.victim and index[c.victim] or nil
    end
    return pools, victim
end

-- How many entries of each kind a pack holds.
function Packs.count(content, pack)
    local pools = Packs.pools(content, pack)
    return { crimes = #pools.crimes, suspects = #pools.suspects, places = #pools.places, objects = #pools.objects }
end

return Packs
