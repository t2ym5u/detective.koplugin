-- ---------------------------------------------------------------------------
-- clues.lua — turns a case (board.lua) into sentences, in French or English.
--
-- This is content wording, so it follows the case's own language, not
-- KOReader's: a French case reads in French on an English reader.
--
-- Each clue kind has several phrasings. Which one a clue gets is derived
-- from the clue itself, so it never changes between two looks at the same
-- case (or after a save and reload).
-- ---------------------------------------------------------------------------

local Clues = {}
Clues.__index = Clues

local FIRST_HOUR = 14

-- {S} subject of a (capitalised when it opens the sentence), {s} the same
-- in the middle of one; {B}/{b} the same for b; {Pa}/{Pb} predicate of a/b
-- ("was at the Louvre"), {Na}/{Nb} negated; {E} "either X or Y" predicate
-- over b and b2; {b2} subject of b2.
local W = {
    fr = {
        person_at     = "la personne qui était %s",
        person_with   = "la personne qui avait %s",
        person_time   = "la personne qui était là à %s",
        is            = "est %s",
        is_not        = "n'est pas %s",
        was_at        = "était %s",
        was_not_at    = "n'était pas %s",
        had           = "avait %s",
        had_not       = "n'avait pas %s",
        time          = "était là à %s",
        time_not      = "n'était pas là à %s",
        either_is     = "est soit %s, soit %s",
        either_at     = "était soit %s, soit %s",
        either_had    = "avait soit %s, soit %s",
        either_time   = "était là soit à %s, soit à %s",
        key_time      = "Le méfait a eu lieu à %s.",
        key_place     = "Le méfait a eu lieu %s.",
        ask           = "Qui, où, avec quoi ?",
        answer        = "%s, %s, avec %s.",
        same = {
            "{S} {Pb}.",
            "Un témoin l'affirme : {s} {Pb}.",
            "{S} et {b} ne font qu'un.",
            "Aucun doute : {s} {Pb}.",
        },
        diff = {
            "{S} {Nb}.",
            "{S} et {b} sont deux personnes différentes.",
            "C'est sûr : {s} {Nb}.",
            "Contrairement aux rumeurs, {s} {Nb}.",
        },
        either = {
            "{S} {E}.",
            "Deux possibilités : {s} {E}.",
            "{B} ou {b2} : l'un des deux, c'est {s}.",
        },
        before1 = {
            "{S} était là une heure avant {b}.",
            "{B} était là une heure après {s}.",
            "Une heure après {s}, {b} était là.",
        },
        earlier = {
            "{S} était là plus tôt que {b}.",
            "{B} était là plus tard que {s}.",
            "{S} était là avant {b}, mais pas forcément juste avant.",
        },
    },
    en = {
        person_at     = "the person %s",
        person_with   = "the person with %s",
        person_time   = "the person who was there at %s",
        is            = "is %s",
        is_not        = "is not %s",
        was_at        = "was %s",
        was_not_at    = "was not %s",
        had           = "had %s",
        had_not       = "did not have %s",
        time          = "was there at %s",
        time_not      = "was not there at %s",
        either_is     = "is either %s or %s",
        either_at     = "was either %s or %s",
        either_had    = "had either %s or %s",
        either_time   = "was there either at %s or at %s",
        key_time      = "It happened at %s.",
        key_place     = "It happened %s.",
        ask           = "Who, where, with what?",
        answer        = "%s, %s, with %s.",
        same = {
            "{S} {Pb}.",
            "A witness is certain: {s} {Pb}.",
            "{S} and {b} are one and the same.",
            "No doubt about it: {s} {Pb}.",
        },
        diff = {
            "{S} {Nb}.",
            "{S} and {b} are two different people.",
            "One thing is sure: {s} {Nb}.",
            "Despite the rumours, {s} {Nb}.",
        },
        either = {
            "{S} {E}.",
            "Two possibilities: {s} {E}.",
            "{B} or {b2}: one of the two is {s}.",
        },
        before1 = {
            "{S} was there one hour before {b}.",
            "{B} was there one hour after {s}.",
            "One hour after {s}, {b} was there.",
        },
        earlier = {
            "{S} was there earlier than {b}.",
            "{B} was there later than {s}.",
            "{S} was there before {b}, though not necessarily just before.",
        },
    },
}
Clues.WORDING = W

-- content: the loaded content_<lang>.lua table; board: the case.
function Clues.new(content, lang, board)
    local self = setmetatable({}, Clues)
    self.content = content
    self.lang    = W[lang] and lang or "en"
    self.w       = W[self.lang]
    self.board   = board
    return self
end

