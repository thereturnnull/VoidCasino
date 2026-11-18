-- ============================================================================
-- VoidCasino - Cards.lua
-- Universal Deck/Shoe Engine & Reusable Card Renderer (Assets\Suits.tga)
-- Shared across Blackjack, Video Poker, and any future card-based modules
-- ============================================================================

local ADDON_NAME, ns = ...
local COLORS = ns.COLORS

local Cards = {}
ns.Cards = Cards

-- Sprite Sheet Path (WoW resolves .tga automatically)
Cards.SUIT_TEXTURE = "Interface\\AddOns\\VoidCasino\\Assets\\Suits"

-- 2x2 Quadrant TexCoords with 0.005 edge inset to prevent bilinear bleeding
Cards.SUIT_COORDS = {
    S = { 0.005, 0.495, 0.005, 0.495 }, -- Top-Left: Spade
    H = { 0.505, 0.995, 0.005, 0.495 }, -- Top-Right: Heart
    D = { 0.005, 0.495, 0.505, 0.995 }, -- Bottom-Left: Diamond
    C = { 0.505, 0.995, 0.505, 0.995 }, -- Bottom-Right: Club
}

-- Rank Text Colors matched to Suits.tga gradients
Cards.SUIT_COLORS = {
    S = { 0.86, 0.72, 1.00, 1.00 }, -- Void Lavender
    C = { 0.86, 0.72, 1.00, 1.00 }, -- Void Lavender
    H = { 0.98, 0.36, 0.44, 1.00 }, -- Neon Crimson
    D = { 0.98, 0.36, 0.44, 1.00 }, -- Neon Crimson
}

Cards.CARD_STYLE = {
    faceBg       = { 0.07, 0.07, 0.10, 1.00 },
    faceBorder   = { 0.24, 0.22, 0.34, 1.00 },
    backBg       = { 0.13, 0.06, 0.22, 1.00 },
    backInnerBg  = { 0.09, 0.04, 0.16, 1.00 },
    backBorder   = { 0.48, 0.17, 0.75, 1.00 },
    heldBorder   = { 0.68, 0.39, 0.93, 1.00 },
    winBorder    = { 0.86, 0.72, 1.00, 1.00 },
    lossBorder   = { 0.92, 0.24, 0.32, 1.00 },
}

Cards.RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
Cards.SUITS = { "S", "H", "D", "C" }

-- ============================================================================
-- Card Value & Hand Helpers
-- ============================================================================
function Cards.GetRankValue(rank, aceHigh)
    if rank == "A" then return aceHigh and 14 or 1 end
    if rank == "K" then return 13 end
    if rank == "Q" then return 12 end
    if rank == "J" then return 11 end
    return tonumber(rank) or 0
end

function Cards.GetBlackjackValue(rank)
    if rank == "A" then return 11 end
    if rank == "K" or rank == "Q" or rank == "J" then return 10 end
    return tonumber(rank) or 0
end

