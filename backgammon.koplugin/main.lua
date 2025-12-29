-- backgammon.koplugin/main.lua
--
-- Backgammon-style plugin for KOReader
-- Modes:
--   - PLAKOTO (with PVP / AI-E / AI-M)
--   - TABULA  (with PVP / AI-E / AI-M)
--   - PORTES  (with PVP / AI-E / AI-M)
--   - FEVGA   (with PVP / AI-E / AI-M)

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Geom            = require("ui/geometry")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local Font            = require("ui/font")

local InputContainer  = require("ui/widget/container/inputcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local TextWidget      = require("ui/widget/textwidget")
local Button          = require("ui/widget/button")

local _ = require("gettext")

local Screen = Device.screen

----------------------------------------------------------------------
-- Shared model
----------------------------------------------------------------------

local NUM_POINTS    = 24
local NUM_CHECKERS  = 15

local function opponent(player)
    return (player == 1) and 2 or 1
end

local function createEmptyBoard()
    local points = {}
    for i = 1, NUM_POINTS do
        points[i] = {
            counts   = { [1] = 0, [2] = 0 },
            pinnedBy = nil,
        }
    end
    return points
end

----------------------------------------------------------------------
-- PLAKOTO rules model (simplified)
----------------------------------------------------------------------

local function initPlakotoStart(board)
    -- Player 1 starts on point 1
    board[1].counts[1] = NUM_CHECKERS
    board[1].pinnedBy  = nil

    -- Player 2 starts on point 24
    board[NUM_POINTS].counts[2] = NUM_CHECKERS
    board[NUM_POINTS].pinnedBy  = nil
end

-- PORTES starting setup (backgammon-style)
-- Player 1 (●) moves 1 -> 24, home 19..24
-- Player 2 (○) moves 24 -> 1, home 1..6
local function initPortesStart(board)
    -- clear just in case
    for i = 1, NUM_POINTS do
        board[i].counts[1] = 0
        board[i].counts[2] = 0
        board[i].pinnedBy  = nil
    end

    -- Player 1
    board[1].counts[1]  = 2
    board[12].counts[1] = 5
    board[17].counts[1] = 3
    board[19].counts[1] = 5

    -- Player 2
    board[24].counts[2] = 2
    board[13].counts[2] = 5
    board[8].counts[2]  = 3
    board[6].counts[2]  = 5
end

local function hasMovableCheckerAt(board, idx, currentPlayer)
    local pt  = board[idx]
    local mine = pt.counts[currentPlayer]
    local opp  = pt.counts[opponent(currentPlayer)]
    if mine <= 0 then
        return false
    end

    -- If your single checker is pinned by the opponent, you cannot move it.
    if pt.pinnedBy == opponent(currentPlayer) and mine == 1 and opp >= 1 then
        return false
    end

    return true
end

local function canLandOn(board, destIdx, currentPlayer)
    -- For normal movement only (bearing off handled separately).
    if destIdx < 1 or destIdx > NUM_POINTS then
        return false, false
    end

    local pt        = board[destIdx]
    local mine      = pt.counts[currentPlayer]
    local oppPlayer = opponent(currentPlayer)
    local opp       = pt.counts[oppPlayer]

    -- Blocked by 2+ opposing checkers
    if opp >= 2 then
        return false, false
    end

    -- Pinning: landing on a single opponent checker (no previous pin)
    if opp == 1 and mine == 0 then
        if pt.pinnedBy ~= nil then
            return false, false
        end
        return true, true
    end

    -- Cannot land on a point pinned by opponent
    if pt.pinnedBy ~= nil and pt.pinnedBy ~= currentPlayer then
        return false, false
    end

    return true, false
end

----------------------------------------------------------------------
-- Bearing off helpers (PLAKOTO + PORTES + FEVGA)
----------------------------------------------------------------------

-- Home boards:
--   Player 1 : points 19..24 (moving upwards, dir = +1, exit after 24)
--   Player 2 : points  1..6  (moving downwards, dir = -1, exit before 1)

local function isInHomeBoard(idx, player)
    if player == 1 then
        return idx >= 19 and idx <= 24
    else
        return idx >= 1 and idx <= 6
    end
end

-- Map a board index in the home board to a "local" home index 1..6
-- where 1 is closest to bearing off.
local function localHomeIndex(idx, player)
    if player == 1 then
        -- 24 is local 1, 23 is local 2, ..., 19 is local 6
        return 24 - idx + 1
    else
        -- 1 is local 1, 2 is local 2, ..., 6 is local 6
        return idx
    end
end

local function allCheckersInHome(board, player, borneOff)
    local remaining = NUM_CHECKERS - (borneOff[player] or 0)
    if remaining <= 0 then
        return true
    end
    for i = 1, NUM_POINTS do
        local cnt = board[i].counts[player]
        if cnt > 0 and not isInHomeBoard(i, player) then
            return false
        end
    end
    return true
end

local function canBearOffFrom(board, player, borneOff, srcIdx, dieVal)
    if not allCheckersInHome(board, player, borneOff) then
        return false
    end

    local srcLocal = localHomeIndex(srcIdx, player)
    if srcLocal == dieVal then
        return true
    end

    -- Over-sized die: allowed only if there are no checkers on higher home points
    if dieVal > srcLocal then
        for i = 1, NUM_POINTS do
            local cnt = board[i].counts[player]
            if cnt > 0 and isInHomeBoard(i, player) then
                local lh = localHomeIndex(i, player)
                if lh > srcLocal then
                    return false
                end
            end
        end
        return true
    end

    return false
end

-- PORTES: all-in-home / bearing off (must also have no checkers on bar)
local function portesAllCheckersInHome(board, player, borneOff, bar)
    local remaining = NUM_CHECKERS - (borneOff[player] or 0)
    if remaining <= 0 then
        return true
    end

    if (bar[player] or 0) > 0 then
        return false
    end

    for i = 1, NUM_POINTS do
        local cnt = board[i].counts[player]
        if cnt > 0 and not isInHomeBoard(i, player) then
            return false
        end
    end
    return true
end

local function portesCanBearOffFrom(board, player, borneOff, bar, srcIdx, dieVal)
    if not portesAllCheckersInHome(board, player, borneOff, bar) then
        return false
    end

    local srcLocal = localHomeIndex(srcIdx, player)
    if srcLocal == dieVal then
        return true
    end

    if dieVal > srcLocal then
        for i = 1, NUM_POINTS do
            local cnt = board[i].counts[player]
            if cnt > 0 and isInHomeBoard(i, player) then
                local lh = localHomeIndex(i, player)
                if lh > srcLocal then
                    return false
                end
            end
        end
        return true
    end

    return false
end

----------------------------------------------------------------------
-- FEVGA helpers (setup + movement helpers only)
-- (No hitting, first-checker rule, same bearing-off helpers as PLAKOTO)
----------------------------------------------------------------------

-- Starting points for Fevga: diagonally opposite corners.
-- Player 1: point 1, Player 2: point 13.
local FEVGA_START = {
    [1] = 1,
    [2] = 13,
}

local function initFevgaStart(board)
    for i = 1, NUM_POINTS do
        board[i].counts[1] = 0
        board[i].counts[2] = 0
        board[i].pinnedBy  = nil
    end
    board[FEVGA_START[1]].counts[1] = NUM_CHECKERS
    board[FEVGA_START[2]].counts[2] = NUM_CHECKERS
end

-- Fevga: a point with *any* opponent checker is blocked (no hitting).
local function fevgaCanLandOn(board, destIdx, player)
    if destIdx < 1 or destIdx > NUM_POINTS then
        return false
    end
    local opp = opponent(player)
    if board[destIdx].counts[opp] > 0 then
        return false
    end
    return true
end

-- Fevga: movable checker check, with "first checker away" restriction.
local function fevgaHasMovableCheckerAt(board, idx, player, firstPassed, startIdx)
    local mine = board[idx].counts[player]
    if mine <= 0 then
        return false
    end
    -- Until one checker has reached the opponent's start,
    -- you may only move the checker(s) on your own starting point.
    if not firstPassed and idx ~= startIdx then
        return false
    end
    return true
end

-- Any “normal” Fevga move exists (ignoring bearing off).
local function fevgaHasAnyMove(board, player, diceList, firstPassed)
    local startIdx = FEVGA_START[player]
    local dir      = (player == 1) and 1 or -1
    for src = 1, NUM_POINTS do
        if fevgaHasMovableCheckerAt(board, src, player, firstPassed, startIdx) then
            for _, d in ipairs(diceList) do
                local dest = src + dir * d
                if dest >= 1 and dest <= NUM_POINTS and fevgaCanLandOn(board, dest, player) then
                    return true
                end
            end
        end
    end
    return false
end

-- Any bearing-off move exists in Fevga (same logic as Plakoto).
local function fevgaHasAnyBearingOff(board, player, borneOff, diceRemaining)
    if not allCheckersInHome(board, player, borneOff) then
        return false
    end
    for src = 1, NUM_POINTS do
        if board[src].counts[player] > 0 and isInHomeBoard(src, player) then
            local srcLocal = localHomeIndex(src, player)
            local dieIndex, dieVal = nil, nil
            -- nearestDieForHome is defined later, but since this is only
            -- used at runtime (after load), order is fine.
        end
    end
    return false
end

----------------------------------------------------------------------
-- Subscript helper for smaller-looking counts
----------------------------------------------------------------------

local subdigits = {
    ["0"] = "₀",
    ["1"] = "₁",
    ["2"] = "₂",
    ["3"] = "₃",
    ["4"] = "₄",
    ["5"] = "₅",
    ["6"] = "₆",
    ["7"] = "₇",
    ["8"] = "₈",
    ["9"] = "₉",
}

local function toSubscript(n)
    local s = tostring(n)
    local out = ""
    for i = 1, #s do
        local ch = s:sub(i, i)
        out = out .. (subdigits[ch] or ch)
    end
    return out
end

----------------------------------------------------------------------
-- Dice formatting
----------------------------------------------------------------------

local function diceToString(dice)
    if not dice or #dice == 0 then
        return "-"
    end
    local parts = {}
    for _, d in ipairs(dice) do
        table.insert(parts, tostring(d))
    end
    return table.concat(parts, " | ")
end

----------------------------------------------------------------------
-- Screen container
----------------------------------------------------------------------

local BackgammonScreen = InputContainer:extend{}

-- decorative marker used for separators
local BOARD_MARK = "◇"
-- blank Unicode (for visually empty lines)
local BLANK_MARK = "　"

function BackgammonScreen:init()
    self.dimen = Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.covers_fullscreen = true
    self.vertical_align    = "center"
    self.plugin            = self.plugin

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    local titleFace = Font:getFace("smallinfofont")

    self.statusWidget = TextWidget:new{
        text    = _("Backgammon"),
        face    = titleFace,
        bold    = true,
        padding = Size.padding.small,
    }

    self.screenContainer    = VerticalGroup:new{}
    self.mode               = nil
    self.currentPlayer      = 1
    self.board              = nil
    self.dice               = {}
    self.diceRemaining      = {}
    self.selectedPoint      = nil
    self.gameOver           = false

    -- PLAKOTO + FEVGA bearing off
    self.borneOff           = { [1] = 0, [2] = 0 }

    -- Mode: "PVP", "AI_E", "AI_M" (shared between games; AI is always player 2)
    self.playMode           = "PVP"
    self.aiDelay            = 3   -- seconds between AI moves

    -- info line content (bottom line)
    self.infoMessageStr     = " "
    self.infoMessageWidget  = nil

    -- TABULA-specific state
    self.tabulaUnentered       = { [1] = NUM_CHECKERS, [2] = NUM_CHECKERS }
    self.tabulaBar             = { [1] = 0, [2] = 0 }
    self.tabulaBorneOff        = { [1] = 0, [2] = 0 }
    self.tabulaDice            = {}
    self.tabulaDiceRemaining   = {}

    -- PORTES-specific state
    self.portesBar             = { [1] = 0, [2] = 0 }
    self.portesBorneOff        = { [1] = 0, [2] = 0 }
    self.portesDice            = {}
    self.portesDiceRemaining   = {}

    -- FEVGA-specific state
    self.fevgaBorneOff         = { [1] = 0, [2] = 0 }
    self.fevgaFirstPassed      = { [1] = false, [2] = false }

    self:buildModeMenu()
    self:buildRootLayout()

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function BackgammonScreen:buildRootLayout()
    self.layout = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ height = Size.span.vertical_large },
        FrameContainer:new{
            padding = Size.padding.large,
            margin  = Size.margin.default,
            VerticalGroup:new{
                TextWidget:new{
                    text = BLANK_MARK,
                    face = Font:getFace("smallinfofont"),
                },
                self.statusWidget,
                TextWidget:new{
                    text = BLANK_MARK,
                    face = Font:getFace("smallinfofont"),
                },
                VerticalSpan:new{ height = Size.span.vertical_small },
                self.screenContainer,
            },
        },
        VerticalSpan:new{ height = Size.span.vertical_large },
    }
    self[1] = self.layout
