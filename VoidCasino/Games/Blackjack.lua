-- ============================================================================
-- VoidCasino - Games/Blackjack.lua
-- 6-Deck Shoe | 3:2 Natural Blackjack | Dealer Stands on All 17s (S17)
-- Supports Hit, Stand, Double Down, Split & Modular Cards.lua Rendering
-- ============================================================================

local ADDON_NAME, ns = ...
local COLORS = ns.COLORS
local Cards = ns.Cards

local Blackjack = {}

-- Constants
local NUM_DECKS          = 6
local RESHUFFLE_RATIO    = 0.25
local DEALER_DRAW_DELAY  = 0.45
local MAX_CARDS_PER_HAND = 7
local CARD_W             = 64
local CARD_H             = 92

-- Runtime State
local BJFrame
local shoe
local state = "IDLE" -- "IDLE", "PLAYER_TURN", "DEALER_TURN", "RESULT"
local dealerHand = {}
local playerHands = {} -- Array of { cards = {}, bet = 0, stood = false, busted = false, doubled = false, isSplit = false, outcome = nil }
local activeHandIdx = 1
local holeCardHidden = true
local dealerTimer = 0
local currentRoundHash = ""
local statusBannerText = "|cff888899Place your bet and click Deal|r"

-- UI References
local DealBtn, BetInput, BtnHalf, Btn2x, BtnMax
local HitBtn, StandBtn, DoubleBtn, SplitBtn
local ShoeCountText, DealerValueText, StatusText
local PlayerValueText1, PlayerValueText2
local TableFrame
local DealerCardFrames = {}
local PlayerCardFrames = { {}, {} } -- [1] = main/left hand, [2] = split right hand
local PersonalRows = {}

-- ============================================================================
-- Helpers
-- ============================================================================
local function EnsureShoe()
    if not shoe then
        shoe = Cards.NewDeck(NUM_DECKS)
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

local function FormatHandValue(hand, hideHole)
    if #hand == 0 then return "" end
    if hideHole and #hand >= 1 then
        local upVal = Cards.GetBlackjackValue(hand[1].rank)
        return tostring(upVal) .. " + ?"
    end
    local total, isSoft, isBJ, isBust = Cards.EvaluateBlackjackHand(hand)
    if isBust then
        return "|cffe63946BUST (" .. total .. ")|r"
    elseif isBJ then
        return "|cffd8b4feBLACKJACK|r"
    elseif isSoft and total < 21 then
        return "Soft " .. total
    else
        return tostring(total)
    end
end

local function LogBJPersonal(betAmt, resultLabel, netDelta, isWin, isPush)
    local db = ns.db
    if not db then return end
    db.bjPersonalLog = db.bjPersonalLog or {}
    table.insert(db.bjPersonalLog, 1, {
        bet    = betAmt,
        label  = resultLabel,
        delta  = netDelta,
        won    = isWin,
        isPush = isPush,
    })
    while #db.bjPersonalLog > 15 do
        table.remove(db.bjPersonalLog)
    end
end

-- ============================================================================
-- Card Layout & Rendering
-- ============================================================================
local function LayoutCardRow(cardFrames, handCards, centerX, yOffset, maxSpanWidth, hideSecond, highlightMode)
    local count = #handCards
    for i = 1, MAX_CARDS_PER_HAND do
        local cf = cardFrames[i]
        if i <= count then
            local step = CARD_W + 8
            if count > 1 then
                local needed = CARD_W + (count - 1) * step
                if needed > maxSpanWidth then
                    step = math.floor((maxSpanWidth - CARD_W) / (count - 1))
                end
            end
            local totalW = CARD_W + (count - 1) * step
            local startX = centerX - (totalW / 2) + (CARD_W / 2)
            local xPos = startX + (i - 1) * step

            cf:ClearAllPoints()
            cf:SetPoint("CENTER", TableFrame, "BOTTOMLEFT", xPos, yOffset)
            cf:SetFrameLevel(TableFrame:GetFrameLevel() + 2 + i)

            if hideSecond and i == 2 then
                cf:SetFaceDown(true)
            else
                cf:SetCard(handCards[i])
                cf:SetHighlight(highlightMode or "NONE")
            end
        else
            cf:Clear()
        end
    end