-- Returns: total, isSoft, isBlackjack, isBust
function Cards.EvaluateBlackjackHand(hand)
    local total = 0
    local aces = 0
    for i = 1, #hand do
        local r = hand[i].rank
        if r == "A" then
            total = total + 11
            aces = aces + 1
        else
            total = total + Cards.GetBlackjackValue(r)
        end
    end
    while total > 21 and aces > 0 do
        total = total - 10
        aces = aces - 1
    end
    local isSoft = (aces > 0)
    local isBlackjack = (#hand == 2 and total == 21)
    local isBust = (total > 21)
    return total, isSoft, isBlackjack, isBust
end

-- ============================================================================
-- Deck / Multi-Deck Shoe Object
-- ============================================================================
function Cards.NewDeck(numDecks)
    local deck = {
        numDecks = math.max(1, numDecks or 1),
        cards = {},
        index = 1,
    }

    function deck:Build()
        self.cards = {}
        for _ = 1, self.numDecks do
            for _, suit in ipairs(Cards.SUITS) do
                for _, rank in ipairs(Cards.RANKS) do
                    table.insert(self.cards, { rank = rank, suit = suit })
                end
            end
        end
        self.index = 1
    end

    function deck:Shuffle()
        if #self.cards == 0 then self:Build() end
        -- Fisher-Yates shuffle using VoidCasino's shared PRNG
        for i = #self.cards, 2, -1 do
            local j = math.floor(ns.NextRandomFloat() * i) + 1
            self.cards[i], self.cards[j] = self.cards[j], self.cards[i]
        end
        self.index = 1
    end

    function deck:Remaining()
        return math.max(0, #self.cards - self.index + 1)
    end

    function deck:NeedsReshuffle(minRemainingRatio)
        local total = self.numDecks * 52
        local threshold = math.floor(total * (minRemainingRatio or 0.25))
        return self:Remaining() <= threshold
    end

    function deck:Draw()
        if self.index > #self.cards then
            self:Shuffle()
        end
        local card = self.cards[self.index]
        self.index = self.index + 1
        return card
    end

    deck:Build()
    deck:Shuffle()
    return deck
end

-- ============================================================================
-- Reusable Card Frame Factory
-- ============================================================================
function Cards.CreateCardFrame(parent, width, height)
    local w = width or 74
    local h = height or 106

    local card = CreateFrame("Button", nil, parent)
    card:SetSize(w, h)
    ns.StyleBox(card, Cards.CARD_STYLE.faceBg, Cards.CARD_STYLE.faceBorder)

    card.rank = nil
    card.suit = nil
    card.isFaceDown = false
    card.isHeld = false
    card.highlightMode = "NONE"

    -- Face Container
    local face = CreateFrame("Frame", nil, card)
    face:SetAllPoints()
    card.face = face

    -- Top-Left Rank Label
    local rankTop = face:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    rankTop:SetPoint("TOPLEFT", 6, -5)
    local fontPath, _, fontFlags = rankTop:GetFont()
    if fontPath then
        local rankSize = math.max(12, math.floor(w * 0.22))
        rankTop:SetFont(fontPath, rankSize, fontFlags)
    end
    card.rankTop = rankTop

    -- Top-Right Mini Suit Pip
    local miniSize = math.max(12, math.floor(w * 0.22))
    local miniSuit = face:CreateTexture(nil, "ARTWORK")
    miniSuit:SetSize(miniSize, miniSize)
    miniSuit:SetPoint("TOPRIGHT", -6, -6)
    miniSuit:SetTexture(Cards.SUIT_TEXTURE)
    card.miniSuit = miniSuit

    -- Center Large Suit Pip
    local centerSize = math.max(26, math.floor(w * 0.54))
    local centerSuit = face:CreateTexture(nil, "ARTWORK")
    centerSuit:SetSize(centerSize, centerSize)
    centerSuit:SetPoint("CENTER", 0, -4)
    centerSuit:SetTexture(Cards.SUIT_TEXTURE)
    card.centerSuit = centerSuit

    -- Bottom-Right Rank Label
    local rankBot = face:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rankBot:SetPoint("BOTTOMRIGHT", -6, 5)
    card.rankBot = rankBot

    -- Back Container (Void Geometric Card Back)
    local back = CreateFrame("Frame", nil, card)
    back:SetAllPoints()
    back:Hide()
    card.back = back

    local backInner = CreateFrame("Frame", nil, back)
    backInner:SetPoint("TOPLEFT", 5, -5)
    backInner:SetPoint("BOTTOMRIGHT", -5, 5)
    ns.StyleBox(backInner, Cards.CARD_STYLE.backInnerBg, Cards.CARD_STYLE.backBorder)

    local backEmblem = backInner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    backEmblem:SetPoint("CENTER", 0, 0)
    backEmblem:SetText("|cff9d4eddVOID|r")

    -- "HELD" Pill Badge (used by Video Poker & future hold/discard games)
    local heldBadge = CreateFrame("Frame", nil, card)
    heldBadge:SetPoint("BOTTOMLEFT", 4, 4)
    heldBadge:SetPoint("BOTTOMRIGHT", -4, 4)
    heldBadge:SetHeight(16)
    heldBadge:SetFrameLevel(card:GetFrameLevel() + 5)
    ns.StyleBox(heldBadge, COLORS.purpleBtn, COLORS.purpleBright)
    heldBadge:Hide()

    local heldText = heldBadge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    heldText:SetPoint("CENTER", 0, 0)
    heldText:SetText("HELD")
    card.heldBadge = heldBadge

    -- Internal border/style refresh
    local function ApplyVisualState()
        if card.isFaceDown then
            card.face:Hide()
            card.back:Show()
            card.heldBadge:Hide()
            ns.StyleBox(card, Cards.CARD_STYLE.backBg, Cards.CARD_STYLE.backBorder)
            return
        end

        card.back:Hide()
        card.face:Show()

        local borderCol = Cards.CARD_STYLE.faceBorder
        if card.highlightMode == "WIN" then
            borderCol = Cards.CARD_STYLE.winBorder
        elseif card.highlightMode == "LOSS" then
            borderCol = Cards.CARD_STYLE.lossBorder
        elseif card.isHeld or card.highlightMode == "HELD" then
            borderCol = Cards.CARD_STYLE.heldBorder
        end

        ns.StyleBox(card, Cards.CARD_STYLE.faceBg, borderCol)
        if card.isHeld then
            card.heldBadge:Show()
        else
            card.heldBadge:Hide()
        end
    end

    -- Public Methods
    function card:SetCard(rankOrTable, optionalSuit)
        local r, s
        if type(rankOrTable) == "table" then
            r = rankOrTable.rank
            s = rankOrTable.suit
        else
            r = rankOrTable
            s = optionalSuit
        end
        if not r or not s then return end

        self.rank = tostring(r)
        self.suit = string.upper(tostring(s))
        self.isFaceDown = false

        local coords = Cards.SUIT_COORDS[self.suit] or Cards.SUIT_COORDS.S
        local col    = Cards.SUIT_COLORS[self.suit] or Cards.SUIT_COLORS.S

        self.rankTop:SetText(self.rank)
        self.rankTop:SetTextColor(col[1], col[2], col[3], 1)

        self.rankBot:SetText(self.rank)
        self.rankBot:SetTextColor(col[1], col[2], col[3], 0.85)

        self.miniSuit:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        self.miniSuit:SetVertexColor(1, 1, 1, 1)

        self.centerSuit:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        self.centerSuit:SetVertexColor(1, 1, 1, 1)

        self:SetAlpha(1)
        ApplyVisualState()
        self:Show()
    end

    function card:SetFaceDown(isDown)
        self.isFaceDown = isDown and true or false
        ApplyVisualState()
        self:Show()
    end

    function card:SetHeld(isHeld)
        self.isHeld = isHeld and true or false
        ApplyVisualState()
    end

    function card:SetHighlight(mode)
        self.highlightMode = mode or "NONE"
        ApplyVisualState()
    end

    function card:SetDimmed(isDimmed)
        self:SetAlpha(isDimmed and 0.45 or 1.0)
    end

    function card:Clear()
        self.rank = nil
        self.suit = nil
        self.isFaceDown = false
        self.isHeld = false
        self.highlightMode = "NONE"
        self:SetAlpha(1)
        self:Hide()
    end

    function card:SetOnClick(callback)
        self:SetScript("OnClick", callback)
    end

    card:Hide()
    return card
end