end

function BackgammonScreen:setScreen(new_widget)
    self.screenContainer = new_widget
    self:buildRootLayout()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function BackgammonScreen:updateStatus(text)
    self.statusWidget:setText(text)
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function BackgammonScreen:setInfoMessage(text)
    self.infoMessageStr = text or " "
    if self.infoMessageWidget then
        self.infoMessageWidget:setText(self.infoMessageStr)
        UIManager:setDirty(self, function()
            return "ui", self.dimen
        end)
    end
end

function BackgammonScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)

    local content_size = self.layout:getSize()
    local offset_x = x + math.floor((self.dimen.w - content_size.w) / 2)
    local offset_y = y
    if self.vertical_align == "center" then
        offset_y = offset_y + math.floor((self.dimen.h - content_size.h) / 2)
    end
    self.layout:paintTo(bb, offset_x, offset_y)
end

----------------------------------------------------------------------
-- Mode selection screen
----------------------------------------------------------------------

function BackgammonScreen:buildModeMenu()
    self.mode     = "menu"
    self.gameOver = false

    local function modeButton(label, enabled, callback)
        return Button:new{
            text    = label,
            margin  = Size.margin.small,
            width   = math.floor(Screen:getWidth() * 0.6),
            enabled = enabled,
            callback = callback,
        }
    end

    local menu = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = BOARD_MARK,
            face = Font:getFace("smallinfofont"),
        },
        VerticalSpan:new{ height = Size.span.vertical_small },

        -- ORDER: PORTES, PLAKOTO, FEVGA, TABULA
        modeButton(_("PORTES"), true, function()
            self:startPortes()
        end),
        VerticalSpan:new{ height = Size.span.vertical_small },

        modeButton(_("PLAKOTO"), true, function()
            self:startPlakoto()
        end),
        VerticalSpan:new{ height = Size.span.vertical_small },

        modeButton(_("FEVGA"), true, function()
            self:startFevga()
        end),
        VerticalSpan:new{ height = Size.span.vertical_small },

        modeButton(_("TABULA"), true, function()
            self:startTabula()
        end),

        TextWidget:new{
            text = BOARD_MARK,
            face = Font:getFace("smallinfofont"),
        },
        VerticalSpan:new{ height = Size.span.vertical_large },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        Button:new{
            text = _("CLOSE"),
            callback = function()
                self:onClose()
                UIManager:close(self)
                UIManager:setDirty(nil, "full")
            end,
        },
    }

    self:updateStatus(_("MAIN MENU"))
    self:setScreen(menu)
end

----------------------------------------------------------------------
-- Shared helpers for AI mode + mode label
----------------------------------------------------------------------

function BackgammonScreen:isAIPlayer(player)
    if self.playMode == "PVP" then
        return false
    end
    -- AI is always player 2 (○)
    return (player == 2)
end

local function modeLabel(mode)
    if mode == "AI_E" then
        return "AI-E"
    elseif mode == "AI_M" then
        return "AI-M"
    else
        return "PVP"
    end
end

function BackgammonScreen:cyclePlayMode()
    if self.playMode == "PVP" then
        self.playMode = "AI_E"
    elseif self.playMode == "AI_E" then
        self.playMode = "AI_M"
    else
        self.playMode = "PVP"
    end
    -- Reset current game when mode changes
    if self.mode == "plakoto" then
        self:startPlakoto()
    elseif self.mode == "tabula" then
        self:startTabula()
    elseif self.mode == "portes" then
        self:startPortes()
    elseif self.mode == "fevga" then
        self:startFevga()
    end
end

----------------------------------------------------------------------
-- Plakoto setup & main screen
----------------------------------------------------------------------

function BackgammonScreen:startPlakoto()
    self.mode          = "plakoto"
    self.board         = createEmptyBoard()
    initPlakotoStart(self.board)
    self.currentPlayer = 1
    self.dice          = {}
    self.diceRemaining = {}
    self.selectedPoint = nil
    self.gameOver      = false
    self.borneOff      = { [1] = 0, [2] = 0 }
    self.infoMessageStr = " "
    self.playMode      = self.playMode or "PVP"

    self.statusWidget:setText(_("PLAKOTO"))

    self:rollNewTurnDice()
    self:buildPlakotoScreen()
end

function BackgammonScreen:rollNewTurnDice()
    local d1 = math.random(1, 6)
    local d2 = math.random(1, 6)
    self.dice = { d1, d2 }

    self.diceRemaining = {}
    if d1 == d2 then
        table.insert(self.diceRemaining, d1)
        table.insert(self.diceRemaining, d1)
        table.insert(self.diceRemaining, d1)
        table.insert(self.diceRemaining, d1)
    else
        table.insert(self.diceRemaining, d1)
        table.insert(self.diceRemaining, d2)
    end
end

----------------------------------------------------------------------
-- Board rendering helpers (shared layout)
----------------------------------------------------------------------

local function tokenForPlayer(player)
    return (player == 1) and "●" or "○"
end

function BackgammonScreen:makePointColumn(idx, cellWidth, cellHeight, isTopRow)
    local pt       = self.board[idx]
    local p1       = pt.counts[1]
    local p2       = pt.counts[2]
    local total    = p1 + p2
    local pinnedBy = pt.pinnedBy

    local topText    = " "
    local bottomText = " "

    if total == 0 then
        topText    = " "
        bottomText = " "
    elseif pinnedBy ~= nil then
        local pinPlayer  = pinnedBy
        local trapPlayer = opponent(pinPlayer)
        local pinCount   = pt.counts[pinPlayer]
        local trapCount  = pt.counts[trapPlayer]

        local pinChar  = tokenForPlayer(pinPlayer)
        local trapChar = tokenForPlayer(trapPlayer)

        if isTopRow then
            topText    = trapChar .. toSubscript(trapCount)
            bottomText = pinChar  .. toSubscript(pinCount)
        else
            topText    = pinChar  .. toSubscript(pinCount)
            bottomText = trapChar .. toSubscript(trapCount)
        end
    elseif p1 > 0 and p2 == 0 then
        local char = tokenForPlayer(1)
        if isTopRow then
            if p1 == 1 then
                topText    = char .. toSubscript(1)
                bottomText = " "
            else
                topText    = char .. toSubscript(p1)
                bottomText = char
            end
        else
            if p1 == 1 then
                topText    = " "
                bottomText = char .. toSubscript(1)
            else
                topText    = char
                bottomText = char .. toSubscript(p1)
            end
        end
    elseif p2 > 0 and p1 == 0 then
        local char = tokenForPlayer(2)
        if isTopRow then
            if p2 == 1 then
                topText    = char .. toSubscript(1)
                bottomText = " "
            else
                topText    = char .. toSubscript(p2)
                bottomText = char
            end
        else
            if p2 == 1 then
                topText    = " "
                bottomText = char .. toSubscript(1)
            else
                topText    = char
                bottomText = char .. toSubscript(p2)
            end
        end
    else
        if isTopRow then
            topText    = "◐" .. toSubscript(total)
            bottomText = "◐"
        else
            topText    = "◐"
            bottomText = "◐" .. toSubscript(total)
        end
    end

    local col = VerticalGroup:new{
        align = "center",
    }

    table.insert(col, Button:new{
        text   = topText,
        width  = cellWidth,
        height = cellHeight,
        margin = 1,
        callback = function()
            if self.mode == "tabula" then
                self:onPointTappedTabula(idx)
            elseif self.mode == "portes" then
                self:onPointTappedPortes(idx)
            elseif self.mode == "fevga" then
                self:onPointTappedFevga(idx)
            else
                self:onPointTapped(idx)
            end
        end,
    })

    table.insert(col, Button:new{
        text   = bottomText,
        width  = cellWidth,
        height = cellHeight,
        margin = 1,
        callback = function()
            if self.mode == "tabula" then
                self:onPointTappedTabula(idx)
            elseif self.mode == "portes" then
                self:onPointTappedPortes(idx)
            elseif self.mode == "fevga" then
                self:onPointTappedFevga(idx)
            else
                self:onPointTapped(idx)
            end
        end,
    })

    return col
end

function BackgammonScreen:renderPlakotoBoard()
    local cellWidth  = math.floor(Screen:getWidth() / 13)
    if cellWidth < 40 then cellWidth = 40 end
    local cellHeight = cellWidth

    local topRow = HorizontalGroup:new{ align = "center" }
    for idx = NUM_POINTS, 13, -1 do
        table.insert(topRow, self:makePointColumn(idx, cellWidth, cellHeight, true))
    end

    local spacerRowsCount = 6
    local spacerGroup = VerticalGroup:new{ align = "center" }
    for r = 1, spacerRowsCount do
        table.insert(spacerGroup, TextWidget:new{
            text = BOARD_MARK,
            face = Font:getFace("smallinfofont"),
        })
        if r < spacerRowsCount then
            table.insert(spacerGroup, VerticalSpan:new{
                height = math.floor(cellHeight / 2),
            })
        end
    end

    local bottomRow = HorizontalGroup:new{ align = "center" }
    for idx = 1, 12 do
        table.insert(bottomRow, self:makePointColumn(idx, cellWidth, cellHeight, false))
    end

    local inner = VerticalGroup:new{
        align = "center",
        topRow,
        spacerGroup,
        bottomRow,
    }

    local board =
        FrameContainer:new{
            padding = Size.padding.small,
            margin  = 0,
            inner,
        }

    return board
end

----------------------------------------------------------------------
-- Info / dice / controls (PLAKOTO)
----------------------------------------------------------------------

