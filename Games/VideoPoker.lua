-- ============================================================================
-- VoidCasino - Games/VideoPoker.lua
-- Singleplayer 9/6 Jacks or Better Video Poker | Uses Shared Cards.lua
-- ============================================================================

local ADDON_NAME, ns = ...
local COLORS = ns.COLORS
local Cards  = ns.Cards

local VideoPoker = {}

-- Constants (grouped into CFG to stay well under Lua 5.1's 60-upvalue limit)
local CFG = {
    NUM_CARDS        = 5,
    CARD_W           = 88,
    CARD_H           = 128,
    CARD_GAP         = 14,
    NUM_HISTORY_ROWS = 5,

    -- Full-Pay 9/6 Jacks or Better Paytable (9 tiers ordered high to low)
    PAYTABLE = {
        { id = "ROYAL_FLUSH",     label = "Royal Flush",     short = "Royal Flush", mult = 800 },
        { id = "STRAIGHT_FLUSH",  label = "Straight Flush",  short = "Str. Flush",  mult = 50  },
        { id = "FOUR_KIND",       label = "4 of a Kind",     short = "4 of a Kind", mult = 25  },
        { id = "FULL_HOUSE",      label = "Full House",      short = "Full House",  mult = 9   },
        { id = "FLUSH",           label = "Flush",           short = "Flush",       mult = 6   },
        { id = "STRAIGHT",        label = "Straight",        short = "Straight",    mult = 4   },
        { id = "THREE_KIND",      label = "3 of a Kind",     short = "3 of a Kind", mult = 3   },
        { id = "TWO_PAIR",        label = "Two Pair",        short = "Two Pair",    mult = 2   },
        { id = "JACKS_OR_BETTER", label = "Jacks or Better", short = "Jacks+",      mult = 1   },
    },
}

-- Runtime State (grouped into ST)
local ST = {
    deck             = nil,
    state            = "IDLE", -- "IDLE", "PLAYER_HOLD", "RESULT"
    hand             = {},
    held             = { false, false, false, false, false },
    activeBet        = 0,
    currentRoundHash = "",
    activeHandId     = "NONE",
    activeWinIndices = {},
    statusBannerText = "|cff888899Place your bet and click Deal|r",
}

-- UI References (grouped into UI)
local UI = {
    PokerFrame    = nil,
    MainBtn       = nil,
    MainBtnText   = nil,
    BetInput      = nil,
    BtnHalf       = nil,
    Btn2x         = nil,
    BtnMax        = nil,
    StatusText    = nil,
    CardFrames    = {},
    HoldButtons   = {},
    PaytableCells = {},
    PersonalRows  = {},
}

-- ============================================================================
-- Helpers & 9/6 Jacks or Better Hand Evaluator
-- ============================================================================
local function EnsureDeck()
    if not ST.deck then
        ST.deck = Cards.NewDeck(1)
    end
end

local function SetButtonEnabled(btn, enabled)
    if not btn then return end
    if enabled then
        btn:Enable()
        btn:SetAlpha(1.0)
    else
        btn:Disable()
        btn:SetAlpha(0.35)
    end
end

local function FormatCompactPayout(amount)
    if amount >= 100000 then
        return string.format("%.0fk", amount / 1000)
    elseif amount >= 1000 then
        return string.format("%.1fk", amount / 1000)
    elseif math.abs(amount - math.floor(amount + 0.5)) < 0.005 then
        return string.format("%d", math.floor(amount + 0.5))
    end
    return string.format("%.1f", amount)
end

local function EvaluatePokerHand(cards)
    if not cards or #cards ~= 5 then
        return "NONE", "No Hand", "No Hand", 0, {}
    end

    local ranks = {}
    local rankCounts = {}
    local suitCounts = {}
    for i = 1, 5 do
        local rv = Cards.GetRankValue(cards[i].rank, true)
        local s  = cards[i].suit
        ranks[i] = rv
        rankCounts[rv] = (rankCounts[rv] or 0) + 1
        suitCounts[s]  = (suitCounts[s] or 0) + 1
    end

    local isFlush = false
    for _, cnt in pairs(suitCounts) do
        if cnt == 5 then
            isFlush = true
            break
        end
    end

    local distinct = {}
    for rv, cnt in pairs(rankCounts) do
        table.insert(distinct, { rank = rv, count = cnt })
    end
    table.sort(distinct, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.rank > b.rank
    end)

    local isStraight = false
    local isRoyal    = false
    if #distinct == 5 then
        local r1, r2, r3, r4, r5 = distinct[1].rank, distinct[2].rank, distinct[3].rank, distinct[4].rank, distinct[5].rank
        if (r1 - r5) == 4 then
            isStraight = true
            isRoyal = (r1 == 14)
        elseif r1 == 14 and r2 == 5 and r3 == 4 and r4 == 3 and r5 == 2 then
            isStraight = true
        end
    end

    local function MarkAll()
        return { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }
    end

    local function MarkRanks(target1, target2)
        local set = {}
        for i = 1, 5 do
            if ranks[i] == target1 or (target2 and ranks[i] == target2) then
                set[i] = true
            end
        end
        return set
    end

    if isFlush and isStraight then
        if isRoyal then
            return "ROYAL_FLUSH", "Royal Flush", "Royal Flush", 800, MarkAll()
        end
        return "STRAIGHT_FLUSH", "Straight Flush", "Str. Flush", 50, MarkAll()
    elseif distinct[1].count == 4 then
        return "FOUR_KIND", "4 of a Kind", "4 of a Kind", 25, MarkRanks(distinct[1].rank)
    elseif distinct[1].count == 3 and distinct[2] and distinct[2].count == 2 then
        return "FULL_HOUSE", "Full House", "Full House", 9, MarkAll()
    elseif isFlush then
        return "FLUSH", "Flush", "Flush", 6, MarkAll()
    elseif isStraight then
        return "STRAIGHT", "Straight", "Straight", 4, MarkAll()
    elseif distinct[1].count == 3 then
        return "THREE_KIND", "3 of a Kind", "3 of a Kind", 3, MarkRanks(distinct[1].rank)
    elseif distinct[1].count == 2 and distinct[2] and distinct[2].count == 2 then
        return "TWO_PAIR", "Two Pair", "Two Pair", 2, MarkRanks(distinct[1].rank, distinct[2].rank)
    elseif distinct[1].count == 2 and distinct[1].rank >= 11 then
        return "JACKS_OR_BETTER", "Jacks or Better", "Jacks+", 1, MarkRanks(distinct[1].rank)
    end

    return "NONE", "No Hand", "No Hand", 0, {}
end

local function LogPokerPersonal(entry)
    local db = ns.db
    if not db then return end
    db.pokerPersonalLog = db.pokerPersonalLog or {}
    table.insert(db.pokerPersonalLog, 1, entry)
    while #db.pokerPersonalLog > 15 do
        table.remove(db.pokerPersonalLog)
    end
end

-- ============================================================================
-- Visual Updates (Paytable, Cards, Hold Buttons)
-- ============================================================================
local function UpdatePaytableVisuals()
    local refBet = (ST.state == "PLAYER_HOLD")
        and ST.activeBet
        or (tonumber(UI.BetInput and UI.BetInput:GetText()) or 0)
    if refBet < 0 then refBet = 0 end

    for _, tier in ipairs(CFG.PAYTABLE) do
        local cell = UI.PaytableCells[tier.id]
        if cell then
            local isMatch = (ST.activeHandId == tier.id)
            local bgCol   = isMatch and COLORS.purpleBtn or COLORS.bgInput
            local brdCol  = isMatch and COLORS.purpleBright or COLORS.border
            ns.StyleBox(cell, bgCol, brdCol)

            if isMatch then
                cell.nameText:SetTextColor(1, 1, 1, 1)
                cell.payText:SetTextColor(0.95, 0.90, 1.00, 1)
            else
                cell.nameText:SetTextColor(unpack(COLORS.textMuted))
                cell.payText:SetTextColor(0.86, 0.72, 1.00, 1.00)
            end

            if refBet > 0 then
                cell.payText:SetText(string.format("%dx (%s)", tier.mult, FormatCompactPayout(refBet * tier.mult)))
            else
                cell.payText:SetText(string.format("%dx", tier.mult))
            end
        end
    end
end

local function UpdateCardRow()
    local isHoldPhase = (ST.state == "PLAYER_HOLD")
    local isResult    = (ST.state == "RESULT")
    local hasWin      = (ST.activeHandId ~= "NONE")

    for i = 1, CFG.NUM_CARDS do
        local cf   = UI.CardFrames[i]
        local hBtn = UI.HoldButtons[i]

        if ST.state == "IDLE" or not ST.hand[i] then
            cf:SetHeld(false)
            cf:SetHighlight("NONE")
            cf:SetDimmed(false)
            cf:SetFaceDown(true)
        elseif isHoldPhase then
            cf:SetCard(ST.hand[i])
            cf:SetHighlight("NONE")
            cf:SetDimmed(false)
            cf:SetHeld(ST.held[i])
        else
            cf:SetCard(ST.hand[i])
            cf:SetHeld(false)
            if hasWin then
                if ST.activeWinIndices[i] then
                    cf:SetHighlight("WIN")
                    cf:SetDimmed(false)
                else
                    cf:SetHighlight("NONE")
                    cf:SetDimmed(true)
                end
            elseif isResult then
                cf:SetHighlight("LOSS")
                cf:SetDimmed(false)
            end
        end

        if hBtn then
            local isHeld = isHoldPhase and ST.held[i]
            hBtn.isPrimary = isHeld
            hBtn.customCol = isHeld and COLORS.purpleBtn or COLORS.bgInput
            ns.StyleBox(hBtn, hBtn.customCol, isHeld and COLORS.purpleBright or COLORS.border)
            hBtn.label:SetText(isHeld and "HELD" or "HOLD")
            SetButtonEnabled(hBtn, isHoldPhase)
        end
    end
end

-- ============================================================================
-- Game Actions: Deal, Toggle Hold, Draw & Settle
-- ============================================================================
local function ToggleHold(idx)
    if ST.state ~= "PLAYER_HOLD" then return end
    ST.held[idx] = not ST.held[idx]
    UpdateCardRow()
end

local function DealNewHand()
    if ST.state == "PLAYER_HOLD" or not UI.BetInput then return end
    UI.BetInput:ClearFocus()
    EnsureDeck()

    local ok, actualBet = ns.DeductCredits(UI.BetInput:GetText())
    if not ok then
        if ns.db and (ns.db.credits or 0) >= 0.01 then
            ST.statusBannerText = "|cffe63946Enter a valid bet amount|r"
            if UI.StatusText then UI.StatusText:SetText(ST.statusBannerText) end
        end
        return
    end
    UI.BetInput:SetText(string.format("%.2f", actualBet))

    -- Fresh shuffle of the 52-card deck for authentic Video Poker odds
    ST.deck:Shuffle()
    ST.hand = {}
    for i = 1, CFG.NUM_CARDS do
        ST.hand[i] = ST.deck:Draw()
        ST.held[i] = false
    end

    ST.activeBet = actualBet
    ST.state     = "PLAYER_HOLD"
    ST.currentRoundHash = ns.GenerateRoundHash(actualBet + 52)
    ns.SetHashText("Hand SHA-Seed: " .. string.sub(ST.currentRoundHash, 1, 24) .. "...")

    local handId, label, _, mult, winSet = EvaluatePokerHand(ST.hand)
    ST.activeHandId     = handId
    ST.activeWinIndices = winSet

    if mult > 0 then
        ST.statusBannerText = string.format("|cffd8b4feDealt: %s (%dx)|r  |cff888899— Click cards to Hold, then Draw|r", label, mult)
    else
        ST.statusBannerText = "|cffd8b4feClick cards to HOLD, then click Draw|r"
    end

    ns.RefreshHub()
end

local function DrawCards()
    if ST.state ~= "PLAYER_HOLD" then return end
    EnsureDeck()

    for i = 1, CFG.NUM_CARDS do
        if not ST.held[i] then
            ST.hand[i] = ST.deck:Draw()
        end
        ST.held[i] = false
    end

    ST.state = "RESULT"
    local handId, label, shortLabel, mult, winSet = EvaluatePokerHand(ST.hand)
    ST.activeHandId     = handId
    ST.activeWinIndices = winSet

    local totalReturned = math.floor(ST.activeBet * mult * 100 + 1e-6) / 100
    local netDelta      = math.floor((totalReturned - ST.activeBet) * 100 + 0.5) / 100
    local shortHash     = string.sub(ST.currentRoundHash, 1, 16)
    local playerDisp    = ns.FormatPlayerName(ns.GetMyFormattedName())

    if totalReturned > 0 then
        ns.AddCredits(totalReturned)
    end

    LogPokerPersonal({
        player = playerDisp,
        label  = shortLabel,
        bet    = ST.activeBet,
        mult   = mult,
        delta  = netDelta,
        won    = (netDelta > 0),
        isPush = (netDelta == 0),
    })

    if netDelta > 0 then
        ST.statusBannerText = string.format("|cffd8b4fe%s!|r  |cff9d4edd+%.2f Credits|r  |cff888899(%dx)|r", string.upper(label), netDelta, mult)
        ns.RecordGameOutcome("POKER", true, ST.activeBet, mult, netDelta, shortHash)
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end
    elseif netDelta == 0 then
        ST.statusBannerText = "|cffd8b4feJACKS OR BETTER (1x)|r  |cff888899— Bet Returned|r"
        ns.CheckBankrollRefill()
        ns.RefreshHub()
    else
        ST.statusBannerText = string.format("|cffe63946NO HAND|r  |cff888899(-%.2f Credits)|r", ST.activeBet)
        ns.RecordGameOutcome("POKER", false, ST.activeBet, 0, 0, shortHash)
    end

    VideoPoker:Refresh()
end

-- ============================================================================
-- Module Interface Methods
-- ============================================================================
function VideoPoker:IsBusy()
    return ST.state == "PLAYER_HOLD"
end

function VideoPoker:Refresh()
    local db = ns.db
    if not UI.PokerFrame or not db then return end
    db.pokerPersonalLog = db.pokerPersonalLog or {}

    local isIdle = (ST.state ~= "PLAYER_HOLD")
    SetButtonEnabled(UI.MainBtn, true)
    if UI.MainBtnText then
        if ST.state == "PLAYER_HOLD" then
            UI.MainBtnText:SetText("Draw")
        elseif ST.state == "RESULT" then
            UI.MainBtnText:SetText("Deal Again")
        else
            UI.MainBtnText:SetText("Deal")
        end
    end

    SetButtonEnabled(UI.BtnHalf, isIdle)
    SetButtonEnabled(UI.Btn2x, isIdle)
    SetButtonEnabled(UI.BtnMax, isIdle)
    if UI.BetInput then
        if isIdle then
            UI.BetInput:Enable()
        else
            UI.BetInput:ClearFocus()
            UI.BetInput:Disable()
        end
    end

    if UI.StatusText then
        UI.StatusText:SetText(ST.statusBannerText)
    end

    -- Left Sidebar Recent Video Poker Hands (formatted with ns.FormatPlayerName)
    local fallbackPlayer = ns.FormatPlayerName(ns.GetMyFormattedName())
    for i = 1, CFG.NUM_HISTORY_ROWS do
        local row   = UI.PersonalRows[i]
        local entry = db.pokerPersonalLog[i]
        if row then
            if entry then
                row:Show()
                local playerDisp = ns.FormatPlayerName(entry.player or fallbackPlayer)
                row.left:SetText(string.format("%s |cff888899%s|r", playerDisp, entry.label))
                if entry.isPush then
                    row.bgTex:SetColorTexture(0.14, 0.14, 0.20, 0.85)
                    row.right:SetText("|cff8888991x PUSH|r")
                elseif entry.won then
                    row.bgTex:SetColorTexture(unpack(COLORS.purpleDim))
                    row.right:SetText(string.format("|cffd8b4fe+%.2f|r", entry.delta))
                else
                    row.bgTex:SetColorTexture(unpack(COLORS.crashRedDim))
                    row.right:SetText(string.format("|cffe63946%.2f|r", entry.delta))
                end
            else
                row:Hide()
            end
        end
    end

    UpdatePaytableVisuals()
    UpdateCardRow()
end

function VideoPoker:OnShow()
    EnsureDeck()
    if ST.currentRoundHash ~= "" then
        ns.SetHashText("Hand SHA-Seed: " .. string.sub(ST.currentRoundHash, 1, 24) .. "...")
    else
        ns.SetHashText("Video Poker — 9/6 Jacks or Better | 52-Card Deck")
    end
    VideoPoker:Refresh()
end

function VideoPoker:OnHide()
    -- Protected by IsBusy(); no unfinished active hold leaves the stage
end

function VideoPoker:Build(parent)
    UI.PokerFrame = CreateFrame("Frame", "VoidCasinoVideoPokerFrame", parent)
    UI.PokerFrame:SetAllPoints()

    -- 1. Left Controls Panel (230 x 340)
    local LeftPanel = CreateFrame("Frame", nil, UI.PokerFrame)
    LeftPanel:SetPoint("TOPLEFT", 0, 0)
    LeftPanel:SetSize(230, 340)
    ns.StyleBox(LeftPanel, COLORS.bgPanel, COLORS.border)

    UI.MainBtn = ns.CreateCustomButton(LeftPanel, 206, 42, "Deal", true)
    UI.MainBtn:SetPoint("TOP", 0, -12)
    UI.MainBtnText = UI.MainBtn.label
    UI.MainBtn:SetScript("OnClick", function()
        if ST.state == "PLAYER_HOLD" then
            DrawCards()
        else
            DealNewHand()
        end
    end)

    local BetLbl = LeftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    BetLbl:SetPoint("TOPLEFT", 12, -62)
    BetLbl:SetText("Bet Amount")
    BetLbl:SetTextColor(unpack(COLORS.textMuted))

    local BetBox = CreateFrame("Frame", nil, LeftPanel)
    BetBox:SetSize(206, 30)
    BetBox:SetPoint("TOPLEFT", 12, -76)
    ns.StyleBox(BetBox, COLORS.bgInput, COLORS.border)

    UI.BetInput = CreateFrame("EditBox", nil, BetBox)
    UI.BetInput:SetSize(96, 26)
    UI.BetInput:SetPoint("LEFT", 8, 0)
    UI.BetInput:SetFontObject("GameFontHighlight")
    UI.BetInput:SetAutoFocus(false)
    UI.BetInput:SetText("50")
    UI.BetInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    UI.BetInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    UI.BetInput:SetScript("OnTextChanged", function() UpdatePaytableVisuals() end)

    UI.BtnMax = ns.CreateCustomButton(BetBox, 36, 24, "Max", false)
    UI.BtnMax:SetPoint("RIGHT", -3, 0)
    UI.BtnMax:SetScript("OnClick", function()
        ns.CheckBankrollRefill()
        local bal = (ns.db and ns.db.credits) or 0
        UI.BetInput:SetText(string.format("%.2f", math.max(0, bal)))
        UpdatePaytableVisuals()
    end)

    UI.Btn2x = ns.CreateCustomButton(BetBox, 32, 24, "2x", false)
    UI.Btn2x:SetPoint("RIGHT", UI.BtnMax, "LEFT", -3, 0)
    UI.Btn2x:SetScript("OnClick", function()
        local cur     = tonumber(UI.BetInput:GetText()) or 0
        local bal     = (ns.db and ns.db.credits) or 0
        local nextVal = math.min(bal, cur * 2)
        if bal >= 1 then
            nextVal = math.max(1, nextVal)
        else
            nextVal = math.max(0, math.floor(nextVal * 100 + 1e-6) / 100)
        end
        UI.BetInput:SetText(string.format("%.2f", nextVal))
        UpdatePaytableVisuals()
    end)

    UI.BtnHalf = ns.CreateCustomButton(BetBox, 32, 24, "1/2", false)
    UI.BtnHalf:SetPoint("RIGHT", UI.Btn2x, "LEFT", -3, 0)
    UI.BtnHalf:SetScript("OnClick", function()
        local cur     = tonumber(UI.BetInput:GetText()) or 0
        local bal     = (ns.db and ns.db.credits) or 0
        local nextVal = math.floor((cur / 2) * 100 + 1e-6) / 100
        if bal >= 1 then
            nextVal = math.max(1, nextVal)
        elseif bal > 0 then
            nextVal = math.max(0.01, math.min(bal, nextVal))
        else
            nextVal = 0
        end
        UI.BetInput:SetText(string.format("%.2f", nextVal))
        UpdatePaytableVisuals()
    end)

    -- Rules Summary Box
    local RulesBox = CreateFrame("Frame", nil, LeftPanel)
    RulesBox:SetSize(206, 46)
    RulesBox:SetPoint("TOPLEFT", 12, -114)
    ns.StyleBox(RulesBox, COLORS.bgInput, COLORS.border)

    local RulesLine1 = RulesBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    RulesLine1:SetPoint("TOP", 0, -8)
    RulesLine1:SetText("|cffd8b4fe9/6 Jacks or Better|r")

    local RulesLine2 = RulesBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    RulesLine2:SetPoint("BOTTOM", 0, 8)
    RulesLine2:SetTextColor(unpack(COLORS.textMuted))
    RulesLine2:SetText("52-Card Deck • Click cards to Hold")

    -- Recent Hands History
    local HistLbl = LeftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    HistLbl:SetPoint("TOPLEFT", 12, -170)
    HistLbl:SetText("Recent Hands")
    HistLbl:SetTextColor(unpack(COLORS.textMuted))

    for i = 1, CFG.NUM_HISTORY_ROWS do
        local row = CreateFrame("Frame", nil, LeftPanel)
        row:SetSize(206, 24)
        row:SetPoint("TOPLEFT", 12, -188 - (i - 1) * 28)
        ns.StyleBox(row, COLORS.purpleDim, nil)

        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.right:SetPoint("RIGHT", -6, 0)
        row.right:SetJustifyH("RIGHT")

        row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.left:SetPoint("LEFT", 6, 0)
        row.left:SetPoint("RIGHT", row.right, "LEFT", -4, 0)
        row.left:SetJustifyH("LEFT")
        row.left:SetWordWrap(false)

        row:Hide()
        UI.PersonalRows[i] = row
    end

    -- 2. Right Video Poker Stage Panel (554 x 340)
    local RightPanel = CreateFrame("Frame", nil, UI.PokerFrame)
    RightPanel:SetPoint("TOPLEFT", LeftPanel, "TOPRIGHT", 12, 0)
    RightPanel:SetPoint("TOPRIGHT", 0, 0)
    RightPanel:SetHeight(340)
    ns.StyleBox(RightPanel, COLORS.bgPanel, COLORS.border)

    local TableFrame = CreateFrame("Frame", nil, RightPanel)
    TableFrame:SetPoint("TOPLEFT", 8, -8)
    TableFrame:SetPoint("BOTTOMRIGHT", -8, 8)
    ns.StyleBox(TableFrame, COLORS.bgInput, COLORS.border)

    -- 3x3 Live Paytable (518 x 96 inside 538px TableFrame)
    local PaytableFrame = CreateFrame("Frame", nil, TableFrame)
    PaytableFrame:SetPoint("TOPLEFT", 10, -10)
    PaytableFrame:SetPoint("TOPRIGHT", -10, -10)
    PaytableFrame:SetHeight(96)
    ns.StyleBox(PaytableFrame, COLORS.bgMain, COLORS.border)

    local cellW = 166
    local cellH = 26
    for idx, tier in ipairs(CFG.PAYTABLE) do
        local colIdx = math.floor((idx - 1) / 3) -- 0..2
        local rowIdx = (idx - 1) % 3            -- 0..2
        local cell = CreateFrame("Frame", nil, PaytableFrame)
        cell:SetSize(cellW, cellH)
        cell:SetPoint("TOPLEFT", 5 + colIdx * (cellW + 5), -5 - rowIdx * (cellH + 4))
        ns.StyleBox(cell, COLORS.bgInput, COLORS.border)

        cell.payText = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell.payText:SetPoint("RIGHT", -6, 0)
        cell.payText:SetJustifyH("RIGHT")

        cell.nameText = cell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cell.nameText:SetPoint("LEFT", 6, 0)
        cell.nameText:SetPoint("RIGHT", cell.payText, "LEFT", -4, 0)
        cell.nameText:SetJustifyH("LEFT")
        cell.nameText:SetWordWrap(false)
        cell.nameText:SetText(tier.label)

        UI.PaytableCells[tier.id] = cell
    end

    UI.StatusText = TableFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    UI.StatusText:SetPoint("TOP", 0, -115)
    UI.StatusText:SetText(ST.statusBannerText)

    -- 5 Reusable Card Frames (Cards.lua) & Aligned Hold Buttons
    local startX = 21
    local stepX  = CFG.CARD_W + CFG.CARD_GAP
    for i = 1, CFG.NUM_CARDS do
        local idx = i
        local cx  = startX + (idx - 1) * stepX

        local cf = Cards.CreateCardFrame(TableFrame, CFG.CARD_W, CFG.CARD_H)
        cf:SetPoint("TOPLEFT", cx, -142)
        cf:SetOnClick(function() ToggleHold(idx) end)
        UI.CardFrames[idx] = cf

        local hBtn = ns.CreateCustomButton(TableFrame, CFG.CARD_W, 26, "HOLD", false)
        hBtn:SetPoint("TOPLEFT", cx, -282)
        hBtn.label:SetFontObject("GameFontHighlightSmall")
        hBtn:SetScript("OnClick", function() ToggleHold(idx) end)
        UI.HoldButtons[idx] = hBtn
    end

    EnsureDeck()
    UpdatePaytableVisuals()
    UpdateCardRow()

    return UI.PokerFrame
end

ns.RegisterGame("POKER", VideoPoker)