function Clues:hour(v)
    local h = FIRST_HOUR + v - 1
    if self.lang == "fr" then return h .. "\194\160h" end
    local h12 = h > 12 and h - 12 or h
    return h12 .. (h >= 12 and " pm" or " am")
end

local function upperFirst(s)
    -- Sentences start with an ASCII letter or a name; names keep their case.
    return (s:gsub("^%l", string.upper))
end

local function suspect(ct, i)
    local e = ct.suspects[i]
    if type(e) == "string" then return e, e end
    return e.name, e.short or e.name
end

-- Short grid label of value v of category c.
function Clues:label(c, v)
    local b, ct = self.board, self.content
    if c == 1 then
        local _, short = suspect(ct, b.names[1][v])
        return short
    end
    if c == 2 then return ct.places[b.names[2][v]].label end
    if c == 3 then return ct.objects[b.names[3][v]].label end
    return self:hour(v)
end

function Clues:suspectName(v)
    return (suspect(self.content, self.board.names[1][v]))
end
function Clues:placeAt(v) return self.content.places[self.board.names[2][v]].at end
function Clues:objectName(v) return self.content.objects[self.board.names[3][v]].name end

-- Noun phrase for an entity: "Mozart", "the person with the umbrella".
function Clues:subject(e)
    local w = self.w
    if e.c == 1 then return self:suspectName(e.v) end
    if e.c == 2 then return string.format(w.person_at, self:placeAt(e.v)) end
    if e.c == 3 then return string.format(w.person_with, self:objectName(e.v)) end
    return string.format(w.person_time, self:hour(e.v))
end

-- Predicate "was at the Louvre" / "did not have the umbrella".
function Clues:predicate(e, negative)
    local w = self.w
    if e.c == 1 then return string.format(negative and w.is_not or w.is, self:suspectName(e.v)) end
    if e.c == 2 then return string.format(negative and w.was_not_at or w.was_at, self:placeAt(e.v)) end
    if e.c == 3 then return string.format(negative and w.had_not or w.had, self:objectName(e.v)) end
    return string.format(negative and w.time_not or w.time, self:hour(e.v))
end

function Clues:eitherPredicate(b, b2)
    local w = self.w
    if b.c == 1 then return string.format(w.either_is, self:suspectName(b.v), self:suspectName(b2.v)) end
    if b.c == 2 then return string.format(w.either_at, self:placeAt(b.v), self:placeAt(b2.v)) end
    if b.c == 3 then return string.format(w.either_had, self:objectName(b.v), self:objectName(b2.v)) end
    return string.format(w.either_time, self:hour(b.v), self:hour(b2.v))
end

-- Which phrasing a clue gets: a hash of what it says.
function Clues.variant(cl, count)
    local h = #cl.kind * 7 + cl.a.c * 11 + cl.a.v * 13 + cl.b.c * 17 + cl.b.v * 19
    if cl.b2 then h = h + cl.b2.c * 23 + cl.b2.v * 29 end
    return h % count + 1
end

-- n: the clue's number in the case (spreads the phrasings within a case;
-- the order is fixed when the case is made, so it stays stable too).
function Clues:text(cl, n, force_variant)
    local frames = self.w[cl.kind]
    local i = force_variant or ((Clues.variant(cl, #frames) + (n or 0)) % #frames + 1)
    local frame = frames[i]
    local sa, sb = self:subject(cl.a), self:subject(cl.b)
    local fields = {
        S = upperFirst(sa), s = sa, B = upperFirst(sb), b = sb,
        b2 = cl.b2 and self:subject(cl.b2) or "",
    }
    if cl.kind == "same" or cl.kind == "diff" then
        fields.Pb = self:predicate(cl.b, false)
        fields.Nb = self:predicate(cl.b, true)
    elseif cl.kind == "either" then
        fields.E = self:eitherPredicate(cl.b, cl.b2)
    end
    local out = frame:gsub("{(%w+)}", function(k) return fields[k] or "" end)
    return out
end

-- The case as told at the top of the clue list.
function Clues:caseText()
    local b = self.board
    local crime = self.content.crimes[b.crime] or self.content.crimes[1]
    local key
    if b.key.c == 4 then
        key = string.format(self.w.key_time, self:hour(b.key.v))
    else
        key = string.format(self.w.key_place, self:placeAt(b.key.v))
    end
    return crime.text .. " " .. key .. " " .. self.w.ask
end

-- "Mozart, at the Louvre, with the umbrella."
function Clues:answer(s, place, object)
    return upperFirst(string.format(self.w.answer, self:suspectName(s), self:placeAt(place), self:objectName(object)))
end

function Clues:crimeText()
    local crime = self.content.crimes[self.board.crime] or self.content.crimes[1]
    return crime.text
end

return Clues