end

local function RenderTable()
    if not TableFrame then return end
    EnsureShoe()

    local tableW = TableFrame:GetWidth()
    if tableW <= 0 then tableW = 538 end
    local midX = tableW / 2

    ShoeCountText:SetText(string.format("Shoe: %d/%d", shoe:Remaining(), NUM_DECKS * 52))
    StatusText:SetText(statusBannerText)

    -- Dealer Row (Top: spans y=186..278 inside 288px TableFrame)
    local dealerHL = "NONE"
    if state == "RESULT" then
        local _, _, _, dBust = Cards.EvaluateBlackjackHand(dealerHand)
        if dBust then dealerHL = "LOSS" end
    end
    LayoutCardRow(DealerCardFrames, dealerHand, midX, 232, tableW - 40, holeCardHidden, dealerHL)
    DealerValueText:SetText(#dealerHand > 0 and ("Dealer: " .. FormatHandValue(dealerHand, holeCardHidden)) or "Dealer")

    -- Player Rows (Bottom: spans y=38..130, labels cleanly below at y=18)
    local isSplit = (#playerHands == 2)
    if not isSplit then
        local h1 = playerHands[1]
        if h1 then
            local hl = "NONE"
            if h1.outcome == "WIN" or h1.outcome == "BJ" then hl = "WIN"
            elseif h1.outcome == "LOSS" then hl = "LOSS" end

            LayoutCardRow(PlayerCardFrames[1], h1.cards, midX, 84, tableW - 40, false, hl)
            PlayerValueText1:ClearAllPoints()
            PlayerValueText1:SetPoint("CENTER", TableFrame, "BOTTOMLEFT", midX, 18)
            PlayerValueText1:SetText(string.format("You: %s  |cff888899(C %.0f)|r", FormatHandValue(h1.cards, false), h1.bet))
            PlayerValueText1:Show()
        else
            for i = 1, MAX_CARDS_PER_HAND do PlayerCardFrames[1][i]:Clear() end
            PlayerValueText1:Hide()
        end
        for i = 1, MAX_CARDS_PER_HAND do PlayerCardFrames[2][i]:Clear() end
        PlayerValueText2:Hide()
    else
        local leftX  = tableW * 0.27
        local rightX = tableW * 0.73
        local halfSpan = (tableW * 0.46)

        for idx = 1, 2 do
            local h = playerHands[idx]
            local cx = (idx == 1) and leftX or rightX
            local lbl = (idx == 1) and PlayerValueText1 or PlayerValueText2

            local hl = "NONE"
            if state == "PLAYER_TURN" and activeHandIdx == idx then
                hl = "HELD"
            elseif h.outcome == "WIN" or h.outcome == "BJ" then
                hl = "WIN"
            elseif h.outcome == "LOSS" then
                hl = "LOSS"
            end

            LayoutCardRow(PlayerCardFrames[idx], h.cards, cx, 84, halfSpan, false, hl)
            lbl:ClearAllPoints()
            lbl:SetPoint("CENTER", TableFrame, "BOTTOMLEFT", cx, 18)
            local activeTag = (state == "PLAYER_TURN" and activeHandIdx == idx) and "|cff9d4edd>|r " or ""
            lbl:SetText(string.format("%sH%d: %s |cff888899(%.0f)|r", activeTag, idx, FormatHandValue(h.cards, false), h.bet))
            lbl:Show()
        end
    end
end

-- ============================================================================
-- Game State Transitions & Settlement
-- ============================================================================
local function SettleRound()
    state = "RESULT"
    holeCardHidden = false

    local dTotal, _, dBJ, dBust = Cards.EvaluateBlackjackHand(dealerHand)
    local totalWagered = 0
    local totalReturned = 0
    local summaryParts = {}

    for idx, hand in ipairs(playerHands) do
        totalWagered = totalWagered + hand.bet
        local pTotal, _, pNaturalBJ, pBust = Cards.EvaluateBlackjackHand(hand.cards)
        local isTrueBJ = pNaturalBJ and (not hand.isSplit)

        if pBust then
            hand.outcome = "LOSS"
            table.insert(summaryParts, "BUST")
        elseif isTrueBJ and not dBJ then
            hand.outcome = "BJ"
            local payout = math.floor(hand.bet * 2.5 * 100) / 100
            totalReturned = totalReturned + payout
            table.insert(summaryParts, "BLACKJACK")
        elseif dBJ and not isTrueBJ then
            hand.outcome = "LOSS"
            table.insert(summaryParts, "DEALER BJ")
        elseif isTrueBJ and dBJ then
            hand.outcome = "PUSH"
            totalReturned = totalReturned + hand.bet
            table.insert(summaryParts, "PUSH")
        elseif dBust or pTotal > dTotal then
            hand.outcome = "WIN"
            local payout = math.floor(hand.bet * 2.0 * 100) / 100
            totalReturned = totalReturned + payout
            table.insert(summaryParts, "WIN")
        elseif pTotal == dTotal then
            hand.outcome = "PUSH"
            totalReturned = totalReturned + hand.bet
            table.insert(summaryParts, "PUSH")
        else
            hand.outcome = "LOSS"
            table.insert(summaryParts, "LOSS")
        end
    end

    if totalReturned > 0 then
        ns.AddCredits(totalReturned)
    end

    local netDelta = math.floor((totalReturned - totalWagered) * 100 + 0.5) / 100
    local shortHash = string.sub(currentRoundHash, 1, 16)
    local labelStr = table.concat(summaryParts, " / ")

    if netDelta > 0 then
        local effMult = math.floor((totalReturned / totalWagered) * 100) / 100
        statusBannerText = string.format("|cffd8b4fe%s!|r  |cff9d4edd+%.2f Credits|r", labelStr, netDelta)
        LogBJPersonal(totalWagered, labelStr, netDelta, true, false)
        ns.RecordGameOutcome("BLACKJACK", true, totalWagered, effMult, netDelta, shortHash)
        if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
    elseif netDelta < 0 then
        local netLoss = math.abs(netDelta)
        statusBannerText = string.format("|cffe63946%s|r  |cff888899(-%.2f Credits)|r", labelStr, netLoss)
        LogBJPersonal(totalWagered, labelStr, -netLoss, false, false)
        ns.RecordGameOutcome("BLACKJACK", false, netLoss, 0, 0, shortHash)
    else
        statusBannerText = "|cffd8b4fePUSH|r  |cff888899— Bet Returned|r"
        LogBJPersonal(totalWagered, "PUSH", 0, false, true)
        ns.CheckBankrollRefill()
        ns.RefreshHub()
    end

    Blackjack:Refresh()
end

local function BeginDealerTurn()
    holeCardHidden = false

    -- If every player hand busted, dealer doesn't need to draw
    local anyAlive = false
    for _, hand in ipairs(playerHands) do
        if not hand.busted then
            anyAlive = true
            break
        end
    end

    if not anyAlive then
        SettleRound()
        return
    end

    state = "DEALER_TURN"
    dealerTimer = DEALER_DRAW_DELAY
    statusBannerText = "|cff9d4eddDEALER'S TURN...|r"
    Blackjack:Refresh()
end

local function AdvancePlayerHand()
    if activeHandIdx < #playerHands then
        activeHandIdx = activeHandIdx + 1
        local nextHand = playerHands[activeHandIdx]
        local total = Cards.EvaluateBlackjackHand(nextHand.cards)
        if total >= 21 then
            nextHand.stood = true
            BeginDealerTurn()
        else
            statusBannerText = string.format("|cffd8b4fePlaying Hand %d|r", activeHandIdx)
            Blackjack:Refresh()
        end
    else
        BeginDealerTurn()
    end
end

local function StartNewHand()
    if state == "PLAYER_TURN" or state == "DEALER_TURN" then return end
    EnsureShoe()

    local ok, actualBet = ns.DeductCredits(BetInput:GetText())
    if not ok then return end
    BetInput:SetText(string.format("%.2f", actualBet))

    if shoe:NeedsReshuffle(RESHUFFLE_RATIO) then
        shoe:Shuffle()
        DEFAULT_CHAT_FRAME:AddMessage("|cff9d4edd[VoidCasino]|r Blackjack 6-deck shoe reshuffled.")
    end

    currentRoundHash = ns.GenerateRoundHash(actualBet + shoe:Remaining())
    ns.SetHashText("Hand SHA-Seed: " .. string.sub(currentRoundHash, 1, 24) .. "...")

    dealerHand = { shoe:Draw(), shoe:Draw() }
    playerHands = {
        {
            cards   = { shoe:Draw(), shoe:Draw() },
            bet     = actualBet,
            stood   = false,
            busted  = false,
            doubled = false,
            isSplit = false,
            outcome = nil,
        }
    }
    activeHandIdx = 1
    holeCardHidden = true
    state = "PLAYER_TURN"
    statusBannerText = "|cffd8b4feYOUR TURN — Hit, Stand, Double, or Split|r"

    -- Immediate Natural Blackjack Check (Player or Dealer Peek)
    local _, _, pBJ = Cards.EvaluateBlackjackHand(playerHands[1].cards)
    local _, _, dBJ = Cards.EvaluateBlackjackHand(dealerHand)
    if pBJ or dBJ then
        SettleRound()
        return
    end

    ns.RefreshHub()
end

local function ActionHit()
    if state ~= "PLAYER_TURN" then return end
    local hand = playerHands[activeHandIdx]
    if not hand or #hand.cards >= MAX_CARDS_PER_HAND then return end

    table.insert(hand.cards, shoe:Draw())
    local total, _, _, isBust = Cards.EvaluateBlackjackHand(hand.cards)
    if isBust then
        hand.busted = true
        hand.stood = true
        AdvancePlayerHand()
    elseif total == 21 then
        hand.stood = true
        AdvancePlayerHand()
    else
        Blackjack:Refresh()
    end
end

local function ActionStand()
    if state ~= "PLAYER_TURN" then return end
    local hand = playerHands[activeHandIdx]
    if not hand then return end
    hand.stood = true
    AdvancePlayerHand()
end

local function ActionDouble()
    if state ~= "PLAYER_TURN" then return end
    local hand = playerHands[activeHandIdx]
    if not hand or #hand.cards ~= 2 then return end
    if (ns.db.credits or 0) < hand.bet then return end

    local ok, extra = ns.DeductCredits(hand.bet)
    if not ok then return end
    hand.bet = hand.bet + extra
    hand.doubled = true

    table.insert(hand.cards, shoe:Draw())
    local _, _, _, isBust = Cards.EvaluateBlackjackHand(hand.cards)
    if isBust then hand.busted = true end
    hand.stood = true

    ns.RefreshHub()
    AdvancePlayerHand()
end

local function ActionSplit()
    if state ~= "PLAYER_TURN" or #playerHands ~= 1 then return end
    local hand = playerHands[1]
    if not hand or #hand.cards ~= 2 then return end

    local v1 = Cards.GetBlackjackValue(hand.cards[1].rank)
    local v2 = Cards.GetBlackjackValue(hand.cards[2].rank)
    if v1 ~= v2 then return end
    if (ns.db.credits or 0) < hand.bet then return end

    local ok, extra = ns.DeductCredits(hand.bet)
    if not ok then return end

    local cardA = hand.cards[1]
    local cardB = hand.cards[2]

    playerHands = {
        {
            cards   = { cardA, shoe:Draw() },
            bet     = hand.bet,
            stood   = false,
            busted  = false,
            doubled = false,
            isSplit = true,
            outcome = nil,
        },
        {
            cards   = { cardB, shoe:Draw() },
            bet     = extra,
            stood   = false,
            busted  = false,
            doubled = false,
            isSplit = true,
            outcome = nil,
        },
    }
    activeHandIdx = 1
    statusBannerText = "|cffd8b4feSplit! Playing Hand 1|r"

    -- Auto-stand Hand 1 if it immediately hit 21
    local t1 = Cards.EvaluateBlackjackHand(playerHands[1].cards)
    if t1 == 21 then
        playerHands[1].stood = true
        AdvancePlayerHand()
    else
        ns.RefreshHub()
    end
end

local function OnUpdateTick(self, elapsed)
    if state ~= "DEALER_TURN" then return end
    dealerTimer = dealerTimer - elapsed
    if dealerTimer > 0 then return end

    -- S17 Rule: Dealer stands on all 17s (soft or hard)
    local dTotal = Cards.EvaluateBlackjackHand(dealerHand)
    if dTotal < 17 and #dealerHand < MAX_CARDS_PER_HAND then
        table.insert(dealerHand, shoe:Draw())
        dealerTimer = DEALER_DRAW_DELAY
        Blackjack:Refresh()
    else
        SettleRound()
    end
end

-- ============================================================================
-- Module Interface Methods
-- ============================================================================
function Blackjack:IsBusy()
    return state == "PLAYER_TURN" or state == "DEALER_TURN"
end

function Blackjack:Refresh()
    if not BJFrame or not ns.db then return end
    local db = ns.db
    db.bjPersonalLog = db.bjPersonalLog or {}

    local isIdle = (state == "IDLE" or state == "RESULT")
    local isTurn = (state == "PLAYER_TURN")
    local curHand = playerHands[activeHandIdx]

    SetButtonEnabled(DealBtn, isIdle)
    DealBtn.label:SetText(state == "RESULT" and "Deal Again" or "Deal")

    SetButtonEnabled(BtnHalf, isIdle)
    SetButtonEnabled(Btn2x, isIdle)
    SetButtonEnabled(BtnMax, isIdle)
    if isIdle then BetInput:Enable() else BetInput:Disable() end

    SetButtonEnabled(HitBtn, isTurn)
    SetButtonEnabled(StandBtn, isTurn)

    local canDouble = isTurn and curHand and #curHand.cards == 2 and (db.credits or 0) >= curHand.bet
    SetButtonEnabled(DoubleBtn, canDouble)

    local canSplit = isTurn and #playerHands == 1 and curHand and #curHand.cards == 2
        and Cards.GetBlackjackValue(curHand.cards[1].rank) == Cards.GetBlackjackValue(curHand.cards[2].rank)
        and (db.credits or 0) >= curHand.bet
    SetButtonEnabled(SplitBtn, canSplit)

    -- Left Sidebar Personal Blackjack History
    for i = 1, 4 do
        local row = PersonalRows[i]
        local entry = db.bjPersonalLog[i]
        if entry then
            row:Show()
            row.left:SetText(string.format("|cffb57edcC|r %.0f |cff888899%s|r", entry.bet, entry.label))
            if entry.isPush then
                row.bgTex:SetColorTexture(0.14, 0.14, 0.20, 0.85)
                row.right:SetText("|cff888899PUSH|r")
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

    RenderTable()
end

function Blackjack:OnShow()
    EnsureShoe()
    if currentRoundHash ~= "" then
        ns.SetHashText("Hand SHA-Seed: " .. string.sub(currentRoundHash, 1, 24) .. "...")
    else
        ns.SetHashText("Blackjack — 6-Deck Shoe | 3:2 Payout | S17")
    end
    Blackjack:Refresh()
end

function Blackjack:OnHide()
    -- Protected by IsBusy(); nothing active to cancel
end

function Blackjack:Build(parent)
    BJFrame = CreateFrame("Frame", "VoidCasinoBlackjackFrame", parent)
    BJFrame:SetAllPoints()

    -- 1. Left Controls Panel (230 x 340)
    local LeftPanel = CreateFrame("Frame", nil, BJFrame)
    LeftPanel:SetPoint("TOPLEFT", 0, 0)
    LeftPanel:SetSize(230, 340)
    ns.StyleBox(LeftPanel, COLORS.bgPanel, COLORS.border)

    DealBtn = ns.CreateCustomButton(LeftPanel, 206, 42, "Deal", true)
    DealBtn:SetPoint("TOP", 0, -12)
    DealBtn:SetScript("OnClick", StartNewHand)

    local BetLbl = LeftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    BetLbl:SetPoint("TOPLEFT", 12, -64)
    BetLbl:SetText("Bet Amount")
    BetLbl:SetTextColor(unpack(COLORS.textMuted))

    local BetBox = CreateFrame("Frame", nil, LeftPanel)
    BetBox:SetSize(206, 30)
    BetBox:SetPoint("TOPLEFT", 12, -80)
    ns.StyleBox(BetBox, COLORS.bgInput, COLORS.border)

    BetInput = CreateFrame("EditBox", nil, BetBox)
    BetInput:SetSize(96, 26)
    BetInput:SetPoint("LEFT", 8, 0)
    BetInput:SetFontObject("GameFontHighlight")
    BetInput:SetAutoFocus(false)
    BetInput:SetText("100")
    BetInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    BetInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    BtnMax = ns.CreateCustomButton(BetBox, 36, 24, "Max", false)
    BtnMax:SetPoint("RIGHT", -3, 0)
    BtnMax:SetScript("OnClick", function()
        ns.CheckBankrollRefill()
        BetInput:SetText(string.format("%.2f", math.max(0, ns.db.credits)))
    end)

    Btn2x = ns.CreateCustomButton(BetBox, 32, 24, "2x", false)
    Btn2x:SetPoint("RIGHT", BtnMax, "LEFT", -3, 0)
    Btn2x:SetScript("OnClick", function()
        local cur = tonumber(BetInput:GetText()) or 0
        local nextVal = math.min(ns.db.credits, cur * 2)
        BetInput:SetText(string.format("%.2f", math.max(1, nextVal)))
    end)

    BtnHalf = ns.CreateCustomButton(BetBox, 32, 24, "1/2", false)
    BtnHalf:SetPoint("RIGHT", Btn2x, "LEFT", -3, 0)
    BtnHalf:SetScript("OnClick", function()
        local cur = tonumber(BetInput:GetText()) or 0
        BetInput:SetText(string.format("%.2f", math.max(1, math.floor((cur / 2) * 100) / 100)))
    end)

    -- Rules Summary Box
    local RulesBox = CreateFrame("Frame", nil, LeftPanel)
    RulesBox:SetSize(206, 48)
    RulesBox:SetPoint("TOPLEFT", 12, -120)
    ns.StyleBox(RulesBox, COLORS.bgInput, COLORS.border)

    local RulesLine1 = RulesBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    RulesLine1:SetPoint("TOP", 0, -9)
    RulesLine1:SetText("|cffd8b4feBlackjack Pays 3:2|r  |cff888899• S17|r")

    local RulesLine2 = RulesBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    RulesLine2:SetPoint("BOTTOM", 0, 9)
    RulesLine2:SetTextColor(unpack(COLORS.textMuted))
    RulesLine2:SetText("6-Deck Shoe • Double & Split")

    -- Personal Blackjack History
    local HistLbl = LeftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    HistLbl:SetPoint("TOPLEFT", 12, -184)
    HistLbl:SetText("Your Blackjack History")
    HistLbl:SetTextColor(unpack(COLORS.textMuted))

    for i = 1, 4 do
        local row = CreateFrame("Frame", nil, LeftPanel)
        row:SetSize(206, 26)
        row:SetPoint("TOPLEFT", 12, -176 - (i * 30))
        ns.StyleBox(row, COLORS.purpleDim, nil)
        row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.left:SetPoint("LEFT", 8, 0)
        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.right:SetPoint("RIGHT", -8, 0)
        row:Hide()
        PersonalRows[i] = row
    end

    -- 2. Right Blackjack Table Area
    local RightPanel = CreateFrame("Frame", nil, BJFrame)
    RightPanel:SetPoint("TOPLEFT", LeftPanel, "TOPRIGHT", 12, 0)
    RightPanel:SetPoint("TOPRIGHT", 0, 0)
    RightPanel:SetHeight(340)
    ns.StyleBox(RightPanel, COLORS.bgPanel, COLORS.border)

    TableFrame = CreateFrame("Frame", nil, RightPanel)
    TableFrame:SetPoint("TOPLEFT", 8, -8)
    TableFrame:SetPoint("BOTTOMRIGHT", -8, 44)
    TableFrame:SetClipsChildren(true)
    ns.StyleBox(TableFrame, COLORS.bgInput, COLORS.border)

    -- Table Top Labels
    DealerValueText = TableFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    DealerValueText:SetPoint("TOPLEFT", 12, -10)
    DealerValueText:SetText("Dealer")

    ShoeCountText = TableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ShoeCountText:SetPoint("TOPRIGHT", -12, -11)
    ShoeCountText:SetTextColor(unpack(COLORS.textMuted))
    ShoeCountText:SetText("Shoe: 312/312")

    -- Center Status Banner (centered in the 56px gap between dealer & player rows)
    StatusText = TableFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    StatusText:SetPoint("CENTER", TableFrame, "BOTTOM", 0, 158)
    StatusText:SetText(statusBannerText)

    -- Player Hand Value Labels (anchored below player cards in RenderTable)
    PlayerValueText1 = TableFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    PlayerValueText1:Hide()

    PlayerValueText2 = TableFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    PlayerValueText2:Hide()

    -- Pre-allocate Reusable Card Frames via Cards.lua
    for i = 1, MAX_CARDS_PER_HAND do
        DealerCardFrames[i]    = Cards.CreateCardFrame(TableFrame, CARD_W, CARD_H)
        PlayerCardFrames[1][i] = Cards.CreateCardFrame(TableFrame, CARD_W, CARD_H)
        PlayerCardFrames[2][i] = Cards.CreateCardFrame(TableFrame, CARD_W, CARD_H)
    end

    -- Bottom Action Buttons Bar: Hit | Stand | Double | Split
    local ActionBar = CreateFrame("Frame", nil, RightPanel)
    ActionBar:SetPoint("BOTTOMLEFT", 8, 8)
    ActionBar:SetPoint("BOTTOMRIGHT", -8, 8)
    ActionBar:SetHeight(30)

    local btnW = 128
    local gap  = 8

    HitBtn = ns.CreateCustomButton(ActionBar, btnW, 30, "Hit", true)
    HitBtn:SetPoint("LEFT", 0, 0)
    HitBtn:SetScript("OnClick", ActionHit)

    StandBtn = ns.CreateCustomButton(ActionBar, btnW, 30, "Stand", false)
    StandBtn:SetPoint("LEFT", HitBtn, "RIGHT", gap, 0)
    StandBtn:SetScript("OnClick", ActionStand)

    DoubleBtn = ns.CreateCustomButton(ActionBar, btnW, 30, "Double", false)
    DoubleBtn:SetPoint("LEFT", StandBtn, "RIGHT", gap, 0)
    DoubleBtn:SetScript("OnClick", ActionDouble)

    SplitBtn = ns.CreateCustomButton(ActionBar, btnW, 30, "Split", false)
    SplitBtn:SetPoint("LEFT", DoubleBtn, "RIGHT", gap, 0)
    SplitBtn:SetScript("OnClick", ActionSplit)

    BJFrame:SetScript("OnUpdate", OnUpdateTick)
    return BJFrame
end

ns.RegisterGame("BLACKJACK", Blackjack)