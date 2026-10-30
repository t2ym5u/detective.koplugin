-- ---------------------------------------------------------------------------
-- logic_grid.lua — one pair grid of the logic puzzle (rows = values of one
-- category, columns = values of another), drawn and tapped.
--
-- Labels sit on the left and on top. Marks: a cross for "no", a filled dot
-- for "yes". Taps on a cell call on_tap(r, c).
-- ---------------------------------------------------------------------------

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local Size           = require("ui/size")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local TextWidget     = require("ui/widget/textwidget")

local DeviceScreen = Device.screen
local DPI_SCALE = DeviceScreen:scaleBySize(1000) / 1000

local function face(px, bold)
    return Font:getFace(bold and "tfont" or "cfont", math.max(8, math.floor(px / DPI_SCALE)))
end

local LogicGrid = InputContainer:extend{
    width      = nil,   -- max width
    height     = nil,   -- max height
    n          = 3,
    row_labels = nil,
    col_labels = nil,
    corner     = nil,   -- "Who \\ Where"
    get_mark   = nil,   -- function(r, c) -> 0 | 1 | 2
    selected   = nil,   -- { r, c } to frame (hint)
    on_tap     = nil,
    label_px   = nil,   -- preferred label font size (px), shrunk to fit
}

-- True if no word of `text` is wider than w at size px (a label must wrap
-- between words, never inside "Bagpipes").
local function wordsFit(text, w, px)
    local f = face(px)
    for word in text:gmatch("[^%s%-]+") do
        if RenderText:sizeUtf8Text(0, w * 4, f, word, true, false).x > w - 2 then return false end
    end
    return true
end

local function makeLabel(text, w, px, align)
    return TextBoxWidget:new{ text = text, face = face(px), width = w, alignment = align or "center" }
end

-- A column label written bottom-to-top, as in printed logic-grid books:
-- used when the columns are too narrow for a readable horizontal label.
local RotatedLabel = {}
RotatedLabel.__index = RotatedLabel