function BackgammonScreen:buildPlakotoInfoAndControls()
    local current   = self.currentPlayer
    local moveToken = (current == 1) and "●" or "○"

    local diceText     = string.format(_("Dice: %s"), diceToString(self.diceRemaining))
    local combinedText = string.format("%s to move  %s  %s", moveToken, BOARD_MARK, diceText)

    local whiteOnBoard = NUM_CHECKERS - (self.borneOff[1] or 0)
    local blackOnBoard = NUM_CHECKERS - (self.borneOff[2] or 0)
    local piecesLine   = string.format("● - %d  %s  ○ - %d", whiteOnBoard, BOARD_MARK, blackOnBoard)

    self.infoMessageWidget = TextWidget:new{
        text = self.infoMessageStr or " ",
        face = Font:getFace("smallinfofont"),
    }
    self:setInfoMessage(self.infoMessageStr)

    local info = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = piecesLine,
            face = Font:getFace("smallinfofont"),
        },
        VerticalSpan:new{ height = Size.span.vertical_small },
        TextWidget:new{
            text = combinedText,
            face = Font:getFace("smallinfofont"),
        },
        VerticalSpan:new{ height = Size.span.vertical_small },
        self.infoMessageWidget,
    }

    local controls = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = "MODE: " .. modeLabel(self.playMode),
            callback = function()
                if self.gameOver then
                    return
                end
                self:cyclePlayMode()
            end,
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        Button:new{
            text = _("MAIN MENU"),
            callback = function()
                self:buildModeMenu()
            end,
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        Button:new{
            text = _("CLOSE"),
            callback = function()
                self:onClose()
                UIManager:close(self)
                UIManager:setDirty(nil, "full")
            end,
        },
    }

    local block = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ height = Size.span.vertical_medium },
        info,
        VerticalSpan:new{ height = Size.span.vertical_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        controls,
    }

    return block
end

function BackgammonScreen:buildPlakotoScreen()
    local board = self:renderPlakotoBoard()
    local info  = self:buildPlakotoInfoAndControls()

    local layout = VerticalGroup:new{
        align = "center",
        board,
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        info,
    }

    self:setScreen(layout)
end

----------------------------------------------------------------------
-- Mother piece trap (PLAKOTO)
----------------------------------------------------------------------

function BackgammonScreen:checkMotherTrap(destIdx, pinPlayer)
    local opp      = opponent(pinPlayer)
    local startIdx = (opp == 1) and 1 or NUM_POINTS

    if destIdx ~= startIdx then
        return false
    end

    local pt = self.board[destIdx]

    if pt.pinnedBy == pinPlayer and pt.counts[opp] == 1 then
        self.gameOver = true
        local winnerLabel =
            (pinPlayer == 1) and _("Player 1 (●)") or _("Player 2 (○)")
        self:setInfoMessage(string.format(
            _("%s wins by trapping the mother checker"),
            winnerLabel
        ))
        self:buildPlakotoScreen()
        return true
    end

    return false
end

----------------------------------------------------------------------
-- Turn / interaction logic (PLAKOTO)
----------------------------------------------------------------------

local function consumeDie(diceRemaining, dist)
    for i, d in ipairs(diceRemaining) do
        if d == dist then
            table.remove(diceRemaining, i)
            return true
        end
    end
    return false
end

local function consumeDieByValue(diceRemaining, value)
    for i, d in ipairs(diceRemaining) do
        if d == value then
            table.remove(diceRemaining, i)
            return true
        end
    end
    return false
end

local function nearestDieForHome(diceRemaining, targetLocal)
    local exactIndex = nil
    local exactVal   = nil
    local bestOverIdx = nil
    local bestOverVal = nil

    for i, d in ipairs(diceRemaining) do
        if d == targetLocal then
            exactIndex = i
            exactVal   = d
            break
        elseif d > targetLocal then
            if not bestOverVal or d < bestOverVal then
                bestOverVal = d
                bestOverIdx = i
            end
        end
    end

    if exactIndex then
        return exactIndex, exactVal
    else
        return bestOverIdx, bestOverVal
    end
end

----------------------------------------------------------------------
-- Simple AI (PLAKOTO)
----------------------------------------------------------------------

local function hasAnyLegalMove(board, currentPlayer, diceList)
    local dir = (currentPlayer == 1) and 1 or -1
    for src = 1, NUM_POINTS do
        if hasMovableCheckerAt(board, src, currentPlayer) then
            for _, d in ipairs(diceList) do
                local dest = src + dir * d
                local ok, _ = canLandOn(board, dest, currentPlayer)
                if ok then
                    return true
                end
            end
        end
    end
    return false
end

local function hasAnyBearingOff(board, player, borneOff, diceRemaining)
    if not allCheckersInHome(board, player, borneOff) then
        return false
    end
    for src = 1, NUM_POINTS do
        local pt = board[src]
        if pt.counts[player] > 0 and isInHomeBoard(src, player) then
            local srcLocal = localHomeIndex(src, player)
            local dieIndex, dieVal = nearestDieForHome(diceRemaining, srcLocal)
            if dieIndex and dieVal and canBearOffFrom(board, player, borneOff, src, dieVal) then
                return true
            end
        end
    end
    return false
end

function BackgammonScreen:generateAIMoves(player)
    local dir = (player == 1) and 1 or -1
    local moves = {}
    for src = 1, NUM_POINTS do
        if hasMovableCheckerAt(self.board, src, player) then
            local srcCount = self.board[src].counts[player]
            for dieIndex, d in ipairs(self.diceRemaining) do
                local dest = src + dir * d
                local ok, willPin = canLandOn(self.board, dest, player)
                if ok then
                    local score = 0
                    score = score + (dest * dir)

                    local srcNewCount = srcCount - 1
                    if srcNewCount == 1 then
                        score = score - 10
                    elseif srcNewCount >= 2 then
                        score = score + 2
                    end

                    local destCount = 0
                    if dest >= 1 and dest <= NUM_POINTS then
                        destCount = self.board[dest].counts[player]
                    end
                    local destNewCount = destCount + 1
                    if destNewCount >= 2 then
                        score = score + 8
                    else
                        score = score - 4
                    end

                    if willPin then
                        score = score + 25
                    end

                    table.insert(moves, {
                        src      = src,
                        dest     = dest,
                        dieIndex = dieIndex,
                        dieVal   = d,
                        score    = score,
                        willPin  = willPin,
                    })
                end
            end
        end
    end
    return moves
end

