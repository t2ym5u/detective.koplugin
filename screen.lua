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

local MenuHelper = require("menu_helper")
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
    self.lang  = p:getSetting("lang", _.lang() == "fr" and "fr" or "en")
    self.level = p:getSetting("level", "easy")
    self.pack  = p:getSetting("pack", "all")
    self.pair  = 1
    self.clue_page = 1
    self.view  = "clues"  -- portrait shows the clues or the grid
    local saved = p:loadState()
    -- A save from another language, or from before the content grew
    -- (indices into the old lists), starts a new case instead.
    self.board = saved and saved.lang == self.lang and saved.content == CONTENT_VERSION
        and Board.load(saved.board) or nil
    if self.board then
        self.pair = math.min(saved.pair or 1, #self.board.pairs)
        self.view = saved.view or "clues"
        self:attachWording()
    else
        self:newCase()
    end
    ScreenBase.init(self)
end

function DetectiveScreen:content()
    local key = "content_" .. self.lang
    if not self._content or self._content_key ~= key then
        self._content = lrequire(key)
        self._content_key = key
    end
    return self._content
end

function DetectiveScreen:attachWording()
    self.words = Clues.new(self:content(), self.lang, self.board)
end

-- Builds a fresh case at the current level (math.random, so the daily
-- challenge can seed it).
function DetectiveScreen:newCase()
    local pools, victim = Packs.pools(self:content(), self.pack)
    local opts = { level = self.level, pools = pools, excluded_suspect = victim }
    -- Generation is bounded by work budgets, so it can (very rarely) give up;
    -- an easy case always fits.
    self.board = Board.generate(opts)
    if not self.board then
        opts.level = "easy"
        self.board = Board.generate(opts)
    end
    self.pair = 1
    self.clue_page = 1
    self.hint_cell = nil
    self.view = "clues"
    self:attachWording()
end

function DetectiveScreen:serializeState()
    return { lang = self.lang, content = CONTENT_VERSION, board = self.board:serialize(),
             pair = self.pair, view = self.view }
end

function DetectiveScreen:save()
    self.plugin:saveState(self:serializeState())
end

function DetectiveScreen:rebuild()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function DetectiveScreen:onNewGame()
    self:newCase()
    self:save()
    self:rebuild()
end

function DetectiveScreen:isRoundOver()
    return self.board ~= nil and self.board.over ~= nil
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
            self.plugin:saveSetting("lang", lang)
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

function DetectiveScreen:menuItems()
    return {
        { text = _("New game"), callback = function() self:onNewGame() end },
        self:makeDailyButtonConfig(),
        { text = T(_("Difficulty: %1"), LEVEL_LABELS[self.level]), callback = function() self:openLevelMenu() end },
        { text = T(_("Language: %1"), self.lang:upper()), callback = function() self:openLangMenu() end },
        { text = T(_("Case pack: %1"), PACK_LABELS[self.pack] or self.pack), callback = function() self:openPackMenu() end },
        { text = _("Show solution"), callback = function() self:onShowSolution() end },
        self:makeRulesButtonConfig(RULES_EN, RULES_FR),
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
    for i, cl in ipairs(b.clues) do
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
    if kind == "clues" then
        return { { text = _("Grid"), callback = function() self:setView("grid") end }, prev, nxt, accuse }
    elseif kind == "grid" then
        return { { text = _("Clues"), callback = function() self:setView("clues") end }, hint, undo, accuse }
    end
    return { prev, hint, undo, accuse, nxt }
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
        local bar_h = ButtonTable:new{ width = cw, buttons = { self:actionRow("both") } }:getSize().h
        local status_h = 2 * self.status_text:getSize().h
        local clues = self:buildClues(cw, avail_h - status_h - bar_h - 3 * gap, math.floor(CLUE_PX * 0.9 * sc))
        local bar = self:buildActionBar(self:actionRow("both"), cw)
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
        local bar_h = ButtonTable:new{ width = w, buttons = { self:actionRow(self.view) } }:getSize().h
        local avail = self.dimen.h - tb_h - self.status_text:getSize().h - bar_h - 4 * g - 2 * gap
        local content
        if self.view == "grid" then
            local tabs = self:buildTabs(w)
            local grid = self:buildGrid(w, avail - tabs:getSize().h - gap)
            content = VerticalGroup:new{ align = "center", tabs, VerticalSpan:new{ width = gap }, grid }
        else
            local clues = self:buildClues(w, avail, math.floor(CLUE_PX * sc))
            -- Top-anchored, like a page.
            content = VerticalGroup:new{ align = "left", clues,
                VerticalSpan:new{ width = math.max(0, avail - clues:getSize().h) } }
        end
        local controls = VerticalGroup:new{ align = "center", self.status_text,
            VerticalSpan:new{ width = gap }, self:buildActionBar(self:actionRow(self.view)) }
        self:buildPortraitLayout(title_bar, content,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = g } })
    end
    self[1] = self.layout
    self:updateStatus()
end

return DetectiveScreen