function RotatedLabel.new(text, px)
    local tw = TextWidget:new{ text = text, face = face(px) }
    local sz = tw:getSize()
    local bb = Blitbuffer.new(sz.w, sz.h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    tw:paintTo(bb, 0, 0)
    tw:free()
    local rot = bb:rotatedCopy(90)
    bb:free()
    return setmetatable({ bb = rot, w = rot:getWidth(), h = rot:getHeight() }, RotatedLabel)
end

function RotatedLabel:getSize() return Geom:new{ w = self.w, h = self.h } end
function RotatedLabel:paintTo(target, x, y) target:blitFrom(self.bb, x, y, 0, 0, self.w, self.h) end
function RotatedLabel:free() if self.bb then self.bb:free() self.bb = nil end end

local function textWidth(text, px)
    return RenderText:sizeUtf8Text(0, 4000, face(px), text, true, false).x
end

function LogicGrid:init()
    local n = self.n
    -- The label column is as wide as the longest row label (on one line,
    -- at the preferred size) needs, between 18% and 30% of the width (longer ones wrap);
    -- the header is three label lines tall at most.
    local pref = self.label_px or math.floor(self.width / 30)
    local widest = 0
    for _, t in ipairs(self.row_labels) do
        widest = math.max(widest, RenderText:sizeUtf8Text(0, self.width, face(pref), t, true, false).x)
    end
    local label_w = math.max(math.floor(self.width * 0.18),
        math.min(math.floor(self.width * 0.30), widest + 3 * Size.padding.default))
    local line_h = TextBoxWidget:new{ text = "Ag", face = face(pref), width = 200 }:getSize().h
    local header_h = math.min(math.floor(self.height * 0.30), 3 * line_h + 8)
    -- Cells may be wider than tall: the column labels need the width more
    -- than the marks need the height.
    local function cells(hh)
        local ch = math.floor((self.height - hh) / n)
        local cw = math.floor((self.width - label_w) / n)
        ch = math.min(ch, math.floor(cw * 1.1))
        cw = math.min(cw, math.floor(ch * 1.8))
        return ch, cw
    end
    local ch, cw = cells(header_h)
    -- Too narrow for the column labels to read across at 80% of the wanted
    -- size? Then stand them on end.
    local horizontal_ok = true
    local test_px = math.floor(pref * 0.8)
    for _, t in ipairs(self.col_labels) do
        if not wordsFit(t, cw - 4, test_px)
           or makeLabel(t, cw - 4, test_px):getSize().h > header_h - 6 then
            horizontal_ok = false
            break
        end
    end
    local rot_px
    if not horizontal_ok then
        rot_px = pref
        local cap = math.floor(self.height * 0.36)
        local longest = 0
        for _, t in ipairs(self.col_labels) do longest = math.max(longest, textWidth(t, rot_px)) end
        while longest + 10 > cap and rot_px > 12 do
            rot_px = math.floor(rot_px * 0.92)
            longest = 0
            for _, t in ipairs(self.col_labels) do longest = math.max(longest, textWidth(t, rot_px)) end
        end
        header_h = longest + 10
        ch, cw = cells(header_h)
    end
    local cell = ch
    self.cell     = cell
    self.cell_w   = cw
    self.label_w  = label_w
    self.header_h = header_h
    self.grid_x   = label_w
    self.grid_y   = header_h
    local w = label_w + n * cw
    local h = header_h + n * cell
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    -- One font size per side (the largest that fits all its labels), so a
    -- short name doesn't shout next to a long one. Column labels are the
    -- narrow ones; they shrink without dragging the row labels down.
    local start = pref
    local col_w, row_w = cw - 4, label_w - 2 * Size.padding.default
    local function fitSize(labels, w, max_h, align)
        local px = start
        while px > 10 do
            local ok = true
            for _, text in ipairs(labels) do
                local tb = makeLabel(text, w, px, align)
                ok = tb:getSize().h <= max_h and wordsFit(text, w, px)
                tb:free()
                if not ok then break end
            end
            if ok then return px end
            px = math.floor(px * 0.92)
        end
        return px
    end
    local col_px = rot_px or fitSize(self.col_labels, col_w, header_h - 6)
    local row_px = fitSize(self.row_labels, row_w, cell - 4, "right")
    self.labels = {}
    for c = 1, n do
        local w = rot_px and RotatedLabel.new(self.col_labels[c], rot_px) or makeLabel(self.col_labels[c], col_w, col_px)
        self.labels[#self.labels + 1] = { kind = "col", i = c, w = w }
    end
    for r = 1, n do
        self.labels[#self.labels + 1] = { kind = "row", i = r, w = makeLabel(self.row_labels[r], row_w, row_px, "right") }
    end
    if self.corner then
        self.corner_w = makeLabel(self.corner, label_w - 8, math.floor(math.min(col_px, row_px) * 0.8))
    end
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

-- Rotated labels own a blitbuffer each.
function LogicGrid:free()
    for _, l in ipairs(self.labels or {}) do
        if l.w.free then l.w:free() end
    end
    self.labels = {}
end

function LogicGrid:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

-- Top-left corner and size (w, h) of cell (r, c) on screen.
function LogicGrid:cellRect(r, c)
    return self.dimen.x + self.grid_x + (c - 1) * self.cell_w,
           self.dimen.y + self.grid_y + (r - 1) * self.cell, self.cell_w, self.cell
end

function LogicGrid:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local n, ch, cw = self.n, self.cell, self.cell_w
    local gx, gy = x + self.grid_x, y + self.grid_y
    local gw, gh = n * cw, n * ch
    local black, gray = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_LIGHT_GRAY

    for _, l in ipairs(self.labels) do
        local sz = l.w:getSize()
        if l.kind == "col" then
            local cx = gx + (l.i - 1) * cw
            l.w:paintTo(bb, cx + math.floor((cw - sz.w) / 2), gy - sz.h - 4)
        else
            local cy = gy + (l.i - 1) * ch
            l.w:paintTo(bb, x + Size.padding.default, cy + math.floor((ch - sz.h) / 2))
        end
    end
    if self.corner_w then
        self.corner_w:paintTo(bb, x + 4, y + 4)
    end

    -- Light shading on every other row, so a row reads across.
    for r = 2, n, 2 do
        bb:paintRect(gx, gy + (r - 1) * ch, gw, ch, Blitbuffer.COLOR_GRAY_E)
    end
    local thin = Size.line.medium
    for i = 0, n do
        bb:paintRect(gx + i * cw, gy, thin, gh, gray)
        bb:paintRect(gx, gy + i * ch, gw, thin, gray)
    end
    bb:paintBorder(gx, gy, gw + thin, gh + thin, Size.border.thick, black)

    local s = math.min(cw, ch)
    for r = 1, n do
        for c = 1, n do
            local m = self.get_mark(r, c)
            local mx = gx + (c - 1) * cw + math.floor((cw - s) / 2)
            local my = gy + (r - 1) * ch
            if m == 1 then
                -- A cross, as a run of small squares along both diagonals.
                local pad = math.floor(s * 0.28)
                local len = s - 2 * pad
                local t = math.max(2, math.floor(s / 14))
                for i = 0, len do
                    bb:paintRect(mx + pad + i, my + pad + i, t, t, Blitbuffer.COLOR_GRAY_4)
                    bb:paintRect(mx + s - pad - i - t, my + pad + i, t, t, Blitbuffer.COLOR_GRAY_4)
                end
            elseif m == 2 then
                local rad = math.floor(s * 0.26)
                bb:paintCircle(mx + math.floor(s / 2), my + math.floor(s / 2), rad, black, rad)
            end
        end
    end
    if self.selected then
        local x0 = gx + (self.selected.c - 1) * cw
        local y0 = gy + (self.selected.r - 1) * ch
        bb:paintBorder(x0 + 2, y0 + 2, cw - 3, ch - 3, Size.border.thick * 2, black)
    end
end

function LogicGrid:onTap(_, ges)
    if not ges or not ges.pos then return true end
    local px = ges.pos.x - self.dimen.x - self.grid_x
    local py = ges.pos.y - self.dimen.y - self.grid_y
    if px < 0 or py < 0 then return true end
    local c = math.floor(px / self.cell_w) + 1
    local r = math.floor(py / self.cell) + 1
    if r >= 1 and r <= self.n and c >= 1 and c <= self.n and self.on_tap then
        self.on_tap(r, c)
    end
    return true
end

return LogicGrid
