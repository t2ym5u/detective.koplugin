local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local GenProgress = require("gen_progress")
local MenuHelper = require("menu_helper")
local Party      = require("party")
local ScreenBase = require("screen_base")

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Board     = lrequire("board")
local Packs     = lrequire("packs")
local Clues     = lrequire("clues")
local LogicGrid = lrequire("logic_grid")
local PartyCase = lrequire("party_case")
local Content   = lrequire("content")

local DeviceScreen = Device.screen
local DPI_SCALE = DeviceScreen:scaleBySize(1000) / 1000

local function pxFace(px, bold)
    return Font:getFace(bold and "tfont" or "cfont", math.max(8, math.floor(px / DPI_SCALE)))
end

local RULES_EN = [[
Detective — Rules

A mischief has been done. Each suspect was in exactly one place, had exactly one object and (in Medium and Hard) came at exactly one time; no two suspects share a place, an object or a time. The case tells you one fact about the culprit (when, or where, it happened). The clues tell you the rest — and only one answer fits them all.

The grid: each tab (Who·Where, Who·What, Where·What…) is one table of the logic grid. Tap a cell once for a cross (no), twice for a dot (yes), a third time to clear it. A dot crosses out the rest of its row and column for you. Undo takes back the last tap.

Tap a clue to grey it out once you have used it. When the clues don't fit on the screen, ◀ and ▶ turn their pages.

"One hour before" means the next time slot; "earlier than" means any earlier slot.

Accuse when you know: pick the culprit, the place and the object. One accusation per case — get any of the three wrong and the case is lost.

Hint: the first tap points at a cell (a wrong mark first), the second fills it in. Show solution fills the grid and closes the case.

Easy: 3 suspects, places and objects. Medium: 4 suspects, with times. Hard: 5 suspects, with times. Daily Challenge: the same case for everyone today.
]]

local RULES_FR = [[
Enquêtes — Règles

Un méfait a été commis. Chaque suspect était dans un seul lieu, avait un seul objet et (en Moyen et Difficile) était là à une seule heure ; deux suspects ne partagent jamais un lieu, un objet ou une heure. L'affaire vous donne un fait sur le coupable (quand, ou où, cela s'est passé). Les indices donnent le reste — et une seule réponse les respecte tous.

La grille : chaque onglet (Qui·Où, Qui·Quoi, Où·Quoi…) est un tableau de la grille logique. Touchez une case une fois pour une croix (non), deux fois pour un rond (oui), une troisième fois pour l'effacer. Un rond barre pour vous le reste de sa ligne et de sa colonne. Annuler reprend le dernier geste.

Touchez un indice pour le griser une fois utilisé. Quand les indices ne tiennent pas à l'écran, ◀ et ▶ tournent leurs pages.

« Une heure avant » veut dire le créneau juste avant ; « plus tôt que » veut dire n'importe quel créneau avant.

Accusez quand vous savez : choisissez le coupable, le lieu et l'objet. Une seule accusation par affaire — une seule erreur sur les trois et l'affaire est perdue.

Astuce : le premier appui désigne une case (d'abord une marque fausse), le second la remplit. Voir la solution remplit la grille et clôt l'affaire.

Facile : 3 suspects, lieux et objets. Moyen : 4 suspects, avec les heures. Difficile : 5 suspects, avec les heures. Défi du jour : la même affaire pour tout le monde aujourd'hui.
]]

local RULES_PARTY_EN = [[
Detective · multiplayer — Rules

Setup: lay the reader in the middle of the table. In the menu: Players (2 to 8) and Player names, Rounds (1, 3, 5 or 7 cases per match), Difficulty, Language and Case pack.

The case: a mischief has been done. Each suspect was in exactly one place, had exactly one object and (in Medium and Hard) came at exactly one time; no two suspects share a place, an object or a time. The case tells you one fact about the culprit; the clues tell you the rest — and only one answer fits them all.

A round = one case. It opens with a single clue: read it aloud. Whenever the table wants more, tap Next clue and one more clue appears. Everyone thinks together; anyone may use the grid (in portrait, Grid and Clues swap the views): tap a cell once for a cross (no), twice for a dot (yes), a third time to clear it; Undo takes back the last tap. Tap a clue to grey it out.

Accusing: anyone may accuse at any moment, but only once per case. Tap Accuse, pick who is accusing, then the culprit, the place and the object.
• Right on all three counts: that player wins the case.
• Wrong: that player can't accuse again in this case — they keep helping the others. Nothing about the answer is shown.
• When every player has accused wrongly, the case is lost and the answer is shown.
The top of the clue page shows who may still accuse, and the scores.

Scoring: a right accusation scores 1 point + 1 per clue still hidden — the bolder, the richer. Example: a case of 7 clues solved with 3 shown scores 1 + 4 = 5 points; solved with all 7 shown, 1 point. A lost case, or one given up with Show solution, scores nothing. The status line shows the case number, the clues shown and what a right accusation is worth now (Prize).

End of the match: after the last case the final scoreboard names the winner; equal best scores are a tie. The action bar offers Next case (then New game) and Scores. There are no hints and no Daily Challenge in multiplayer. The match is saved apart from your solo case.
]]