function BackgammonScreen:chooseAIMove(player)
    local moves = self:generateAIMoves(player)
    if #moves == 0 then
        return nil
    end

    if self.playMode == "AI_E" then
        local subsetSize = math.max(1, math.floor(#moves / 2))
        local best = nil
        for i = 1, subsetSize do
            local idx = math.random(1, #moves)
            local m = moves[idx]
            if not best or m.score > best.score then
                best = m
            end
        end
        return best
    else
        local best = moves[1]
        for i = 2, #moves do
            if moves[i].score > best.score then
                best = moves[i]
            end
        end
        return best
    end
end

function BackgammonScreen:performSingleAIMove(player)
    if self.gameOver then
        return false
    end

    if #self.diceRemaining == 0 then
        return false
    end

    local move = self:chooseAIMove(player)
    if not move then
        self:setInfoMessage(_("AI has no legal moves"))
        return false
    end

    table.remove(self.diceRemaining, move.dieIndex)

    local ok, willPin = canLandOn(self.board, move.dest, player)
    if not ok then
        self:setInfoMessage(_("AI attempted illegal move"))
        return false
    end

    local success, err = applyMove(self.board, move.src, move.dest, player)
    if not success then
        self:setInfoMessage(err or _("AI move failed"))
        return false
    end

    if willPin then
        self:setInfoMessage(_("AI pins a checker"))
        if self:checkMotherTrap(move.dest, player) then
            return false
        end
    else
        self:setInfoMessage(_("AI moves"))
    end

    return true
end

function BackgammonScreen:startAITurn()
    if self.gameOver then
        return
    end
    if not self:isAIPlayer(self.currentPlayer) then
        return
    end

    UIManager:scheduleIn(self.aiDelay, function()
        self:continueAITurn()
    end)
end

function BackgammonScreen:continueAITurn()
    if self.gameOver then
        return
    end
    local current = self.currentPlayer
    if not self:isAIPlayer(current) then
        return
    end

    if #self.diceRemaining == 0 or not hasAnyLegalMove(self.board, current, self.diceRemaining) then
        self:nextPlayerTurn()
        return
    end

    local moved = self:performSingleAIMove(current)
    self:buildPlakotoScreen()

    if not moved then
        self:nextPlayerTurn()
        return
    end

    if #self.diceRemaining == 0 or not hasAnyLegalMove(self.board, current, self.diceRemaining) then
        self:nextPlayerTurn()
    else
        UIManager:scheduleIn(self.aiDelay, function()
            self:continueAITurn()
        end)
    end
end

----------------------------------------------------------------------
-- Core movement (PLAKOTO)
----------------------------------------------------------------------

function applyMove(board, srcIdx, destIdx, currentPlayer)
    local opp = opponent(currentPlayer)
    local src = board[srcIdx]

    local mine          = src.counts[currentPlayer]
    local oppCountAtSrc = src.counts[opp]

    if src.pinnedBy == opp and mine == 1 and oppCountAtSrc >= 1 then
        return false, "Pinned checker cannot move"
    end

    src.counts[currentPlayer] = mine - 1

    if src.pinnedBy == currentPlayer and src.counts[currentPlayer] == 0 then
        src.pinnedBy = nil
    end

    if destIdx < 1 or destIdx > NUM_POINTS then
        src.counts[currentPlayer] = src.counts[currentPlayer] + 1
        return false, "Bearing off not handled here"
    end

    local dst       = board[destIdx]
    local mineDest  = dst.counts[currentPlayer]
    local oppDest   = dst.counts[opp]

    if oppDest == 1 and mineDest == 0 and dst.pinnedBy == nil then
        dst.counts[currentPlayer] = 1
        dst.pinnedBy              = currentPlayer
        return true
    end

    dst.counts[currentPlayer] = mineDest + 1
    return true
end

function BackgammonScreen:onPointTapped(idx)
    if self.mode ~= "plakoto" then
        return
    end
    if self.gameOver then
        return
    end

    if self:isAIPlayer(self.currentPlayer) then
        return
    end

    if #self.diceRemaining == 0 then
        self:nextPlayerTurn()
        return
    end

    local current = self.currentPlayer
    local dir     = (current == 1) and 1 or -1

    if not self.selectedPoint then
        if hasMovableCheckerAt(self.board, idx, current) then
            self.selectedPoint = idx
            self:setInfoMessage(string.format(_("Selected point %d"), idx))
        else
            self:setInfoMessage(_("No movable checker on that point"))
        end
    else
        local src = self.selectedPoint

        if src == idx then
            if allCheckersInHome(self.board, current, self.borneOff) then
                local srcLocal = localHomeIndex(src, current)
                local dieIndex, dieVal = nearestDieForHome(self.diceRemaining, srcLocal)
                if dieIndex and dieVal and canBearOffFrom(self.board, current, self.borneOff, src, dieVal) then
                    table.remove(self.diceRemaining, dieIndex)

                    local pt = self.board[src]
                    pt.counts[current] = pt.counts[current] - 1
                    if pt.pinnedBy == current and pt.counts[current] == 0 then
                        pt.pinnedBy = nil
                    end

                    self.borneOff[current] = (self.borneOff[current] or 0) + 1
                    self:setInfoMessage(_("Checker borne off"))

                    self.selectedPoint = nil

                    if self.borneOff[current] >= NUM_CHECKERS then
                        self.gameOver = true
                        local winnerLabel = (current == 1)
                            and _("Player 1 (●)")
                            or  _("Player 2 (○)")
                        self:setInfoMessage(string.format(
                            _("%s bears off all checkers and wins"),
                            winnerLabel
                        ))
                        self:buildPlakotoScreen()
                        return
                    end

                    local noDice  = (#self.diceRemaining == 0)
                    local noMoves = not hasAnyLegalMove(self.board, current, self.diceRemaining)
                    local noBear  = not hasAnyBearingOff(self.board, current, self.borneOff, self.diceRemaining)

                    if noDice or (noMoves and noBear) then
                        self:nextPlayerTurn()
                    end

                    self:buildPlakotoScreen()
                    return
                end
            end

            self.selectedPoint = nil
            self:setInfoMessage(_("Selection cleared"))
            return
        end

        local dist = (idx - src) * dir
        if dist <= 0 then
            self:setInfoMessage(_("You must move forward"))
            self.selectedPoint = nil
            return
        end

        if not consumeDie(self.diceRemaining, dist) then
            self:setInfoMessage(string.format(_("No die for distance %d"), dist))
            self.selectedPoint = nil
            return
        end

        local dest       = src + dir * dist
        local ok, willPin = canLandOn(self.board, dest, current)
        if not ok then
            table.insert(self.diceRemaining, dist)
            self:setInfoMessage(_("Illegal destination"))
            self.selectedPoint = nil
            return
        end

        local success, err = applyMove(self.board, src, dest, current)
        if not success then
            table.insert(self.diceRemaining, dist)
            self:setInfoMessage(err or _("Move failed"))
            self.selectedPoint = nil
            return
        end

        if willPin then
            self:setInfoMessage(_("Pinned an opponent checker"))
            if self:checkMotherTrap(dest, current) then
                self.selectedPoint = nil
                return
            end
        else
            self:setInfoMessage(_("Move played"))
        end

        self.selectedPoint = nil

        local noDice  = (#self.diceRemaining == 0)
        local noMoves = not hasAnyLegalMove(self.board, current, self.diceRemaining)
        local noBear  = not hasAnyBearingOff(self.board, current, self.borneOff, self.diceRemaining)

        if noDice or (noMoves and noBear) then
            self:nextPlayerTurn()
        end

        self:buildPlakotoScreen()
    end
end

function BackgammonScreen:nextPlayerTurn()
    if self.gameOver then
        return
    end
    self.currentPlayer = opponent(self.currentPlayer)
    self.selectedPoint = nil
    self:rollNewTurnDice()
    self.infoMessageStr = " "
    self:buildPlakotoScreen()

    if self:isAIPlayer(self.currentPlayer) then
        self:startAITurn()
    end
end

----------------------------------------------------------------------
-- TABULA
----------------------------------------------------------------------

local TABULA_START_MIN = 1
local TABULA_START_MAX = 6
local TABULA_HOME_MIN  = 19
local TABULA_HOME_MAX  = 24

local function tabulaIsInHome(idx)
    return idx >= TABULA_HOME_MIN and idx <= TABULA_HOME_MAX
end

local function tabulaLocalHomeIndex(idx)
    return 24 - idx + 1 -- 24->1, 23->2, ..., 19->6
end

local function tabulaCanEnterAt(board, idx, player)
    if idx < TABULA_START_MIN or idx > TABULA_START_MAX then
        return false
    end
    local opp = opponent(player)
    if board[idx].counts[opp] >= 2 then
        return false
    end
    return true
end

local function tabulaCanLandOn(board, destIdx, player)
    if destIdx < 1 or destIdx > NUM_POINTS then
        return false
    end
    local opp = opponent(player)
    if board[destIdx].counts[opp] >= 2 then
        return false
    end
    return true
end

local function tabulaAllCheckersInHome(board, player, borneOff, unentered, bar)
    local notBorne = NUM_CHECKERS - (borneOff[player] or 0)
    if notBorne <= 0 then
        return true
    end

    local offboard = (unentered[player] or 0) + (bar[player] or 0)
    if offboard > 0 then
        return false
    end

    for i = 1, NUM_POINTS do
        local cnt = board[i].counts[player]
        if cnt > 0 and not tabulaIsInHome(i) then
            return false
        end
    end

    return true
end

local function tabulaCanBearOffFrom(board, player, borneOff, unentered, bar, srcIdx, dieVal)
    if not tabulaAllCheckersInHome(board, player, borneOff, unentered, bar) then
        return false
    end

    local srcLocal = tabulaLocalHomeIndex(srcIdx)
    if srcLocal == dieVal then
        return true
    end

    if dieVal > srcLocal then
        for i = 1, NUM_POINTS do
            local cnt = board[i].counts[player]
            if cnt > 0 and tabulaIsInHome(i) then
                local lh = tabulaLocalHomeIndex(i)
                if lh > srcLocal then
                    return false
                end
            end
        end
        return true
    end

    return false
end

function BackgammonScreen:rollTabulaDice()
    self.tabulaDice = {
        math.random(1, 6),
        math.random(1, 6),
        math.random(1, 6),
    }
    self.tabulaDiceRemaining = {
        self.tabulaDice[1],
        self.tabulaDice[2],
        self.tabulaDice[3],
    }
end

function BackgammonScreen:updateTabulaTitle()
    if self.mode ~= "tabula" then
        return
    end
    local bar1 = self.tabulaBar[1] or 0
    local bar2 = self.tabulaBar[2] or 0
    local base = _("TABULA")
    if bar1 > 0 or bar2 > 0 then
        local title = string.format("%s  ● %d  %s  ○ %d", base, bar1, BOARD_MARK, bar2)
        self.statusWidget:setText(title)
    else
        self.statusWidget:setText(base)
    end
end

function BackgammonScreen:startTabula()
    self.mode              = "tabula"
    self.board             = createEmptyBoard()
    self.currentPlayer     = 1
    self.selectedPoint     = nil
    self.gameOver          = false
    self.infoMessageStr    = " "

    self.tabulaUnentered   = { [1] = NUM_CHECKERS, [2] = NUM_CHECKERS }
    self.tabulaBar         = { [1] = 0, [2] = 0 }
    self.tabulaBorneOff    = { [1] = 0, [2] = 0 }
    self.tabulaDice        = {}
    self.tabulaDiceRemaining = {}

    self.statusWidget:setText(_("TABULA"))
    self:rollTabulaDice()
    self:updateTabulaTitle()
    self:buildTabulaScreen()
end

function BackgammonScreen:tabulaAllEntered(player)
    return (self.tabulaUnentered[player] or 0) == 0
end

function BackgammonScreen:tabulaEnterFromBar(idx, player)
    local opp = opponent(player)
    local pt  = self.board[idx]
    local oppCount = pt.counts[opp]

    if oppCount == 1 then
        pt.counts[opp] = 0
        self.tabulaBar[opp] = (self.tabulaBar[opp] or 0) + 1
    end

    pt.counts[player] = pt.counts[player] + 1
    self.tabulaBar[player] = self.tabulaBar[player] - 1
    if self.tabulaBar[player] < 0 then
        self.tabulaBar[player] = 0
    end
end

function BackgammonScreen:tabulaEnterFromOffBoard(idx, player)
    local opp = opponent(player)
    local pt  = self.board[idx]
    local oppCount = pt.counts[opp]

    if oppCount == 1 then
        pt.counts[opp] = 0
        self.tabulaBar[opp] = (self.tabulaBar[opp] or 0) + 1
    end

    pt.counts[player] = pt.counts[player] + 1
    self.tabulaUnentered[player] = self.tabulaUnentered[player] - 1
    if self.tabulaUnentered[player] < 0 then
        self.tabulaUnentered[player] = 0
    end
end

function BackgammonScreen:tabulaMoveFromBoard(srcIdx, destIdx, player)
    local opp = opponent(player)
    local src = self.board[srcIdx]
    src.counts[player] = src.counts[player] - 1

    local dst = self.board[destIdx]
    local oppCount = dst.counts[opp]
    if oppCount == 1 then
        dst.counts[opp] = 0
        self.tabulaBar[opp] = (self.tabulaBar[opp] or 0) + 1
    end
    dst.counts[player] = dst.counts[player] + 1
end

function BackgammonScreen:tabulaHasAnyMove(player)
    local dice = self.tabulaDiceRemaining
    if #dice == 0 then
        return false
    end

    local unentered = self.tabulaUnentered[player] or 0
    local bar       = self.tabulaBar[player] or 0

    if bar > 0 then
        -- must re-enter from bar
        for _, d in ipairs(dice) do
            local idx = d
            if idx >= TABULA_START_MIN and idx <= TABULA_START_MAX then
                if tabulaCanEnterAt(self.board, idx, player) then
                    return true
                end
            end
        end
        return false
    end

    if unentered > 0 then
        for _, d in ipairs(dice) do
            local idx = d
            if idx >= TABULA_START_MIN and idx <= TABULA_START_MAX then
                if tabulaCanEnterAt(self.board, idx, player) then
                    return true
                end
            end
        end
    end

    for src = 1, NUM_POINTS do
        local cnt = self.board[src].counts[player]
        if cnt > 0 then
            for _, d in ipairs(dice) do
                local dest = src + d
                if dest > src then
                    if not self:tabulaAllEntered(player) and src <= 12 and dest > 12 then
                        -- forbidden
                    else
                        if dest > NUM_POINTS then
                            if tabulaCanBearOffFrom(self.board, player, self.tabulaBorneOff, self.tabulaUnentered, self.tabulaBar, src, d) then
                                return true
                            end
                        else
                            if tabulaCanLandOn(self.board, dest, player) then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- ---------- TABULA AI ----------

function BackgammonScreen:tabulaGenerateAIMoves(player)
    local moves = {}
    local dice  = self.tabulaDiceRemaining
    if #dice == 0 then
        return moves
    end

    local unentered = self.tabulaUnentered[player] or 0
    local bar       = self.tabulaBar[player] or 0
    local opp       = opponent(player)

    local function scoreMove(kind, src, dest, hitsOpp, createdStack, leavesBlotBehind, bearingOff)
        local score = 0
        if bearingOff then
            score = score + 30
        end
        if dest then
            score = score + dest
        end
        if hitsOpp then
            score = score + 15
        end
        if createdStack then
            score = score + 8
        end
        if leavesBlotBehind then
            score = score - 6
        end
        if kind == "enter_bar" then
            score = score + 10
        elseif kind == "enter_off" then
            score = score + 5
        end
        return score
    end

    -- If on bar, must re-enter from bar
    if bar > 0 then
        for dieIndex, d in ipairs(dice) do
            local idx = d
            if idx >= TABULA_START_MIN and idx <= TABULA_START_MAX and tabulaCanEnterAt(self.board, idx, player) then
                local ptDest      = self.board[idx]
                local hitsOpp     = (ptDest.counts[opp] == 1)
                local createdStack = (ptDest.counts[player] + 1 >= 2)
                local s = scoreMove("enter_bar", nil, idx, hitsOpp, createdStack, false, false)
                table.insert(moves, {
                    kind     = "enter_bar",
                    dest     = idx,
                    dieIndex = dieIndex,
                    dieVal   = d,
                    score    = s,
                })
            end
        end
        return moves
    end

    -- Enter from off-board
    if unentered > 0 then
        for dieIndex, d in ipairs(dice) do
            local idx = d
            if idx >= TABULA_START_MIN and idx <= TABULA_START_MAX and tabulaCanEnterAt(self.board, idx, player) then
                local ptDest      = self.board[idx]
                local hitsOpp     = (ptDest.counts[opp] == 1)
                local createdStack = (ptDest.counts[player] + 1 >= 2)
                local s = scoreMove("enter_off", nil, idx, hitsOpp, createdStack, false, false)
                table.insert(moves, {
                    kind     = "enter_off",
                    dest     = idx,
                    dieIndex = dieIndex,
                    dieVal   = d,
                    score    = s,
                })
            end
        end
    end

    -- Moves from board
    for src = 1, NUM_POINTS do
        local cnt = self.board[src].counts[player]
        if cnt > 0 then
            for dieIndex, d in ipairs(dice) do
                local dest = src + d
                if dest > src then
                    if not self:tabulaAllEntered(player) and src <= 12 and dest > 12 then
                        -- skip
                    else
                        if dest > NUM_POINTS then
                            if tabulaCanBearOffFrom(self.board, player, self.tabulaBorneOff, self.tabulaUnentered, self.tabulaBar, src, d) then
                                local leavesBlot = (cnt - 1 == 1)
                                local s = scoreMove("bearoff", src, nil, false, false, leavesBlot, true)
                                table.insert(moves, {
                                    kind     = "bearoff",
                                    src      = src,
                                    dieIndex = dieIndex,
                                    dieVal   = d,
                                    score    = s,
                                })
                            end
                        else
                            if tabulaCanLandOn(self.board, dest, player) then
                                local ptDest      = self.board[dest]
                                local hitsOpp     = (ptDest.counts[opp] == 1)
                                local createdStack = (ptDest.counts[player] + 1 >= 2)
                                local leavesBlot   = (cnt - 1 == 1)
                                local s = scoreMove("move", src, dest, hitsOpp, createdStack, leavesBlot, false)
                                table.insert(moves, {
                                    kind     = "move",
                                    src      = src,
                                    dest     = dest,
                                    dieIndex = dieIndex,
                                    dieVal   = d,
                                    score    = s,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    return moves
end

function BackgammonScreen:tabulaChooseAIMove(player)
    local moves = self:tabulaGenerateAIMoves(player)
    if #moves == 0 then
        return nil
    end

    if self.playMode == "AI_E" then
        local subsetSize = math.max(1, math.floor(#moves / 2))
        local best = nil
        for i = 1, subsetSize do
            local idx = math.random(1, #moves)
            local m = moves[idx]
            if not best or m.score > best.score then
                best = m
            end
        end
        return best
    else
        local best = moves[1]
        for i = 2, #moves do
            if moves[i].score > best.score then
                best = moves[i]
            end
        end
        return best
    end
end

function BackgammonScreen:tabulaPerformSingleAIMove(player)
    if self.gameOver then
        return false
    end
    if #self.tabulaDiceRemaining == 0 then
        return false
    end

    local move = self:tabulaChooseAIMove(player)
    if not move then
        self:setInfoMessage(_("AI has no legal moves"))
        return false
    end

    table.remove(self.tabulaDiceRemaining, move.dieIndex)

    if move.kind == "enter_bar" then
        self:tabulaEnterFromBar(move.dest, player)
        self:setInfoMessage(_("AI enters from bar"))
        return true
    elseif move.kind == "enter_off" then
        self:tabulaEnterFromOffBoard(move.dest, player)
        self:setInfoMessage(_("AI enters a checker"))
        return true
    elseif move.kind == "move" then
        self:tabulaMoveFromBoard(move.src, move.dest, player)
        self:setInfoMessage(_("AI moves"))
        return true
    elseif move.kind == "bearoff" then
        local pt = self.board[move.src]
        pt.counts[player] = pt.counts[player] - 1
        if pt.counts[player] < 0 then
            pt.counts[player] = 0
        end
        self.tabulaBorneOff[player] = (self.tabulaBorneOff[player] or 0) + 1
        self:setInfoMessage(_("AI bears off a checker"))
        if self.tabulaBorneOff[player] >= NUM_CHECKERS then
            self.gameOver = true
            local winnerLabel = (player == 1) and _("Player 1 (●)") or _("Player 2 (○)")
            self:setInfoMessage(string.format(
                _("%s bears off all checkers and wins"),
                winnerLabel
            ))
        end
        return true
    end

    return false
end

function BackgammonScreen:startTabulaAITurn()
    if self.gameOver then
        return
    end
    if not self:isAIPlayer(self.currentPlayer) then
        return
    end
    UIManager:scheduleIn(self.aiDelay, function()
        self:continueTabulaAITurn()
    end)
end

function BackgammonScreen:continueTabulaAITurn()
    if self.gameOver then
        return
    end
    local current = self.currentPlayer
    if not self:isAIPlayer(current) then
        return
    end

    if #self.tabulaDiceRemaining == 0 or not self:tabulaHasAnyMove(current) then
        self:tabulaNextPlayerTurn()
        return
    end

    local moved = self:tabulaPerformSingleAIMove(current)
    self:updateTabulaTitle()
    self:buildTabulaScreen()

    if not moved or self.gameOver then
        if not self.gameOver then
            self:tabulaNextPlayerTurn()
        end
        return
    end

    if #self.tabulaDiceRemaining == 0 or not self:tabulaHasAnyMove(current) then
        self:tabulaNextPlayerTurn()
    else
        UIManager:scheduleIn(self.aiDelay, function()
            self:continueTabulaAITurn()
        end)
    end
end

-- ---------- TABULA turn flow ----------

function BackgammonScreen:tabulaNextPlayerTurn()
    if self.gameOver then
        return
    end
    self.currentPlayer = opponent(self.currentPlayer)
    self.selectedPoint = nil
    self:rollTabulaDice()
    self.infoMessageStr = " "
    self:updateTabulaTitle()
    self:buildTabulaScreen()

    if self:isAIPlayer(self.currentPlayer) then
        self:startTabulaAITurn()
    end
end

function BackgammonScreen:tabulaPostMove(player)
    self:updateTabulaTitle()
    if #self.tabulaDiceRemaining == 0 or not self:tabulaHasAnyMove(player) then
        self:tabulaNextPlayerTurn()
    else
        self:buildTabulaScreen()
    end
end

-- ---------- TABULA info + controls ----------

function BackgammonScreen:buildTabulaInfoAndControls()
    local current   = self.currentPlayer
    local moveToken = (current == 1) and "●" or "○"

    local diceText     = string.format(_("Dice: %s"), diceToString(self.tabulaDiceRemaining))
    local combinedText = string.format("%s to move  %s  %s", moveToken, BOARD_MARK, diceText)

    local whiteRemaining = NUM_CHECKERS - (self.tabulaBorneOff[1] or 0)
    local blackRemaining = NUM_CHECKERS - (self.tabulaBorneOff[2] or 0)
    local piecesLine = string.format("● - %d  %s  ○ - %d", whiteRemaining, BOARD_MARK, blackRemaining)

    self.infoMessageWidget = TextWidget:new{
        text = self.infoMessageStr or " ",
        face = Font:getFace("smallinfofont"),
    }
    self:setInfoMessage(self.infoMessageStr)

    local info = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = piecesLine,
            face = Font:getFace("smallinfofont"),
        },
        VerticalSpan:new{ height = Size.span.vertical_small },
        TextWidget:new{
            text = combinedText,
            face = Font:getFace("smallinfofont"),
        },
        VerticalSpan:new{ height = Size.span.vertical_small },
        self.infoMessageWidget,
    }

    local controls = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = "MODE: " .. modeLabel(self.playMode),
            callback = function()
                if self.gameOver then
                    return
                end
                self:cyclePlayMode()
            end,
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        Button:new{
            text = _("MAIN MENU"),
            callback = function()
                self:buildModeMenu()
            end,
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        Button:new{
            text = _("CLOSE"),
            callback = function()
                self:onClose()
                UIManager:close(self)
                UIManager:setDirty(nil, "full")
            end,
        },
    }

    local block = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ height = Size.span.vertical_medium },
        info,
        VerticalSpan:new{ height = Size.span.vertical_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        controls,
    }

    return block
end

function BackgammonScreen:buildTabulaScreen()
    local board = self:renderPlakotoBoard()
    local info  = self:buildTabulaInfoAndControls()

    local layout = VerticalGroup:new{
        align = "center",
        board,
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        info,
    }

    self:setScreen(layout)
end

-- ---------- TABULA interaction ----------

function BackgammonScreen:onPointTappedTabula(idx)
    if self.mode ~= "tabula" then
        return
    end
    if self.gameOver then
        return
    end

    if self:isAIPlayer(self.currentPlayer) then
        return
    end

    if #self.tabulaDiceRemaining == 0 then
        self:tabulaNextPlayerTurn()
        return
    end

    local current   = self.currentPlayer
    local unentered = self.tabulaUnentered[current] or 0
    local bar       = self.tabulaBar[current] or 0

    local function consumeTabulaDie(val)
        return consumeDieByValue(self.tabulaDiceRemaining, val)
    end

    local function tryEnter(fromBar)
        if idx < TABULA_START_MIN or idx > TABULA_START_MAX then
            return false
        end

        if fromBar and bar <= 0 then
            return false
        end
        if (not fromBar) and unentered <= 0 then
            return false
        end

        if not tabulaCanEnterAt(self.board, idx, current) then
            return false
        end

        if not consumeTabulaDie(idx) then
            return false
        end

        if fromBar then
            self:tabulaEnterFromBar(idx, current)
        else
            self:tabulaEnterFromOffBoard(idx, current)
        end
        self:setInfoMessage(_("Entered checker"))
        self:tabulaPostMove(current)
        return true
    end

    if not self.selectedPoint then
        if bar > 0 then
            if not tryEnter(true) then
                if not self:tabulaHasAnyMove(current) then
                    self:setInfoMessage(_("No legal re-entry; turn passes"))
                    self:tabulaNextPlayerTurn()
                else
                    self:setInfoMessage(_("Must re-enter from bar using matching die"))
                end
            end
            return
        end

        if idx >= TABULA_START_MIN and idx <= TABULA_START_MAX and unentered > 0 then
            if tryEnter(false) then
                return
            end
        end

        if self.board[idx].counts[current] > 0 then
            self.selectedPoint = idx
            self:setInfoMessage(string.format(_("Selected point %d"), idx))
        else
            self:setInfoMessage(_("No movable checker on that point"))
        end
        return
    else
        local src = self.selectedPoint

        if src == idx then
            if tabulaAllCheckersInHome(self.board, current, self.tabulaBorneOff, self.tabulaUnentered, self.tabulaBar) then
                local srcLocal = tabulaLocalHomeIndex(src)
                local dieIndex, dieVal = nearestDieForHome(self.tabulaDiceRemaining, srcLocal)
                if dieIndex and dieVal and tabulaCanBearOffFrom(self.board, current, self.tabulaBorneOff, self.tabulaUnentered, self.tabulaBar, src, dieVal) then
                    table.remove(self.tabulaDiceRemaining, dieIndex)
                    local pt = self.board[src]
                    pt.counts[current] = pt.counts[current] - 1
                    if pt.counts[current] < 0 then
                        pt.counts[current] = 0
                    end
                    self.tabulaBorneOff[current] = (self.tabulaBorneOff[current] or 0) + 1
                    self:setInfoMessage(_("Checker borne off"))

                    self.selectedPoint = nil

                    if self.tabulaBorneOff[current] >= NUM_CHECKERS then
                        self.gameOver = true
                        local winnerLabel = (current == 1)
                            and _("Player 1 (●)")
                            or  _("Player 2 (○)")
                        self:setInfoMessage(string.format(
                            _("%s bears off all checkers and wins"),
                            winnerLabel
                        ))
                        self:updateTabulaTitle()
                        self:buildTabulaScreen()
                        return
                    end

                    self:tabulaPostMove(current)
                    return
                end
            end
            self.selectedPoint = nil
            self:setInfoMessage(_("Selection cleared"))
            return
        end

        local dir  = 1
        local dist = (idx - src) * dir
        if dist <= 0 then
            self:setInfoMessage(_("You must move forward"))
            self.selectedPoint = nil
            return
        end

        if not self:tabulaAllEntered(current) and src <= 12 and idx > 12 then
            self:setInfoMessage(_("Cannot move beyond 12 until all checkers are entered"))
            self.selectedPoint = nil
            return
        end

        if not consumeTabulaDie(dist) then
            self:setInfoMessage(string.format(_("No die for distance %d"), dist))
            self.selectedPoint = nil
            return
        end

        local dest = src + dist
        if dest > NUM_POINTS then
            if not tabulaCanBearOffFrom(self.board, current, self.tabulaBorneOff, self.tabulaUnentered, self.tabulaBar, src, dist) then
                table.insert(self.tabulaDiceRemaining, dist)
                self:setInfoMessage(_("Illegal bearing off"))
                self.selectedPoint = nil
                return
            end

            local pt = self.board[src]
            pt.counts[current] = pt.counts[current] - 1
            if pt.counts[current] < 0 then
                pt.counts[current] = 0
            end

            self.tabulaBorneOff[current] = (self.tabulaBorneOff[current] or 0) + 1
            self:setInfoMessage(_("Checker borne off (move)"))
            self.selectedPoint = nil

            if self.tabulaBorneOff[current] >= NUM_CHECKERS then
                self.gameOver = true
                local winnerLabel = (current == 1)
                    and _("Player 1 (●)")
                    or  _("Player 2 (○)")
                self:setInfoMessage(string.format(
                    _("%s bears off all checkers and wins"),
                    winnerLabel
                ))
                self:updateTabulaTitle()
                self:buildTabulaScreen()
                return
            end

            self:tabulaPostMove(current)
            return
        end

        if not tabulaCanLandOn(self.board, dest, current) then
            table.insert(self.tabulaDiceRemaining, dist)
            self:setInfoMessage(_("Illegal destination"))
            self.selectedPoint = nil
            return
        end

        self:tabulaMoveFromBoard(src, dest, current)
        self.selectedPoint = nil
        self:setInfoMessage(_("Move played"))
        self:tabulaPostMove(current)
    end
end

----------------------------------------------------------------------
-- PORTES
----------------------------------------------------------------------

local function portesCanLandOn(board, destIdx, player)
    if destIdx < 1 or destIdx > NUM_POINTS then
        return false
    end
    local opp = opponent(player)
    if board[destIdx].counts[opp] >= 2 then
        return false
    end
    return true
end

local function portesCanEnterAt(board, destIdx, player)
    return portesCanLandOn(board, destIdx, player)
end

function BackgammonScreen:rollPortesDice()
    local d1 = math.random(1, 6)
    local d2 = math.random(1, 6)
    self.portesDice = { d1, d2 }
    self.portesDiceRemaining = {}
    if d1 == d2 then
        table.insert(self.portesDiceRemaining, d1)
        table.insert(self.portesDiceRemaining, d1)
        table.insert(self.portesDiceRemaining, d1)
        table.insert(self.portesDiceRemaining, d1)
    else
        table.insert(self.portesDiceRemaining, d1)
        table.insert(self.portesDiceRemaining, d2)
    end
end

function BackgammonScreen:updatePortesTitle()
    if self.mode ~= "portes" then
        return
    end
    local bar1 = self.portesBar[1] or 0
    local bar2 = self.portesBar[2] or 0
    local base = _("PORTES")
    if bar1 > 0 or bar2 > 0 then
        local title = string.format("%s  ● %d  %s  ○ %d", base, bar1, BOARD_MARK, bar2)
        self.statusWidget:setText(title)
    else
        self.statusWidget:setText(base)
    end
end

function BackgammonScreen:startPortes()
    self.mode              = "portes"
    self.board             = createEmptyBoard()
    initPortesStart(self.board)
    self.currentPlayer     = 1
    self.selectedPoint     = nil
    self.gameOver          = false
    self.infoMessageStr    = " "
    self.portesBar         = { [1] = 0, [2] = 0 }
    self.portesBorneOff    = { [1] = 0, [2] = 0 }
    self.portesDice        = {}
    self.portesDiceRemaining = {}
    self.playMode          = self.playMode or "PVP"

    self.statusWidget:setText(_("PORTES"))
    self:rollPortesDice()
    self:updatePortesTitle()
    self:buildPortesScreen()
end

function BackgammonScreen:portesEnterFromBar(destIdx, player)
    local opp = opponent(player)
    local pt  = self.board[destIdx]
    local oppCount = pt.counts[opp]

    if oppCount == 1 then
        pt.counts[opp] = 0
        self.portesBar[opp] = (self.portesBar[opp] or 0) + 1
    end

    pt.counts[player] = pt.counts[player] + 1
    self.portesBar[player] = (self.portesBar[player] or 0) - 1
    if self.portesBar[player] < 0 then
        self.portesBar[player] = 0
    end
end

function BackgammonScreen:portesMoveFromBoard(srcIdx, destIdx, player)
    local opp = opponent(player)
    local src = self.board[srcIdx]
    src.counts[player] = src.counts[player] - 1
    if src.counts[player] < 0 then
        src.counts[player] = 0
    end

    local dst = self.board[destIdx]
    local oppCount = dst.counts[opp]
    if oppCount == 1 then
        dst.counts[opp] = 0
        self.portesBar[opp] = (self.portesBar[opp] or 0) + 1
    end
    dst.counts[player] = dst.counts[player] + 1
end

function BackgammonScreen:portesHasAnyMove(player)
    local dice = self.portesDiceRemaining
    if #dice == 0 then
        return false
    end

    local bar = self.portesBar[player] or 0

    if bar > 0 then
        -- must re-enter from bar
        for _, d in ipairs(dice) do
            local dest
            if player == 1 then
                dest = d
            else
                dest = 25 - d
            end
            if dest >= 1 and dest <= NUM_POINTS and portesCanEnterAt(self.board, dest, player) then
                return true
            end
        end
        return false
    end

    for src = 1, NUM_POINTS do
        local cnt = self.board[src].counts[player]
        if cnt > 0 then
            for _, d in ipairs(dice) do
                local dir  = (player == 1) and 1 or -1
                local dest = src + dir * d
                if dest >= 1 and dest <= NUM_POINTS then
                    if portesCanLandOn(self.board, dest, player) then
                        return true
                    end
                else
                    if portesCanBearOffFrom(self.board, player, self.portesBorneOff, self.portesBar, src, d) then
                        return true
                    end
                end
            end
        end
    end

    return false
end

-- ---------- PORTES AI ----------

function BackgammonScreen:portesGenerateAIMoves(player)
    local moves = {}
    local dice  = self.portesDiceRemaining
    if #dice == 0 then
        return moves
    end

    local bar = self.portesBar[player] or 0
    local opp = opponent(player)
    local dir = (player == 1) and 1 or -1

    local function scoreMove(kind, src, dest, hitsOpp, createdPoint, leavesBlotBehind, bearingOff)
        local score = 0
        if bearingOff then
            score = score + 30
        end
        if dest then
            score = score + (player == 1 and dest or (NUM_POINTS - dest + 1))
        end
        if hitsOpp then
            score = score + 15
        end
        if createdPoint then
            score = score + 8
        end
        if leavesBlotBehind then
            score = score - 6
        end
        if kind == "enter_bar" then
            score = score + 10
        end
        return score
    end

    if bar > 0 then
        for dieIndex, d in ipairs(dice) do
            local dest
            if player == 1 then
                dest = d
            else
                dest = 25 - d
            end
            if dest >= 1 and dest <= NUM_POINTS and portesCanEnterAt(self.board, dest, player) then
                local ptDest      = self.board[dest]
                local hitsOpp     = (ptDest.counts[opp] == 1)
                local createdPoint = (ptDest.counts[player] + 1 >= 2)
                local s = scoreMove("enter_bar", nil, dest, hitsOpp, createdPoint, false, false)
                table.insert(moves, {
                    kind     = "enter_bar",
                    dest     = dest,
                    dieIndex = dieIndex,
                    dieVal   = d,
                    score    = s,
                })
            end
        end
        return moves
    end

    for src = 1, NUM_POINTS do
        local cnt = self.board[src].counts[player]
        if cnt > 0 then
            for dieIndex, d in ipairs(dice) do
                local dest = src + dir * d
                if dest >= 1 and dest <= NUM_POINTS then
                    if portesCanLandOn(self.board, dest, player) then
                        local ptDest      = self.board[dest]
                        local hitsOpp     = (ptDest.counts[opp] == 1)
                        local createdPoint = (ptDest.counts[player] + 1 >= 2)
                        local leavesBlot   = (cnt - 1 == 1)
                        local s = scoreMove("move", src, dest, hitsOpp, createdPoint, leavesBlot, false)
                        table.insert(moves, {
                            kind     = "move",
                            src      = src,
                            dest     = dest,
                            dieIndex = dieIndex,
                            dieVal   = d,
                            score    = s,
                        })
                    end
                else
                    if portesCanBearOffFrom(self.board, player, self.portesBorneOff, self.portesBar, src, d) then
                        local leavesBlot = (cnt - 1 == 1)
                        local s = scoreMove("bearoff", src, nil, false, false, leavesBlot, true)
                        table.insert(moves, {
                            kind     = "bearoff",
                            src      = src,
                            dieIndex = dieIndex,
                            dieVal   = d,
                            score    = s,
                        })
                    end
                end
            end
        end
    end

    return moves
end

function BackgammonScreen:portesChooseAIMove(player)
    local moves = self:portesGenerateAIMoves(player)
    if #moves == 0 then
        return nil
    end

    if self.playMode == "AI_E" then
        local subsetSize = math.max(1, math.floor(#moves / 2))
        local best = nil
        for i = 1, subsetSize do
            local idx = math.random(1, #moves)
            local m = moves[idx]
            if not best or m.score > best.score then
                best = m
            end
        end
        return best
    else
        local best = moves[1]
        for i = 2, #moves do
            if moves[i].score > best.score then
                best = moves[i]
            end
        end
        return best
    end
end

function BackgammonScreen:portesPerformSingleAIMove(player)
    if self.gameOver then
        return false
    end
    if #self.portesDiceRemaining == 0 then
        return false
    end

    local move = self:portesChooseAIMove(player)
    if not move then
        self:setInfoMessage(_("AI has no legal moves"))
        return false
    end

    table.remove(self.portesDiceRemaining, move.dieIndex)

    if move.kind == "enter_bar" then
        self:portesEnterFromBar(move.dest, player)
        self:setInfoMessage(_("AI enters from bar"))
        return true
    elseif move.kind == "move" then
        self:portesMoveFromBoard(move.src, move.dest, player)
        self:setInfoMessage(_("AI moves"))
        return true
    elseif move.kind == "bearoff" then
        local pt = self.board[move.src]
        pt.counts[player] = pt.counts[player] - 1
        if pt.counts[player] < 0 then
            pt.counts[player] = 0
        end
        self.portesBorneOff[player] = (self.portesBorneOff[player] or 0) + 1
        self:setInfoMessage(_("AI bears off a checker"))
        if self.portesBorneOff[player] >= NUM_CHECKERS then
            self.gameOver = true
            local winnerLabel = (player == 1) and _("Player 1 (●)") or _("Player 2 (○)")
            self:setInfoMessage(string.format(
                _("%s bears off all checkers and wins"),
                winnerLabel
            ))
        end
        return true
    end

    return false
end

function BackgammonScreen:startPortesAITurn()
    if self.gameOver then
        return
    end
    if not self:isAIPlayer(self.currentPlayer) then
        return
    end
    UIManager:scheduleIn(self.aiDelay, function()
        self:continuePortesAITurn()
    end)
end

function BackgammonScreen:continuePortesAITurn()
    if self.gameOver then
        return
    end
    local current = self.currentPlayer
    if not self:isAIPlayer(current) then
        return
    end

    if #self.portesDiceRemaining == 0 or not self:portesHasAnyMove(current) then
        self:portesNextPlayerTurn()
        return
    end

    local moved = self:portesPerformSingleAIMove(current)
    self:updatePortesTitle()
    self:buildPortesScreen()

    if not moved or self.gameOver then
        if not self.gameOver then
            self:portesNextPlayerTurn()
        end
        return
    end

    if #self.portesDiceRemaining == 0 or not self:portesHasAnyMove(current) then
        self:portesNextPlayerTurn()
    else
        UIManager:scheduleIn(self.aiDelay, function()
            self:continuePortesAITurn()
        end)
    end
end

-- ---------- PORTES turn flow ----------

function BackgammonScreen:portesNextPlayerTurn()
    if self.gameOver then
        return
    end
    self.currentPlayer = opponent(self.currentPlayer)
    self.selectedPoint = nil
    self:rollPortesDice()
    self.infoMessageStr = " "
    self:updatePortesTitle()
    self:buildPortesScreen()

    if self:isAIPlayer(self.currentPlayer) then
        self:startPortesAITurn()
    end
end

function BackgammonScreen:portesPostMove(player)
    self:updatePortesTitle()
    if #self.portesDiceRemaining == 0 or not self:portesHasAnyMove(player) then
        self:portesNextPlayerTurn()
    else
        self:buildPortesScreen()
    end
end

-- ---------- PORTES info + controls ----------

function BackgammonScreen:buildPortesInfoAndControls()
    local current   = self.currentPlayer
    local moveToken = (current == 1) and "●" or "○"

    local diceText     = string.format(_("Dice: %s"), diceToString(self.portesDiceRemaining))
    local combinedText = string.format("%s to move  %s  %s", moveToken, BOARD_MARK, diceText)

    local whiteRemaining = NUM_CHECKERS - (self.portesBorneOff[1] or 0)
    local blackRemaining = NUM_CHECKERS - (self.portesBorneOff[2] or 0)
    local piecesLine = string.format("● - %d  %s  ○ - %d", whiteRemaining, BOARD_MARK, blackRemaining)

    self.infoMessageWidget = TextWidget:new{
        text = self.infoMessageStr or " ",
        face = Font:getFace("smallinfofont"),
    }
    self:setInfoMessage(self.infoMessageStr)

    local info = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = piecesLine,
            face = Font:getFace("smallinfofont"),
        },
        VerticalSpan:new{ height = Size.span.vertical_small },
        TextWidget:new{
            text = combinedText,
            face = Font:getFace("smallinfofont"),
        },
        VerticalSpan:new{ height = Size.span.vertical_small },
        self.infoMessageWidget,
    }

    local controls = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = "MODE: " .. modeLabel(self.playMode),
            callback = function()
                if self.gameOver then
                    return
                end
                self:cyclePlayMode()
            end,
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        Button:new{
            text = _("MAIN MENU"),
            callback = function()
                self:buildModeMenu()
            end,
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        Button:new{
            text = _("CLOSE"),
            callback = function()
                self:onClose()
                UIManager:close(self)
                UIManager:setDirty(nil, "full")
            end,
        },
    }

    local block = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ height = Size.span.vertical_medium },
        info,
        VerticalSpan:new{ height = Size.span.vertical_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        controls,
    }

    return block
end

function BackgammonScreen:buildPortesScreen()
    local board = self:renderPlakotoBoard()
    local info  = self:buildPortesInfoAndControls()

    local layout = VerticalGroup:new{
        align = "center",
        board,
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        info,
    }

    self:setScreen(layout)
end

-- ---------- PORTES interaction ----------

function BackgammonScreen:onPointTappedPortes(idx)
    if self.mode ~= "portes" then
        return
    end
    if self.gameOver then
        return
    end

    if self:isAIPlayer(self.currentPlayer) then
        return
    end

    if #self.portesDiceRemaining == 0 then
        self:portesNextPlayerTurn()
        return
    end

    local current = self.currentPlayer
    local bar     = self.portesBar[current] or 0

    local function consumePortesDie(val)
        return consumeDieByValue(self.portesDiceRemaining, val)
    end

    local function tryEnterFromBar()
        if bar <= 0 then
            return false
        end

        local dieNeeded
        if current == 1 then
            dieNeeded = idx
        else
            dieNeeded = 25 - idx
        end

        if dieNeeded < 1 or dieNeeded > 6 then
            return false
        end

        if not portesCanEnterAt(self.board, idx, current) then
            return false
        end

        if not consumePortesDie(dieNeeded) then
            return false
        end

        self:portesEnterFromBar(idx, current)
        self:setInfoMessage(_("Entered from bar"))
        self:portesPostMove(current)
        return true
    end

    if not self.selectedPoint then
        if bar > 0 then
            if not tryEnterFromBar() then
                if not self:portesHasAnyMove(current) then
                    self:setInfoMessage(_("No legal re-entry; turn passes"))
                    self:portesNextPlayerTurn()
                else
                    self:setInfoMessage(_("Must re-enter from bar using matching die"))
                end
            end
            return
        end

        if self.board[idx].counts[current] > 0 then
            self.selectedPoint = idx
            self:setInfoMessage(string.format(_("Selected point %d"), idx))
        else
            self:setInfoMessage(_("No movable checker on that point"))
        end
        return
    else
        local src = self.selectedPoint

        if src == idx then
            if portesAllCheckersInHome(self.board, current, self.portesBorneOff, self.portesBar) then
                local srcLocal = localHomeIndex(src, current)
                local dieIndex, dieVal = nearestDieForHome(self.portesDiceRemaining, srcLocal)
                if dieIndex and dieVal and portesCanBearOffFrom(self.board, current, self.portesBorneOff, self.portesBar, src, dieVal) then
                    table.remove(self.portesDiceRemaining, dieIndex)
                    local pt = self.board[src]
                    pt.counts[current] = pt.counts[current] - 1
                    if pt.counts[current] < 0 then
                        pt.counts[current] = 0
                    end
                    self.portesBorneOff[current] = (self.portesBorneOff[current] or 0) + 1
                    self:setInfoMessage(_("Checker borne off"))

                    self.selectedPoint = nil

                    if self.portesBorneOff[current] >= NUM_CHECKERS then
                        self.gameOver = true
                        local winnerLabel = (current == 1)
                            and _("Player 1 (●)")
                            or  _("Player 2 (○)")
                        self:setInfoMessage(string.format(
                            _("%s bears off all checkers and wins"),
                            winnerLabel
                        ))
                        self:updatePortesTitle()
                        self:buildPortesScreen()
                        return
                    end

                    self:portesPostMove(current)
                    return
                end
            end
            self.selectedPoint = nil
            self:setInfoMessage(_("Selection cleared"))
            return
        end

        local dir  = (current == 1) and 1 or -1
        local dist = (idx - src) * dir
        if dist <= 0 then
            self:setInfoMessage(_("You must move forward"))
            self.selectedPoint = nil
            return
        end

        if not consumePortesDie(dist) then
            self:setInfoMessage(string.format(_("No die for distance %d"), dist))
            self.selectedPoint = nil
            return
        end

        local dest = src + dir * dist

        if dest < 1 or dest > NUM_POINTS then
            -- Attempt bearing off with exact move (only valid from home board)
            if not portesCanBearOffFrom(self.board, current, self.portesBorneOff, self.portesBar, src, dist) then
                table.insert(self.portesDiceRemaining, dist)
                self:setInfoMessage(_("Illegal bearing off"))
                self.selectedPoint = nil
                return
            end

            local pt = self.board[src]
            pt.counts[current] = pt.counts[current] - 1
            if pt.counts[current] < 0 then
                pt.counts[current] = 0
            end

            self.portesBorneOff[current] = (self.portesBorneOff[current] or 0) + 1
            self:setInfoMessage(_("Checker borne off"))
            self.selectedPoint = nil

            if self.portesBorneOff[current] >= NUM_CHECKERS then
                self.gameOver = true
                local winnerLabel = (current == 1)
                    and _("Player 1 (●)")
                    or  _("Player 2 (○)")
                self:setInfoMessage(string.format(
                    _("%s bears off all checkers and wins"),
                    winnerLabel
                ))
                self:updatePortesTitle()
                self:buildPortesScreen()
                return
            end

            self:portesPostMove(current)
            return
        end

        if not portesCanLandOn(self.board, dest, current) then
            table.insert(self.portesDiceRemaining, dist)
            self:setInfoMessage(_("Illegal destination"))
            self.selectedPoint = nil
            return
        end

        self:portesMoveFromBoard(src, dest, current)
        self.selectedPoint = nil
        self:setInfoMessage(_("Move played"))
        self:portesPostMove(current)
    end
end

----------------------------------------------------------------------
-- FEVGA
-- (No hitting, first checker must reach opponent’s start before others move)
----------------------------------------------------------------------

-- Update "first checker away" status for Fevga.
function BackgammonScreen:fevgaUpdateFirstPassed(player)
    if self.fevgaFirstPassed[player] then
        return
    end
    local startIdx    = FEVGA_START[player]
    local oppStartIdx = FEVGA_START[opponent(player)]
    local dir         = (player == 1) and 1 or -1
    local distToOpp   = (oppStartIdx - startIdx) * dir

    if distToOpp <= 0 then
        return
    end

    for idx = 1, NUM_POINTS do
        local cnt = self.board[idx].counts[player]
        if cnt > 0 then
            local distFromStart = (idx - startIdx) * dir
            if distFromStart >= distToOpp then
                self.fevgaFirstPassed[player] = true
                return
            end
        end
    end
end

-- Fevga move application (no hitting, no bar).
function BackgammonScreen:fevgaApplyMove(srcIdx, destIdx, player)
    if destIdx < 1 or destIdx > NUM_POINTS then
        return false, "Bearing off not handled here"
    end

    local src = self.board[srcIdx]
    if src.counts[player] <= 0 then
        return false, "No checker to move"
    end

    local opp = opponent(player)
    local dst = self.board[destIdx]

    if dst.counts[opp] > 0 then
        return false, _("Destination blocked")
    end

    src.counts[player] = src.counts[player] - 1
    dst.counts[player] = dst.counts[player] + 1
    return true
end

-- Check if any bearing-off move exists in Fevga (reuse helpers).
local function fevgaAnyBearingOff(board, player, borneOff, diceRemaining)
    if not allCheckersInHome(board, player, borneOff) then
        return false
    end
    for src = 1, NUM_POINTS do
        if board[src].counts[player] > 0 and isInHomeBoard(src, player) then
            local srcLocal = localHomeIndex(src, player)
            local dieIndex, dieVal = nearestDieForHome(diceRemaining, srcLocal)
            if dieIndex and dieVal and canBearOffFrom(board, player, borneOff, src, dieVal) then
                return true
            end
        end
    end
    return false
end

function BackgammonScreen:startFevga()
    self.mode              = "fevga"
    self.board             = createEmptyBoard()
    initFevgaStart(self.board)
    self.currentPlayer     = 1
    self.selectedPoint     = nil
    self.gameOver          = false
    self.infoMessageStr    = " "
    self.borneOff          = { [1] = 0, [2] = 0 }
    self.fevgaFirstPassed  = { [1] = false, [2] = false }
    self.playMode          = self.playMode or "PVP"

    self.statusWidget:setText(_("FEVGA"))
    self:rollNewTurnDice()
    self:buildFevgaScreen()
end

-- ---------- FEVGA AI ----------

function BackgammonScreen:fevgaGenerateAIMoves(player)
    local moves = {}
    local dice  = self.diceRemaining
    if not dice or #dice == 0 then
        return moves
    end

    local dir         = (player == 1) and 1 or -1
    local firstPassed = self.fevgaFirstPassed[player]
    local startIdx    = FEVGA_START[player]

    local function scoreMove(src, dest, leavesBlot, createsStack)
        local score = 0
        -- prefer advancing
        score = score + (player == 1 and dest or (NUM_POINTS - dest + 1))
        if createsStack then
            score = score + 6
        end
        if leavesBlot then
            score = score - 4
        end
        return score
    end

    for src = 1, NUM_POINTS do
        local cnt = self.board[src].counts[player]
        if cnt > 0 and fevgaHasMovableCheckerAt(self.board, src, player, firstPassed, startIdx) then
            for dieIndex, d in ipairs(dice) do
                local dest = src + dir * d
                if dest >= 1 and dest <= NUM_POINTS and fevgaCanLandOn(self.board, dest, player) then
                    local dst = self.board[dest]
                    local createsStack = (dst.counts[player] + 1 >= 2)
                    local leavesBlot   = (cnt - 1 == 1)
                    local s = scoreMove(src, dest, leavesBlot, createsStack)
                    table.insert(moves, {
                        src      = src,
                        dest     = dest,
                        dieIndex = dieIndex,
                        dieVal   = d,
                        score    = s,
                    })
                end
            end
        end
    end

    return moves
end

function BackgammonScreen:fevgaChooseAIMove(player)
    local moves = self:fevgaGenerateAIMoves(player)
    if #moves == 0 then
        return nil
    end

    if self.playMode == "AI_E" then
        local subsetSize = math.max(1, math.floor(#moves / 2))
        local best = nil
        for i = 1, subsetSize do
            local idx = math.random(1, #moves)
            local m = moves[idx]
            if not best or m.score > best.score then
                best = m
            end
        end
        return best
    else
        local best = moves[1]
        for i = 2, #moves do
            if moves[i].score > best.score then
                best = moves[i]
            end
        end
        return best
    end
end

function BackgammonScreen:fevgaPerformSingleAIMove(player)
    if self.gameOver then
        return false
    end
    if #self.diceRemaining == 0 then
        return false
    end

    local move = self:fevgaChooseAIMove(player)
    if not move then
        self:setInfoMessage(_("AI has no legal moves"))
        return false
    end

    table.remove(self.diceRemaining, move.dieIndex)

    local ok, err = self:fevgaApplyMove(move.src, move.dest, player)
    if not ok then
        self:setInfoMessage(err or _("AI move failed"))
        return false
    end

    self:fevgaUpdateFirstPassed(player)
    self:setInfoMessage(_("AI moves"))
    return true
end

function BackgammonScreen:startFevgaAITurn()
    if self.gameOver then
        return
    end
    if not self:isAIPlayer(self.currentPlayer) then
        return
    end
    UIManager:scheduleIn(self.aiDelay, function()
        self:continueFevgaAITurn()
    end)
end

function BackgammonScreen:continueFevgaAITurn()
    if self.gameOver then
        return
    end
    local current = self.currentPlayer
    if not self:isAIPlayer(current) then
        return
    end

    if #self.diceRemaining == 0 or (not fevgaHasAnyMove(self.board, current, self.diceRemaining, self.fevgaFirstPassed[current]) and not fevgaAnyBearingOff(self.board, current, self.borneOff, self.diceRemaining)) then
        self:fevgaNextPlayerTurn()
        return
    end

    local moved = self:fevgaPerformSingleAIMove(current)
    self:buildFevgaScreen()

    if not moved or self.gameOver then
        if not self.gameOver then
            self:fevgaNextPlayerTurn()
        end
        return
    end

    if #self.diceRemaining == 0 or (not fevgaHasAnyMove(self.board, current, self.diceRemaining, self.fevgaFirstPassed[current]) and not fevgaAnyBearingOff(self.board, current, self.borneOff, self.diceRemaining)) then
        self:fevgaNextPlayerTurn()
    else
        UIManager:scheduleIn(self.aiDelay, function()
            self:continueFevgaAITurn()
        end)
    end
end

-- ---------- FEVGA turn flow ----------

function BackgammonScreen:fevgaNextPlayerTurn()
    if self.gameOver then
        return
    end
    self.currentPlayer = opponent(self.currentPlayer)
    self.selectedPoint = nil
    self:rollNewTurnDice()
    self.infoMessageStr = " "
    self:buildFevgaScreen()

    if self:isAIPlayer(self.currentPlayer) then
        self:startFevgaAITurn()
    end
end

function BackgammonScreen:fevgaPostMove(player)
    if #self.diceRemaining == 0
        or (not fevgaHasAnyMove(self.board, player, self.diceRemaining, self.fevgaFirstPassed[player])
            and not fevgaAnyBearingOff(self.board, player, self.borneOff, self.diceRemaining)) then
        self:fevgaNextPlayerTurn()
    else
        self:buildFevgaScreen()
    end
end

-- ---------- FEVGA info + controls ----------

function BackgammonScreen:buildFevgaInfoAndControls()
    local current   = self.currentPlayer
    local moveToken = (current == 1) and "●" or "○"

    local diceText     = string.format(_("Dice: %s"), diceToString(self.diceRemaining))
    local combinedText = string.format("%s to move  %s  %s", moveToken, BOARD_MARK, diceText)

    local whiteRemaining = NUM_CHECKERS - (self.borneOff[1] or 0)
    local blackRemaining = NUM_CHECKERS - (self.borneOff[2] or 0)
    local piecesLine = string.format("● - %d  %s  ○ - %d", whiteRemaining, BOARD_MARK, blackRemaining)

    self.infoMessageWidget = TextWidget:new{
        text = self.infoMessageStr or " ",
        face = Font:getFace("smallinfofont"),
    }
    self:setInfoMessage(self.infoMessageStr)

    local info = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = piecesLine,
            face = Font:getFace("smallinfofont"),
        },
        VerticalSpan:new{ height = Size.span.vertical_small },
        TextWidget:new{
            text = combinedText,
            face = Font:getFace("smallinfofont"),
        },
        VerticalSpan:new{ height = Size.span.vertical_small },
        self.infoMessageWidget,
    }

    local controls = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = "MODE: " .. modeLabel(self.playMode),
            callback = function()
                if self.gameOver then
                    return
                end
                self:cyclePlayMode()
            end,
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        Button:new{
            text = _("MAIN MENU"),
            callback = function()
                self:buildModeMenu()
            end,
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        HorizontalSpan:new{ width = Size.span.horizontal_medium },
        Button:new{
            text = _("CLOSE"),
            callback = function()
                self:onClose()
                UIManager:close(self)
                UIManager:setDirty(nil, "full")
            end,
        },
    }

    local block = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ height = Size.span.vertical_medium },
        info,
        VerticalSpan:new{ height = Size.span.vertical_medium },
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        controls,
    }

    return block
end

function BackgammonScreen:buildFevgaScreen()
    local board = self:renderPlakotoBoard()
    local info  = self:buildFevgaInfoAndControls()

    local layout = VerticalGroup:new{
        align = "center",
        board,
        TextWidget:new{
            text = BLANK_MARK,
            face = Font:getFace("smallinfofont"),
        },
        info,
    }

    self:setScreen(layout)
end

-- ---------- FEVGA interaction ----------

function BackgammonScreen:onPointTappedFevga(idx)
    if self.mode ~= "fevga" then
        return
    end
    if self.gameOver then
        return
    end

    if self:isAIPlayer(self.currentPlayer) then
        return
    end

    if #self.diceRemaining == 0 then
        self:fevgaNextPlayerTurn()
        return
    end

    local current     = self.currentPlayer
    local dir         = (current == 1) and 1 or -1
    local startIdx    = FEVGA_START[current]
    local firstPassed = self.fevgaFirstPassed[current]

    if not self.selectedPoint then
        if fevgaHasMovableCheckerAt(self.board, idx, current, firstPassed, startIdx) then
            self.selectedPoint = idx
            self:setInfoMessage(string.format(_("Selected point %d"), idx))
        else
            if self.board[idx].counts[current] > 0 and not firstPassed and idx ~= startIdx then
                self:setInfoMessage(_("First checker must reach opponent's start before moving others"))
            else
                self:setInfoMessage(_("No movable checker on that point"))
            end
        end
        return
    else
        local src = self.selectedPoint

        if src == idx then
            if allCheckersInHome(self.board, current, self.borneOff) then
                local srcLocal = localHomeIndex(src, current)
                local dieIndex, dieVal = nearestDieForHome(self.diceRemaining, srcLocal)
                if dieIndex and dieVal and canBearOffFrom(self.board, current, self.borneOff, src, dieVal) then
                    table.remove(self.diceRemaining, dieIndex)
                    local pt = self.board[src]
                    pt.counts[current] = pt.counts[current] - 1
                    if pt.counts[current] < 0 then
                        pt.counts[current] = 0
                    end
                    self.borneOff[current] = (self.borneOff[current] or 0) + 1
                    self:setInfoMessage(_("Checker borne off"))

                    self.selectedPoint = nil

                    if self.borneOff[current] >= NUM_CHECKERS then
                        self.gameOver = true
                        local winnerLabel = (current == 1)
                            and _("Player 1 (●)")
                            or  _("Player 2 (○)")
                        self:setInfoMessage(string.format(
                            _("%s bears off all checkers and wins"),
                            winnerLabel
                        ))
                        self:buildFevgaScreen()
                        return
                    end

                    self:fevgaUpdateFirstPassed(current)
                    self:fevgaPostMove(current)
                    return
                end
            end
            self.selectedPoint = nil
            self:setInfoMessage(_("Selection cleared"))
            return
        end

        local dist = (idx - src) * dir
        if dist <= 0 then
            self:setInfoMessage(_("You must move forward"))
            self.selectedPoint = nil
            return
        end

        if not consumeDie(self.diceRemaining, dist) then
            self:setInfoMessage(string.format(_("No die for distance %d"), dist))
            self.selectedPoint = nil
            return
        end

        local dest = src + dir * dist
        if not fevgaCanLandOn(self.board, dest, current) then
            table.insert(self.diceRemaining, dist)
            self:setInfoMessage(_("Illegal destination"))
            self.selectedPoint = nil
            return
        end

        local ok, err = self:fevgaApplyMove(src, dest, current)
        if not ok then
            table.insert(self.diceRemaining, dist)
            self:setInfoMessage(err or _("Move failed"))
            self.selectedPoint = nil
            return
        end

        self.selectedPoint = nil
        self:fevgaUpdateFirstPassed(current)
        self:setInfoMessage(_("Move played"))
        self:fevgaPostMove(current)
    end
end

----------------------------------------------------------------------
-- Screen close
----------------------------------------------------------------------

function BackgammonScreen:onClose()
    if self.plugin and self.plugin.onScreenClosed then
        self.plugin:onScreenClosed()
    end
end

----------------------------------------------------------------------
-- Plugin container
----------------------------------------------------------------------

local Backgammon = WidgetContainer:extend{
    name        = "backgammon",
    is_doc_only = false,
}

function Backgammon:init()
    self.ui.menu:registerToMainMenu(self)
end

function Backgammon:addToMainMenu(menu_items)
    menu_items.backgammon = {
        text         = _("Backgammon"),
        sorting_hint = "tools",
        callback     = function()
            self:showGame()
        end,
    }
end

function Backgammon:showGame()
    if self.screen then
        return
    end
    self.screen = BackgammonScreen:new{
        plugin = self,
    }
    UIManager:show(self.screen)
end

function Backgammon:onScreenClosed()
    self.screen = nil
end

return Backgammon