local RULES_PARTY_FR = [[
Enquêtes · à plusieurs — Règles

Mise en place : posez la liseuse au milieu de la table. Dans le menu : Joueurs (2 à 8) et Noms des joueurs, Manches (1, 3, 5 ou 7 affaires par partie), Difficulté, Langue et Thème.

L'affaire : un méfait a été commis. Chaque suspect était dans un seul lieu, avait un seul objet et (en Moyen et Difficile) était là à une seule heure ; deux suspects ne partagent jamais un lieu, un objet ou une heure. L'affaire vous donne un fait sur le coupable ; les indices donnent le reste — et une seule réponse les respecte tous.

Une manche = une affaire. Elle s'ouvre sur un seul indice : lisez-le à voix haute. Quand la table en veut un autre, touchez +1 indice : un indice de plus apparaît. Tout le monde réfléchit ensemble ; chacun peut se servir de la grille (en portrait, Grille et Indices changent de vue) : touchez une case une fois pour une croix (non), deux fois pour un rond (oui), une troisième fois pour l'effacer ; Annuler reprend le dernier geste. Touchez un indice pour le griser.

Accuser : chacun peut accuser à tout moment, mais une seule fois par affaire. Touchez Accuser, choisissez qui accuse, puis le coupable, le lieu et l'objet.
• Juste sur les trois : ce joueur remporte l'affaire.
• Faux : ce joueur ne peut plus accuser dans cette affaire — il continue d'aider les autres. Rien de la réponse n'est montré.
• Quand tous les joueurs se sont trompés, l'affaire est perdue et la réponse s'affiche.
Le haut de la page des indices montre qui peut encore accuser, et les scores.

Points : une accusation juste rapporte 1 point + 1 par indice encore caché — l'audace paie. Exemple : une affaire de 7 indices résolue avec 3 indices visibles rapporte 1 + 4 = 5 points ; avec les 7 visibles, 1 point. Une affaire perdue, ou abandonnée avec Voir la solution, ne rapporte rien. La ligne d'état indique le numéro de l'affaire, les indices visibles et ce que vaut une accusation juste maintenant (Gain).

Fin de la partie : après la dernière affaire, le tableau des scores désigne le gagnant ; à meilleur score égal, c'est une égalité. La barre d'actions propose Affaire suivante (puis Nouvelle partie) et Scores. Pas d'astuces ni de Défi du jour à plusieurs. La partie est sauvegardée à part de votre affaire en solo.
]]

local LEVEL_LABELS = { easy = _("Easy"), medium = _("Medium"), hard = _("Hard") }

-- Tab names per category pair: "Who·Where"...
local CAT_SHORT = { _("Who"), _("Where"), _("What"), _("When") }

-- ---------------------------------------------------------------------------
-- ClueLine — one tappable clue (tap greys it out)
-- ---------------------------------------------------------------------------

local ClueLine = InputContainer:extend{ text = "", face = nil, width = nil, dim = false, bold = false, callback = nil }

function ClueLine:init()
    self[1] = TextBoxWidget:new{
        text    = self.text,
        face    = self.face,
        width   = self.width,
        bold    = self.bold,
        fgcolor = self.dim and Blitbuffer.COLOR_GRAY_9 or Blitbuffer.COLOR_BLACK,
    }
    self.dimen = Geom:new{ w = self.width, h = self[1]:getSize().h }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } } }
end

function ClueLine:getSize() return self[1]:getSize() end

function ClueLine:onTap()
    if self.callback then self.callback() end
    return true
end

-- ---------------------------------------------------------------------------
-- DetectiveScreen
-- ---------------------------------------------------------------------------

local DetectiveScreen = ScreenBase:extend{}

-- Bumped whenever the content lists change shape, so a saved case pointing
-- into the old lists is dropped rather than shown with the wrong names.
local CONTENT_VERSION = 2

function DetectiveScreen:init()
    local p = self.plugin
    self.lang  = p:getLang({ "fr", "en" })
    self.level = p:getSetting("level", "easy")
    self.pack  = p:getSetting("pack", "all")
    self.party = p.launch_mode == "party"
    self:restore()
    ScreenBase.init(self)
end

-- The saved game of the current mode (solo and multiplayer are saved apart),
-- or a new one.
function DetectiveScreen:restore()
    local p = self.plugin
    self.pair  = 1
    self.clue_page = 1
    self.view  = "clues"  -- portrait shows the clues or the grid
    self.rounds = p:getSetting("party_rounds", 3)
    local saved = p:loadState(self:stateKey())
    -- A save from another language, or from before the content grew
    -- (indices into the old lists), starts a new case instead.
    self.board = saved and saved.lang == self.lang and saved.content == CONTENT_VERSION
        and Board.load(saved.board) or nil
    if self.board and self.party then
        self.scores = Party.restoreScores(saved.scores)
        self.pcase = self.scores and PartyCase.restore(saved.case, #self.board.clues, #self.scores.names)
        if not self.pcase then self.board = nil end
    end
    if self.board then
        self.pair = math.min(saved.pair or 1, #self.board.pairs)
        self.view = saved.view or "clues"
        self:attachWording()
    elseif self.party then
        self:newMatch()
    else
        self:newCase()
    end
end

function DetectiveScreen:stateKey()
    return self.party and "party_state" or nil
end

function DetectiveScreen:content()
    return Content.get(self.lang)
end

function DetectiveScreen:attachWording()
    self.words = Clues.new(self:content(), self.lang, self.board)
end

-- Builds a fresh case at the current level (math.random, so the daily
-- challenge can seed it).
function DetectiveScreen:newCase()
    local pools, victim = Packs.pools(self:content(), self.pack)
    local opts = { level = self.level, pools = pools, excluded_suspect = victim }
    -- A hard case can take a moment on an e-reader: the shared progress bar
    -- shows up if it does.
    GenProgress.run(function(on_progress)
        opts.on_progress = on_progress
        self.board = Board.generate(opts)
    end)
    self.pair = 1
    self.clue_page = 1
    self.hint_cell = nil
    self.view = "clues"
    if self.party then self.pcase = PartyCase.new(#self.board.clues, #self.scores.names) end
    self:attachWording()
end

-- Multiplayer: fresh scores for the players set up, and the first case.
function DetectiveScreen:newMatch()
    local p = self.plugin
    self.scores = Party.newScores(Party.loadPlayers(p, Party.loadCount(p)))
    Party.nextRound(self.scores)
    self:newCase()
end

function DetectiveScreen:serializeState()
    local t = { lang = self.lang, content = CONTENT_VERSION, board = self.board:serialize(),
                pair = self.pair, view = self.view }
    if self.party then
        t.scores = Party.copyScores(self.scores)
        t.case   = PartyCase.copy(self.pcase)
    end
    return t
end

function DetectiveScreen:save()
    self.plugin:saveState(self:serializeState(), self:stateKey())
end

-- ScreenBase's version saves under the solo key.
function DetectiveScreen:closeScreen()
    if not self.party then return ScreenBase.closeScreen(self) end
    self:save()
    self.plugin:onScreenClosed()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
end

function DetectiveScreen:rebuild()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function DetectiveScreen:onNewGame()
    if self.party then self:newMatch() else self:newCase() end
    self:save()
    self:rebuild()
end

function DetectiveScreen:isRoundOver()
    return self.board ~= nil and self.board.over ~= nil
end

-- Multiplayer: the last case of the match is closed.
function DetectiveScreen:isMatchOver()
    return self.party and PartyCase.matchOver(self.scores.round, self.rounds, self.board.over ~= nil)
end

function DetectiveScreen:getRoundOverButtons()
    if not self.party then return ScreenBase.getRoundOverButtons(self) end
    local scores = { text = _("Scores"), callback = function() self:showScores() end }
    if self:isMatchOver() then
        return { { text = _("New game"), callback = function() self:onNewGame() end }, scores }
    end
    return { { text = _("Next case"), callback = function() self:onNextCase() end }, scores }
end

function DetectiveScreen:showScores()
    Party.showScoreboard(self.scores, { final = self:isMatchOver() })
end

function DetectiveScreen:onNextCase()
    Party.nextRound(self.scores)
    self:newCase()
    self:save()
    self:rebuild()
end

-- After an action that may have closed a multiplayer case.
function DetectiveScreen:afterPartyCase()
    self.clue_page = 1
    self:save()
    self:rebuild()
    if self:isMatchOver() then self:showScores() end
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function DetectiveScreen:onCellTap(r, c)
    if self.board:cycle(self.pair, r, c) then
        self.hint_cell = nil
        self:save()
        self:rebuild()
    end
end

function DetectiveScreen:onUndo()
    if self.board:canUndo() and self.board:undoStep() then
        self:save()
        self:rebuild()
    else
        self:updateStatus(_("Nothing to undo."))
    end
end

function DetectiveScreen:selectPair(p)
    self.pair = p
    self:rebuild()
end

function DetectiveScreen:toggleClue(i)
    self.board:toggleStruck(i)
    self:save()
    self:rebuild()
end

-- Hint steps name their pair grid; switch to it so the framed cell shows.
function DetectiveScreen:describeHintStep(step, level)
    local b = self.board
    local pa, pb = b.pairs[step.tag][1], b.pairs[step.tag][2]
    local where = T("%1 / %2", self.words:label(pa, step.r), self.words:label(pb, step.c))
    if level == 1 then
        self.pair = step.tag
        self.view = "grid"
        if step.kind == "mistake" then
            return T(_("Wrong mark: %1."), where)
        elseif step.clue then
            return T(_("Look at %1 (clue %2)."), where, step.clue)
        end
        return T(_("Look at %1."), where)
    end
    return T(_("Marked %1."), where)
end

-- The hint may have switched tabs or marked a cell: rebuild, but keep the
-- hint's own message in the status line.
function DetectiveScreen:onHint()
    ScreenBase.onHint(self)
    local msg = self.status_text.text
    self:buildLayout()
    ScreenBase.updateStatus(self, msg)
end

function DetectiveScreen:pickFrom(title, cat, on_pick)
    local items = {}
    for v = 1, self.board.n do
        local text = cat == 1 and self.words:suspectName(v):gsub("^%l", string.upper) or self.words:label(cat, v)
        items[#items + 1] = { id = v, text = text }
    end
    MenuHelper.openPickerMenu{ title = title, items = items, parent = self, on_select = on_pick }
end

function DetectiveScreen:onAccuse()
    if self.board.over then return end
    if self.party then return self:onPartyAccuse() end
    self:pickFrom(_("Who did it?"), 1, function(s)
        self:pickFrom(_("Where?"), 2, function(pl)
            self:pickFrom(_("With what?"), 3, function(ob)
                self.board:accuse(s, pl, ob)
                self:save()
                self:rebuild()
            end)
        end)
    end)
end

function DetectiveScreen:onShowSolution()
    if self.board.over then return end
    self.board:reveal()
    if self.party then
        PartyCase.giveUp(self.pcase)
        return self:afterPartyCase()
    end
    self:save()
    self:rebuild()
end

-- Multiplayer: who accuses first (only the players still allowed to), then
-- the usual culprit / place / object pickers.
function DetectiveScreen:onPartyAccuse()
    local allowed = PartyCase.accusers(self.pcase)
    if #allowed == 0 then return end
    local function accuse(i)
        self:pickFrom(_("Who did it?"), 1, function(s)
            self:pickFrom(_("Where?"), 2, function(pl)
                self:pickFrom(_("With what?"), 3, function(ob)
                    self:partyVerdict(i, s, pl, ob)
                end)
            end)
        end)
    end
    if #allowed == 1 then return accuse(allowed[1]) end
    local names = {}
    for k, i in ipairs(allowed) do names[k] = self.scores.names[i] end
    Party.askWhoFound(names, {
        title       = _("Who is accusing?"),
        allow_none  = false,
        dismissable = true,
        on_pick     = function(k) if k then accuse(allowed[k]) end end,
    })
end

function DetectiveScreen:partyVerdict(i, s, pl, ob)
    local cs, cp, co = self.board:culprit()
    local res = PartyCase.accuse(self.pcase, i, s == cs and pl == cp and ob == co)
    if res == "win" then
        self.board:accuse(s, pl, ob)
        Party.award(self.scores, i, self.pcase.points)
    elseif res == "lost" then
        self.board:accuse(s, pl, ob)  -- the last one: the case is lost
    elseif res == "wrong" then
        -- Nothing about the answer: the others are still looking for it.
        self:save()
        self:rebuild()
        local msg = T(_("Wrong, %1! You can't accuse again in this case."), self.scores.names[i])
        self:showMessage(msg, 4)
        return
    end
    self:afterPartyCase()
end

function DetectiveScreen:onNextClue()
    if not PartyCase.revealNext(self.pcase) then return end
    -- The new clue is the last one: show its page.
    self.clue_page = math.huge
    if not self:isLandscape() then self.view = "clues" end
    self:save()
    self:rebuild()
end

-- ---------------------------------------------------------------------------
-- Menu and settings
-- ---------------------------------------------------------------------------

function DetectiveScreen:openLevelMenu()
    local items = {}
    for _i, id in ipairs(Board.LEVEL_ORDER) do items[#items + 1] = { id = id, text = LEVEL_LABELS[id] } end
    MenuHelper.openPickerMenu{
        title = _("Difficulty"), items = items, current_id = self.level, parent = self,
        on_select = function(id)
            self.level = id
            self.plugin:saveSetting("level", id)
            self:onNewGame()
        end,
    }
end

function DetectiveScreen:openLangMenu()
    MenuHelper.openPickerMenu{
        title      = _("Language"),
        items      = { { id = "fr", text = "Français" }, { id = "en", text = "English" } },
        current_id = self.lang,
        parent     = self,
        on_select  = function(lang)
            if lang == self.lang then return end
            self.lang = lang
            self.plugin:setLang(lang)
            self:onNewGame()
        end,
    }
end

local PACK_LABELS = {
    all     = _("All themes"),
    history = _("Legends & history"),
    art     = _("Art & museums"),
    science = _("Science"),
    fiction = _("Pop culture & fiction"),
    world   = _("Around the world"),
}

function DetectiveScreen:openPackMenu()
    local items = {}
    for _i, id in ipairs(Packs.IDS) do items[#items + 1] = { id = id, text = PACK_LABELS[id] } end
    MenuHelper.openPickerMenu{
        title = _("Case pack"), items = items, current_id = self.pack, parent = self,
        on_select = function(id)
            self.pack = id
            self.plugin:saveSetting("pack", id)
            self:onNewGame()
        end,
    }
end

local ROUND_CHOICES = { 1, 3, 5, 7 }

function DetectiveScreen:openRoundsMenu()
    local items = {}
    for _i, n in ipairs(ROUND_CHOICES) do items[#items + 1] = { id = n, text = tostring(n) } end
    MenuHelper.openPickerMenu{
        title = _("Rounds"), items = items, current_id = self.rounds, parent = self,
        on_select = function(n)
            self.rounds = n
            self.plugin:saveSetting("party_rounds", n)
            self:onNewGame()
        end,
    }
end

function DetectiveScreen:openModeMenu()
    MenuHelper.openPickerMenu{
        title      = _("Mode"),
        items      = { { id = "solo", text = _("Solo") }, { id = "party", text = _("Multiplayer") } },
        current_id = self.party and "party" or "solo",
        parent     = self,
        on_select  = function(mode)
            if (mode == "party") == self.party then return end
            self:save()
            self.plugin.launch_mode = mode
            self.party = mode == "party"
            self:restore()
            self:save()
            self:rebuild()
        end,
    }
end

function DetectiveScreen:menuItems()
    local mode = { text = T(_("Mode: %1"), self.party and _("Multiplayer") or _("Solo")),
                   callback = function() self:openModeMenu() end }
    local level = { text = T(_("Difficulty: %1"), LEVEL_LABELS[self.level]), callback = function() self:openLevelMenu() end }
    local lang = { text = T(_("Language: %1"), self.lang:upper()), callback = function() self:openLangMenu() end }
    local pack = { text = T(_("Case pack: %1"), PACK_LABELS[self.pack] or self.pack), callback = function() self:openPackMenu() end }
    local solution = { text = _("Show solution"), callback = function() self:onShowSolution() end }
    if self.party then
        local p = self.plugin
        return {
            { text = _("New game"), callback = function() self:onNewGame() end },
            { text = T(_("Players: %1"), #self.scores.names),
              callback = function() Party.pickCount(p, function() self:onNewGame() end, self) end },
            { text = _("Player names"), callback = function()
                Party.editPlayers(p, self.scores.names, function() self:save(); self:rebuild() end, self)
            end },
            { text = T(_("Rounds: %1"), self.rounds), callback = function() self:openRoundsMenu() end },
            level, lang, pack, mode, solution,
            self:makeModeRulesButtonConfig({ solo = { RULES_EN, RULES_FR }, party = { RULES_PARTY_EN, RULES_PARTY_FR } }),
        }
    end
    return {
        { text = _("New game"), callback = function() self:onNewGame() end },
        self:makeDailyButtonConfig(),
        level, lang, pack, mode, solution,
        self:makeModeRulesButtonConfig({ solo = { RULES_EN, RULES_FR }, party = { RULES_PARTY_EN, RULES_PARTY_FR } }),
    }
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function DetectiveScreen:verdictText()
    local b, w = self.board, self.words
    local s, pl, ob = b:culprit()
    local answer = w:answer(s, pl, ob)
    if b.over == "solved" then
        return T(_("Case solved! %1"), answer)
    elseif b.over == "failed" then
        return T(_("Wrong! It was %1"), answer)
    end
    return T(_("The answer: %1"), answer)
end

function DetectiveScreen:updateStatus(msg)
    if msg then return ScreenBase.updateStatus(self, msg) end
    local b = self.board
    if self.party then return self:updatePartyStatus() end
    if b.over then
        -- The full answer is too long for one status line: it heads the
        -- clue list instead.
        return ScreenBase.updateStatus(self, b.over == "solved" and _("Case solved!")
            or b.over == "failed" and _("Case lost.") or _("Solution shown."))
    end
    ScreenBase.updateStatus(self, self:joinStatus(
        T("%1×%2", b.n, b.n),
        LEVEL_LABELS[b.level] or b.level,
        T(_("Clues: %1"), #b.clues),
        (self.clue_pages or 1) > 1 and (self.view == "clues" or self:isLandscape())
            and T(_("Page %1/%2"), self.clue_page, self.clue_pages) or nil,
        b.hints_used > 0 and T(_("Hints: %1"), b.hints_used) or nil))
end

-- "Case 2/3 · Clues: 3/7 · Prize: 5", or the case's outcome once closed.
function DetectiveScreen:updatePartyStatus()
    local b, c = self.board, self.pcase
    local round = T(_("Case %1/%2"), self.scores.round, self.rounds)
    if b.over then
        local outcome = b.over == "solved" and _("Case solved!")
            or b.over == "failed" and _("Case lost.") or _("Solution shown.")
        if self:isMatchOver() then outcome = _("Game over") end
        return ScreenBase.updateStatus(self, self:joinStatus(round, outcome))
    end
    ScreenBase.updateStatus(self, self:joinStatus(round,
        T(_("Clues: %1/%2"), c.revealed, c.total),
        T(_("Prize: %1"), PartyCase.worth(c)),
        (self.clue_pages or 1) > 1 and (self.view == "clues" or self:isLandscape())
            and T(_("Page %1/%2"), self.clue_page, self.clue_pages) or nil))
end

-- The lines under the case: who may still accuse (or who won it), and the
-- scores.
function DetectiveScreen:partyLines()
    local c, sc = self.pcase, self.scores
    local lines = {}
    if c.winner then
        lines[1] = T(_("%1 solved the case (+%2)."), sc.names[c.winner], c.points)
    elseif c.lost then
        lines[1] = _("Nobody scores this case.")
    else
        local names = {}
        for _i, i in ipairs(PartyCase.accusers(c)) do names[#names + 1] = sc.names[i] end
        lines[1] = T(_("Can accuse: %1"), table.concat(names, ", "))
    end
    lines[2] = T(_("Scores: %1"), Party.statusText(sc))
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Layout
--
-- Portrait shows one of two views, swapped from the action bar: the clues
-- (the case on top, numbered clues in a large font, paged) or the grid
-- (tabs and one big pair table). Both at once only fit at a size nobody can
-- read on a 6" screen. Landscape has room for both side by side.
-- ---------------------------------------------------------------------------

-- Font sizes, in pixels at a 758 px short side (a Kobo Aura), scaled with
-- the screen.
local CLUE_PX, LABEL_PX = 24, 25
-- Multiplayer: read across a table, and only a few clues at a time.
local PARTY_CLUE_PX = 28

-- (Landscape keeps the solo size: its clue column is narrow.)
function DetectiveScreen:cluePx()
    return (self.party and not self:isLandscape()) and PARTY_CLUE_PX or CLUE_PX
end

function DetectiveScreen:scale()
    return math.min(DeviceScreen:getWidth(), DeviceScreen:getHeight()) / 758
end

function DetectiveScreen:pairName(p)
    local pr = self.board.pairs[p]
    return CAT_SHORT[pr[1]] .. "·" .. CAT_SHORT[pr[2]]
end

function DetectiveScreen:buildTabs(width)
    local row, rows = {}, {}
    local npairs = #self.board.pairs
    local per_row = npairs <= 3 and npairs or 3
    for p = 1, npairs do
        local label = self:pairName(p)
        if p == self.pair then label = "▸ " .. label .. " ◂" end
        row[#row + 1] = { text = label, callback = function() self:selectPair(p) end }
        if #row == per_row then rows[#rows + 1] = row; row = {} end
    end
    if #row > 0 then rows[#rows + 1] = row end
    return ButtonTable:new{ width = width, buttons = rows }
end

function DetectiveScreen:buildGrid(w, h)
    local b, words = self.board, self.words
    local pa, pb = b.pairs[self.pair][1], b.pairs[self.pair][2]
    local rl, cl = {}, {}
    for v = 1, b.n do
        rl[v] = words:label(pa, v)
        cl[v] = words:label(pb, v)
    end
    local sel = nil
    if self.hint_cell and self.hint_cell.tag == self.pair then sel = self.hint_cell end
    local pair = self.pair
    if self.grid then self.grid:free() end
    self.grid = LogicGrid:new{
        width = w, height = h, n = b.n,
        label_px = math.floor(LABEL_PX * self:scale()),
        row_labels = rl, col_labels = cl,
        corner = CAT_SHORT[pa] .. " \\ " .. CAT_SHORT[pb],
        get_mark = function(r, c) return b:getMark(pair, r, c) end,
        selected = sel,
        on_tap = function(r, c) self:onCellTap(r, c) end,
    }
    return self.grid
end

-- The case (and the verdict once over) and the clues, paged to fit `h`.
function DetectiveScreen:buildClues(w, h, px)
    local b = self.board
    local gap = Size.span.vertical_large
    local entries = {}
    entries[1] = { text = self.words:caseText(), bold = true }
    if b.over then entries[1].text = self:verdictText() .. "\n" .. entries[1].text end
    if self.party then entries[1].text = entries[1].text .. "\n" .. self:partyLines() end
    -- Multiplayer: only the clues revealed so far, all of them once closed.
    local shown = (self.party and not b.over) and self.pcase.revealed or #b.clues
    for i, cl in ipairs(b.clues) do
        if i > shown then break end
        entries[#entries + 1] = {
            text = T("%1. %2", i, self.words:text(cl, i)), dim = b.struck[i],
            callback = function() self:toggleClue(i) end,
        }
    end
    local lines = {}
    for i, e in ipairs(entries) do
        lines[i] = ClueLine:new{ text = e.text, face = pxFace(px, e.bold), width = w,
                                 dim = e.dim, bold = e.bold, callback = e.callback }
    end
    -- Pages: the case stays on top of each one.
    local avail = h - lines[1]:getSize().h - gap
    local pages, cur, used = {}, {}, 0
    for i = 2, #lines do
        local lh = lines[i]:getSize().h + gap
        if used + lh > avail and #cur > 0 then
            pages[#pages + 1] = cur; cur = {}; used = 0
        end
        cur[#cur + 1] = lines[i]; used = used + lh
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    self.clue_pages = math.max(1, #pages)
    self.clue_page = math.max(1, math.min(self.clue_page, self.clue_pages))
    local group = VerticalGroup:new{ align = "left", lines[1] }
    for _i, l in ipairs(pages[self.clue_page] or {}) do
        group[#group + 1] = VerticalSpan:new{ width = gap }
        group[#group + 1] = l
    end
    return group
end

function DetectiveScreen:turnCluePage(d)
    self.clue_page = math.max(1, math.min(self.clue_pages or 1, self.clue_page + d))
    self:rebuild()
end

function DetectiveScreen:setView(v)
    self.view = v
    self:rebuild()
end

function DetectiveScreen:actionRow(kind)
    local paged = (self.clue_pages or 1) > 1
    local prev = { text = "◀", enabled = paged and self.clue_page > 1, callback = function() self:turnCluePage(-1) end }
    local nxt  = { text = "▶", enabled = paged and self.clue_page < self.clue_pages, callback = function() self:turnCluePage(1) end }
    local hint   = { text = _("Hint"),   callback = function() self:onHint() end }
    local undo   = { text = _("Undo"),   callback = function() self:onUndo() end }
    local accuse = { text = _("Accuse"), callback = function() self:onAccuse() end }
    if self.party then
        local more = { text = _("Next clue"), enabled = PartyCase.hidden(self.pcase) > 0,
                       callback = function() self:onNextClue() end }
        if kind == "clues" then
            return { { text = _("Grid"), callback = function() self:setView("grid") end }, prev, nxt, more, accuse }
        elseif kind == "grid" then
            return { { text = _("Clues"), callback = function() self:setView("clues") end }, undo, more, accuse }
        end
        -- The landscape side panel is narrow: two rows.
        return { { prev, undo, nxt }, { more, accuse } }
    end
    if kind == "clues" then
        return { { text = _("Grid"), callback = function() self:setView("grid") end }, prev, nxt, accuse }
    elseif kind == "grid" then
        return { { text = _("Clues"), callback = function() self:setView("clues") end }, hint, undo, accuse }
    end
    return { prev, hint, undo, accuse, nxt }
end

-- actionRow() gives one row, or a list of rows: always a list of rows.
function DetectiveScreen:barRows(kind)
    local r = self:actionRow(kind)
    return r[1].text and { r } or r
end

function DetectiveScreen:buildLayout()
    local title_bar = self:buildTitleBar(_("Detective"), function() return self:menuItems() end)
    local g = self:getGutter()
    local gap = Size.span.vertical_large
    local sc = self:scale()
    local tb_h = title_bar:getSize().h

    if self:isLandscape() then
        -- Clues on the right, wider than the usual side panel: they are
        -- sentences, not buttons.
        local cw = math.floor(self.dimen.w * 0.44)
        self.status_text:setMaxWidth(cw)
        local avail_h = self.dimen.h - tb_h - 2 * g
        local bar_h = ButtonTable:new{ width = cw, buttons = self:barRows("both") }:getSize().h
        local status_h = 2 * self.status_text:getSize().h
        if self.party then
            -- Its text is known already (the page count aside): reserve what
            -- it takes, not twice that, the clue column needs the room.
            self:updateStatus()
            status_h = self.status_text:getSize().h
        end
        local clues = self:buildClues(cw, avail_h - status_h - bar_h - 3 * gap, math.floor(self:cluePx() * 0.9 * sc))
        local bar = self:buildActionBar(self:barRows("both"), cw)
        local clue_h = avail_h - status_h - bar_h - 2 * gap
        local controls = VerticalGroup:new{ align = "left", clues,
            VerticalSpan:new{ width = math.max(0, clue_h - clues:getSize().h) },
            VerticalSpan:new{ width = gap }, self.status_text, VerticalSpan:new{ width = gap }, bar }
        local bw = self.dimen.w - cw - 3 * g
        local tabs = self:buildTabs(bw)
        local grid = self:buildGrid(bw, avail_h - tabs:getSize().h - gap)
        local left = VerticalGroup:new{ align = "center", tabs, VerticalSpan:new{ width = gap }, grid }
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center", left, HorizontalSpan:new{ width = g }, controls })
    else
        local w = self.dimen.w - 2 * g
        self.status_text:setMaxWidth(w)
        local bar_h = ButtonTable:new{ width = w, buttons = self:barRows(self.view) }:getSize().h
        local avail = self.dimen.h - tb_h - self.status_text:getSize().h - bar_h - 4 * g - 2 * gap
        local content
        if self.view == "grid" then
            local tabs = self:buildTabs(w)
            local grid = self:buildGrid(w, avail - tabs:getSize().h - gap)
            content = VerticalGroup:new{ align = "center", tabs, VerticalSpan:new{ width = gap }, grid }
        else
            local clues = self:buildClues(w, avail, math.floor(self:cluePx() * sc))
            -- Top-anchored, like a page.
            content = VerticalGroup:new{ align = "left", clues,
                VerticalSpan:new{ width = math.max(0, avail - clues:getSize().h) } }
        end
        local controls = VerticalGroup:new{ align = "center", self.status_text,
            VerticalSpan:new{ width = gap }, self:buildActionBar(self:barRows(self.view)) }
        self:buildPortraitLayout(title_bar, content,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = g } })
    end
    self[1] = self.layout
    self:updateStatus()
end

-- The case content (names, places, objects) is only needed while a game is
-- open: drop it when the screen closes (the next game reads its language's
-- file again).
function DetectiveScreen:onCloseWidget()
    Content.release()
end

return DetectiveScreen
