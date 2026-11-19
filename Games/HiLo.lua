-- ============================================================================
-- VoidCasino - Games/HiLo.lua
-- 0-100 Slider Hi-Lo | Roll Over / Roll Under | 1% House Edge | Instant Roll
-- ============================================================================

local ADDON_NAME, ns = ...
local COLORS = ns.COLORS

local HiLo = {}

-- Constants
local HOUSE_EDGE_PCT      = 1
local MIN_TARGET          = 2
local MAX_TARGET          = 98
local NUM_TICKER_PILLS    = 11
local NUM_HISTORY_ROWS    = 5
local TRACK_W             = 478
local TRACK_INNER_W       = 476
local TRACK_H             = 18
local ROLL_ANIM_DURATION  = 0.80
local MIN_SCRUB_DIST      = 180
local IDEAL_SCRUB_DIST    = 250

local WIN_ZONE_COLOR  = COLORS.purpleBtn
local LOSS_ZONE_COLOR = { 0.55, 0.13, 0.19, 0.85 }
local PRESETS         = { 10, 25, 50, 75 }
local SCALE_TICKS     = { 0, 25, 50, 75, 100 }

-- Runtime State
local HiLoFrame
local state              = "IDLE" -- "IDLE" or "ROLLING"
local targetValue        = 50
local rollMode           = "OVER" -- "OVER" or "UNDER"
local instantRollEnabled = false
local pendingRoll        = nil
local lastRoll           = nil
local lastWon            = nil
local lastTarget         = nil
local lastMode           = nil
local currentRoundHash   = ""
local statusBannerText   = "|cff888899Adjust the slider and click Roll|r"
local isDragging         = false

-- Scrubbing Animation State (non-spoiler until landing when Instant Roll is off)
local animTimer        = 0
local scrubStartU      = 50
local scrubEndU        = 50
local markerDisplayVal = 50

-- UI References
local RollBtn, RollBtnText
local BetInput, BtnHalf, Btn2x, BtnMax, InstantSwitch
local ModeUnderBtn, ModeOverBtn, MinusBtn, PlusBtn
local BigRollText, SubStatusText
local TrackBar, TrackInner, LeftZoneTex, RightZoneTex, ThumbFrame
local ResultMarker, ResultLine, ResultStem, ResultPill, ResultPillText
local TargetValText, TargetSubText, WinChanceText, MultText, ProfitText
local TickerPills   = {}
local PersonalRows  = {}
local PresetButtons = {}

-- ============================================================================
-- Math & Probability Helpers
-- ============================================================================
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

local function FoldTo0100(u)
    local m = u % 200
    if m < 0 then m = m + 200 end
    if m > 100 then return 200 - m end
    return m
end

local function ComputeScrubEndU(startPos, finalRoll)
    local bestCand = 200 + finalRoll
    local bestDiff = math.huge
    for k = 1, 3 do
        local c1 = 200 * k + finalRoll
        local c2 = 200 * k - finalRoll
        for _, cand in ipairs({ c1, c2 }) do
            local dist = cand - startPos
            if dist >= MIN_SCRUB_DIST then
                local diff = math.abs(dist - IDEAL_SCRUB_DIST)
                if diff < bestDiff then
                    bestDiff = diff
                    bestCand = cand
                end
            end
        end
    end
    return bestCand
end
local function ClampTarget(val)
    local rounded = math.floor((tonumber(val) or 50) + 0.5)
    if rounded < MIN_TARGET then return MIN_TARGET end
    if rounded > MAX_TARGET then return MAX_TARGET end
    return rounded
end

local function GetWinChance(tgt, mode)
    if mode == "OVER" then
        return 100 - tgt
    end
    return tgt
end

local function GetMultiplier(winChance)
    local rtpNumerator = (100 - HOUSE_EDGE_PCT) * 100 -- 9900 for 1% house edge
    return math.floor((rtpNumerator / winChance) + 1e-9) / 100
end

local function ComputeProfitOnWin(betAmt, mult)
    if betAmt <= 0 then return 0 end
    local payout = math.floor(betAmt * mult * 100 + 1e-6) / 100
    return math.max(0, math.floor((payout - betAmt) * 100 + 0.5) / 100)
end

local function LogHiLoPersonal(entry)
    local db = ns.db
    if not db then return end
    db.hiloPersonalLog = db.hiloPersonalLog or {}
    table.insert(db.hiloPersonalLog, 1, entry)
    while #db.hiloPersonalLog > 15 do
        table.remove(db.hiloPersonalLog)
    end
end

local function LogHiLoTicker(rollVal, won)
    local db = ns.db
    if not db then return end
    db.hiloHistory = db.hiloHistory or {}
    table.insert(db.hiloHistory, 1, {
        roll = rollVal,
        won  = won,
    })
    while #db.hiloHistory > 15 do
        table.remove(db.hiloHistory)
    end
end

-- ============================================================================
-- Visual Updates & Interactive Slider Controls
-- ============================================================================
local function PositionResultMarker(rollPos)
    if not ResultMarker or not TrackInner then return end
    local clamped = math.max(0, math.min(100, rollPos))
    local xPos = (clamped / 100) * TRACK_INNER_W
    ResultMarker:ClearAllPoints()
    ResultMarker:SetPoint("CENTER", TrackInner, "LEFT", xPos, 0)
end

local function UpdateModeButtons()
    if not ModeUnderBtn or not ModeOverBtn then return end
    local underActive = (rollMode == "UNDER")
    local overActive  = (rollMode == "OVER")

    ModeUnderBtn.isPrimary = underActive
    ModeUnderBtn.customCol = underActive and COLORS.purpleBtn or COLORS.bgPanel
    ns.StyleBox(ModeUnderBtn, ModeUnderBtn.customCol, underActive and COLORS.purpleBright or COLORS.border)

    ModeOverBtn.isPrimary = overActive
    ModeOverBtn.customCol = overActive and COLORS.purpleBtn or COLORS.bgPanel
    ns.StyleBox(ModeOverBtn, ModeOverBtn.customCol, overActive and COLORS.purpleBright or COLORS.border)
end

local function UpdateSliderVisuals()
    if not TrackInner then return end
    local frac = targetValue / 100
    local splitX = frac * TRACK_INNER_W

    LeftZoneTex:SetWidth(math.max(1, splitX))
    RightZoneTex:SetWidth(math.max(1, TRACK_INNER_W - splitX))

    if rollMode == "OVER" then
        LeftZoneTex:SetColorTexture(unpack(LOSS_ZONE_COLOR))
        RightZoneTex:SetColorTexture(unpack(WIN_ZONE_COLOR))
    else
        LeftZoneTex:SetColorTexture(unpack(WIN_ZONE_COLOR))
        RightZoneTex:SetColorTexture(unpack(LOSS_ZONE_COLOR))
    end

    ThumbFrame:ClearAllPoints()
    ThumbFrame:SetPoint("CENTER", TrackInner, "LEFT", splitX, 0)
end

local function UpdateMetrics()
    local winChance = GetWinChance(targetValue, rollMode)
    local mult      = GetMultiplier(winChance)
    local betAmt    = tonumber(BetInput and BetInput:GetText()) or 0
    if betAmt < 0 then betAmt = 0 end
    local profit    = ComputeProfitOnWin(betAmt, mult)

    if TargetSubText then
        TargetSubText:SetText(rollMode == "OVER" and "ROLL OVER" or "ROLL UNDER")
    end
    if TargetValText then
        TargetValText:SetText(tostring(targetValue))
    end
    if WinChanceText then
        WinChanceText:SetText(string.format("%.2f%%", winChance))
    end
    if MultText then
        MultText:SetText(string.format("%.2fx", mult))
    end
    if ProfitText then
        ProfitText:SetText(string.format("+%.2f", profit))
    end
    if RollBtnText then
        if state == "ROLLING" then
            RollBtnText:SetText("Rolling...")
        else
            RollBtnText:SetText(string.format("Roll %s %d", rollMode == "OVER" and "Over" or "Under", targetValue))
        end
    end

    for i = 1, #PRESETS do
        local pBtn = PresetButtons[i]
        if pBtn then
            local active = (winChance == PRESETS[i])
            pBtn.isPrimary = active
            pBtn.customCol = active and COLORS.purpleBtn or COLORS.bgInput
            ns.StyleBox(pBtn, pBtn.customCol, active and COLORS.purpleBright or COLORS.border)
        end
    end
end

local function ApplyMarkerColors(isWin)
    if isWin then
        BigRollText:SetTextColor(0.86, 0.72, 1.00, 1.00)
        if ResultMarker then
            ResultLine:SetColorTexture(0.86, 0.72, 1.00, 1.00)
            ResultStem:SetColorTexture(0.86, 0.72, 1.00, 1.00)
            ns.StyleBox(ResultPill, COLORS.purpleBtn, COLORS.textLight)
            ResultPillText:SetTextColor(1, 1, 1, 1)
        end
    else
        BigRollText:SetTextColor(unpack(COLORS.crashRed))
        if ResultMarker then
            ResultLine:SetColorTexture(unpack(COLORS.crashRed))
            ResultStem:SetColorTexture(unpack(COLORS.crashRed))
            ns.StyleBox(ResultPill, COLORS.crashRedDim, COLORS.crashRed)
            ResultPillText:SetTextColor(1, 0.85, 0.88, 1)
        end
    end
end

local function RenderScrubFrame(posVal, tgt, mode)
    if not BigRollText then return end
    local shownVal = math.floor(math.max(0, math.min(100, posVal)) * 100 + 0.5) / 100
    local isWinningPos = (mode == "UNDER") and (shownVal < tgt) or (shownVal > tgt)

    BigRollText:SetText(string.format("%.2f", shownVal))
    ApplyMarkerColors(isWinningPos)

    if ResultMarker then
        ResultMarker:Show()
        ResultPillText:SetText(string.format("%.2f", shownVal))
        PositionResultMarker(posVal)
    end
end

local function UpdateResultDisplay()
    if not BigRollText or not SubStatusText then return end
    if state == "ROLLING" and pendingRoll then
        SubStatusText:SetText("|cff9d4eddROLLING...|r")
        RenderScrubFrame(markerDisplayVal, pendingRoll.target, pendingRoll.mode)
        return
    end

    SubStatusText:SetText(statusBannerText)

    if lastRoll == nil then
        BigRollText:SetTextColor(unpack(COLORS.textMuted))
        BigRollText:SetText("--.--")
        if ResultMarker then ResultMarker:Hide() end
        return
    end

    BigRollText:SetText(string.format("%.2f", lastRoll))
    ApplyMarkerColors(lastWon)

    if ResultMarker then
        ResultMarker:Show()
        ResultPillText:SetText(string.format("%.2f", lastRoll))
        PositionResultMarker(lastRoll)
    end
end

local function SetTargetValue(newTarget)
    if state == "ROLLING" then return end
    targetValue = ClampTarget(newTarget)
    UpdateSliderVisuals()
    UpdateMetrics()
end

local function SetRollMode(newMode)
    if state == "ROLLING" then return end
    if newMode ~= "OVER" and newMode ~= "UNDER" then return end
    if rollMode == newMode then return end
    rollMode = newMode
    UpdateModeButtons()
    UpdateSliderVisuals()
    UpdateMetrics()
end

local function UpdateTargetFromCursor()
    if not TrackInner then return end
    local left  = TrackInner:GetLeft()
    local width = TrackInner:GetWidth()
    if not left or not width or width <= 0 then return end
    local scale   = TrackInner:GetEffectiveScale() or 1
    local cursorX = GetCursorPosition() / scale
    local rel     = (cursorX - left) / width
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    SetTargetValue(rel * 100)
end

-- ============================================================================
-- Roll Settlement & Execution (Deferred Scrub Reveal vs. Instant Roll)
-- ============================================================================
local function SettleRoll(data)
    if not data then return end
    state            = "IDLE"
    pendingRoll      = nil
    lastRoll         = data.roll
    lastWon          = data.won
    lastTarget       = data.target
    lastMode         = data.mode
    markerDisplayVal = data.roll
    currentRoundHash = data.hash

    ns.SetHashText("Roll SHA-Seed: " .. string.sub(data.hash, 1, 24) .. "...")

    if data.won then
        local payout    = math.floor(data.bet * data.mult * 100 + 1e-6) / 100
        local netProfit = math.floor((payout - data.bet) * 100 + 0.5) / 100
        ns.AddCredits(payout)

        LogHiLoPersonal({
            player = data.player,
            roll   = data.roll,
            target = data.target,
            mode   = data.mode,
            bet    = data.bet,
            mult   = data.mult,
            profit = netProfit,
            won    = true,
        })
        LogHiLoTicker(data.roll, true)

        statusBannerText = string.format("|cffd8b4feWIN!|r  |cff9d4edd+%.2f Credits|r  |cff888899(%.2fx)|r", netProfit, data.mult)
        ns.RecordGameOutcome("HILO", true, data.bet, data.mult, netProfit, data.shortHash)
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end
    else
        LogHiLoPersonal({
            player = data.player,
            roll   = data.roll,
            target = data.target,
            mode   = data.mode,
            bet    = data.bet,
            mult   = data.mult,
            profit = 0,
            won    = false,
        })
        LogHiLoTicker(data.roll, false)

        local opSym = (data.mode == "OVER") and ">" or "<"
        statusBannerText = string.format("|cffe63946MISS|r  |cff888899(-%.2f • Needed %s %d)|r", data.bet, opSym, data.target)
        ns.RecordGameOutcome("HILO", false, data.bet, data.mult, 0, data.shortHash)
    end

    HiLo:Refresh()
end

local function ExecuteRoll()
    if state == "ROLLING" or not BetInput then return end
    BetInput:ClearFocus()
    isDragging = false

    local ok, actualBet = ns.DeductCredits(BetInput:GetText())
    if not ok then
        if ns.db and (ns.db.credits or 0) >= 0.01 then
            statusBannerText = "|cffe63946Enter a valid bet amount|r"
            SubStatusText:SetText(statusBannerText)
        end
        return
    end
    BetInput:SetText(string.format("%.2f", actualBet))

    local winChance = GetWinChance(targetValue, rollMode)
    local mult      = GetMultiplier(winChance)

    -- Uniform 10,000-outcome roll matching exact winChance / 100 probability
    local raw = math.floor(ns.NextRandomFloat() * 10000)
    local roll, won
    if rollMode == "UNDER" then
        roll = raw / 100 -- 0.00 .. 99.99
        won  = (roll < targetValue)
    else
        roll = (raw + 1) / 100 -- 0.01 .. 100.00
        won  = (roll > targetValue)
    end

    local roundHash = ns.GenerateRoundHash(roll * 100 + actualBet)
    local rollData = {
        roll      = roll,
        won       = won,
        target    = targetValue,
        mode      = rollMode,
        bet       = actualBet,
        mult      = mult,
        hash      = roundHash,
        shortHash = string.sub(roundHash, 1, 16),
        player    = ns.FormatPlayerName(ns.GetMyFormattedName()),
    }

    if instantRollEnabled then
        -- Bypass deferred reveal and settle immediately
        SettleRoll(rollData)
        return
    end

    state            = "ROLLING"
    pendingRoll      = rollData
    scrubStartU      = (lastRoll ~= nil) and lastRoll or targetValue
    scrubEndU        = ComputeScrubEndU(scrubStartU, roll)
    markerDisplayVal = scrubStartU
    animTimer        = 0

    ns.SetHashText("Roll SHA-Seed: Rolling...")
    ns.RefreshHub()
end

local function OnUpdateTick(self, elapsed)
    if isDragging and state ~= "ROLLING" then
        if IsMouseButtonDown("LeftButton") then
            UpdateTargetFromCursor()
        else
            isDragging = false
        end
    end

    if state == "ROLLING" and pendingRoll then
        animTimer = animTimer + elapsed
        local t = animTimer / ROLL_ANIM_DURATION
        if t >= 1 then
            SettleRoll(pendingRoll)
        else
            -- Smooth cubic ease-out deceleration across sweeps onto final roll
            local inv   = 1 - t
            local eased = 1 - (inv * inv * inv)
            markerDisplayVal = FoldTo0100(scrubStartU + (scrubEndU - scrubStartU) * eased)
            RenderScrubFrame(markerDisplayVal, pendingRoll.target, pendingRoll.mode)
        end
    end
end

-- ============================================================================
-- Module Interface Methods
-- ============================================================================
function HiLo:IsBusy()
    return state == "ROLLING"
end

function HiLo:Refresh()
    local db = ns.db
    if not HiLoFrame or not db then return end
    db.hiloHistory     = db.hiloHistory or {}
    db.hiloPersonalLog = db.hiloPersonalLog or {}

    local isIdle = (state ~= "ROLLING")
    SetButtonEnabled(RollBtn, isIdle)
    SetButtonEnabled(BtnHalf, isIdle)
    SetButtonEnabled(Btn2x, isIdle)
    SetButtonEnabled(BtnMax, isIdle)
    SetButtonEnabled(ModeUnderBtn, isIdle)
    SetButtonEnabled(ModeOverBtn, isIdle)
    SetButtonEnabled(MinusBtn, isIdle)
    SetButtonEnabled(PlusBtn, isIdle)
    for i = 1, #PRESETS do
        SetButtonEnabled(PresetButtons[i], isIdle)
    end
    if BetInput then
        if isIdle then
            BetInput:Enable()
        else
            BetInput:ClearFocus()
            BetInput:Disable()
        end
    end

    -- Top Ticker Pills
    for i = 1, NUM_TICKER_PILLS do
        local pill = TickerPills[i]
        local item = db.hiloHistory[i]
        if item then
            pill:Show()
            pill.text:SetText(string.format("%.2f", item.roll))
            if item.won then
                pill.bgTex:SetColorTexture(unpack(COLORS.purpleBtn))
                pill.text:SetTextColor(1, 1, 1, 1)
            else
                pill.bgTex:SetColorTexture(unpack(COLORS.crashRedDim))
                pill.text:SetTextColor(0.95, 0.55, 0.60, 1)
            end
        else
            pill:Hide()
        end
    end

    -- Left Sidebar Recent Rolls History (formatted with ns.FormatPlayerName)
    local fallbackPlayer = ns.FormatPlayerName(ns.GetMyFormattedName())
    for i = 1, NUM_HISTORY_ROWS do
        local row   = PersonalRows[i]
        local entry = db.hiloPersonalLog[i]
        if entry then
            row:Show()
            local playerDisp = ns.FormatPlayerName(entry.player or fallbackPlayer)
            local sym = (entry.mode == "UNDER") and "<" or ">"
            row.left:SetText(string.format("%s |cffffffff%.2f|r |cff888899(%s%d)|r", playerDisp, entry.roll, sym, entry.target))
            if entry.won then
                row.bgTex:SetColorTexture(unpack(COLORS.purpleDim))
                row.right:SetText(string.format("|cffd8b4fe+%.2f|r", entry.profit))
            else
                row.bgTex:SetColorTexture(unpack(COLORS.crashRedDim))
                row.right:SetText(string.format("|cffe63946-%.2f|r", entry.bet))
            end
        else
            row:Hide()
        end
    end

    UpdateModeButtons()
    UpdateSliderVisuals()
    UpdateMetrics()
    UpdateResultDisplay()
end

function HiLo:OnShow()
    if state == "ROLLING" then
        ns.SetHashText("Roll SHA-Seed: Rolling...")
    elseif currentRoundHash ~= "" then
        ns.SetHashText("Roll SHA-Seed: " .. string.sub(currentRoundHash, 1, 24) .. "...")
    else
        ns.SetHashText("Hi-Lo — 0-100 Slider | 1% House Edge")
    end
    HiLo:Refresh()
end

function HiLo:OnHide()
    isDragging = false
    if state == "ROLLING" and pendingRoll then
        SettleRoll(pendingRoll)
    end
end

function HiLo:Build(parent)
    HiLoFrame = CreateFrame("Frame", "VoidCasinoHiLoFrame", parent)
    HiLoFrame:SetAllPoints()

    -- 1. Left Controls Panel (230 x 340)
    local LeftPanel = CreateFrame("Frame", nil, HiLoFrame)
    LeftPanel:SetPoint("TOPLEFT", 0, 0)
    LeftPanel:SetSize(230, 340)
    ns.StyleBox(LeftPanel, COLORS.bgPanel, COLORS.border)

    RollBtn = ns.CreateCustomButton(LeftPanel, 206, 42, "Roll Over 50", true)
    RollBtn:SetPoint("TOP", 0, -12)
    RollBtnText = RollBtn.label
    RollBtn:SetScript("OnClick", ExecuteRoll)

    local BetLbl = LeftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    BetLbl:SetPoint("TOPLEFT", 12, -62)
    BetLbl:SetText("Bet Amount")
    BetLbl:SetTextColor(unpack(COLORS.textMuted))

    local BetBox = CreateFrame("Frame", nil, LeftPanel)
    BetBox:SetSize(206, 30)
    BetBox:SetPoint("TOPLEFT", 12, -76)
    ns.StyleBox(BetBox, COLORS.bgInput, COLORS.border)

    BetInput = CreateFrame("EditBox", nil, BetBox)
    BetInput:SetSize(96, 26)
    BetInput:SetPoint("LEFT", 8, 0)
    BetInput:SetFontObject("GameFontHighlight")
    BetInput:SetAutoFocus(false)
    BetInput:SetText("100")
    BetInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    BetInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    BetInput:SetScript("OnTextChanged", function() UpdateMetrics() end)

    BtnMax = ns.CreateCustomButton(BetBox, 36, 24, "Max", false)
    BtnMax:SetPoint("RIGHT", -3, 0)
    BtnMax:SetScript("OnClick", function()
        ns.CheckBankrollRefill()
        local bal = (ns.db and ns.db.credits) or 0
        BetInput:SetText(string.format("%.2f", math.max(0, bal)))
        UpdateMetrics()
    end)

    Btn2x = ns.CreateCustomButton(BetBox, 32, 24, "2x", false)
    Btn2x:SetPoint("RIGHT", BtnMax, "LEFT", -3, 0)
    Btn2x:SetScript("OnClick", function()
        local cur     = tonumber(BetInput:GetText()) or 0
        local bal     = (ns.db and ns.db.credits) or 0
        local nextVal = math.min(bal, cur * 2)
        if bal >= 1 then
            nextVal = math.max(1, nextVal)
        else
            nextVal = math.max(0, math.floor(nextVal * 100) / 100)
        end
        BetInput:SetText(string.format("%.2f", nextVal))
        UpdateMetrics()
    end)

    BtnHalf = ns.CreateCustomButton(BetBox, 32, 24, "1/2", false)
    BtnHalf:SetPoint("RIGHT", Btn2x, "LEFT", -3, 0)
    BtnHalf:SetScript("OnClick", function()
        local cur     = tonumber(BetInput:GetText()) or 0
        local bal     = (ns.db and ns.db.credits) or 0
        local nextVal = math.floor((cur / 2) * 100) / 100
        if bal >= 1 then
            nextVal = math.max(1, nextVal)
        else
            nextVal = math.max(0.01, math.min(bal, nextVal))
        end
        BetInput:SetText(string.format("%.2f", nextVal))
        UpdateMetrics()
    end)

    -- Quick Win-Chance Presets
    local PresetBar = CreateFrame("Frame", nil, LeftPanel)
    PresetBar:SetSize(206, 24)
    PresetBar:SetPoint("TOPLEFT", 12, -114)

    for i = 1, #PRESETS do
        local pct = PRESETS[i]
        local pBtn = ns.CreateCustomButton(PresetBar, 48, 22, pct .. "%", false)
        pBtn.label:SetFontObject("GameFontHighlightSmall")
        pBtn:SetPoint("LEFT", (i - 1) * 52 + 1, 0)
        pBtn:SetScript("OnClick", function()
            local newTgt = (rollMode == "OVER") and (100 - pct) or pct
            SetTargetValue(newTgt)
        end)
        PresetButtons[i] = pBtn
    end

    -- Instant Roll Toggle (bypasses scrubbing animation & deferred reveal)
    local instantContainer
    instantContainer, InstantSwitch = ns.CreateToggleSwitch(LeftPanel, "Instant Roll", function(val)
        instantRollEnabled = val
        if val and state == "ROLLING" and pendingRoll then
            SettleRoll(pendingRoll)
        end
    end)
    instantContainer:SetPoint("TOPLEFT", 12, -142)

    local HistLbl = LeftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    HistLbl:SetPoint("TOPLEFT", 12, -174)
    HistLbl:SetText("Recent Rolls")
    HistLbl:SetTextColor(unpack(COLORS.textMuted))

    for i = 1, NUM_HISTORY_ROWS do
        local row = CreateFrame("Frame", nil, LeftPanel)
        row:SetSize(206, 24)
        row:SetPoint("TOPLEFT", 12, -192 - (i - 1) * 28)
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
        PersonalRows[i] = row
    end

    -- 2. Right Slider & Stage Panel (554 x 340)
    local RightPanel = CreateFrame("Frame", nil, HiLoFrame)
    RightPanel:SetPoint("TOPLEFT", LeftPanel, "TOPRIGHT", 12, 0)
    RightPanel:SetPoint("TOPRIGHT", 0, 0)
    RightPanel:SetHeight(340)
    ns.StyleBox(RightPanel, COLORS.bgPanel, COLORS.border)

    local TickerBar = CreateFrame("Frame", nil, RightPanel)
    TickerBar:SetPoint("TOPLEFT", 8, -8)
    TickerBar:SetPoint("TOPRIGHT", -8, -8)
    TickerBar:SetHeight(22)
    TickerBar:SetClipsChildren(true)

    for i = 1, NUM_TICKER_PILLS do
        local pill = CreateFrame("Frame", nil, TickerBar)
        pill:SetSize(44, 20)
        pill:SetPoint("LEFT", (i - 1) * 48, 0)
        ns.StyleBox(pill, COLORS.bgInput, nil)
        pill.text = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pill.text:SetPoint("CENTER")
        pill:Hide()
        TickerPills[i] = pill
    end

    local StageFrame = CreateFrame("Frame", nil, RightPanel)
    StageFrame:SetPoint("TOPLEFT", 8, -36)
    StageFrame:SetPoint("BOTTOMRIGHT", -8, 8)
    ns.StyleBox(StageFrame, COLORS.bgInput, COLORS.border)

    local RangeTag = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    RangeTag:SetPoint("TOPLEFT", 14, -15)
    RangeTag:SetTextColor(unpack(COLORS.textMuted))
    RangeTag:SetText("0 - 100")

    local EdgeTag = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    EdgeTag:SetPoint("TOPRIGHT", -14, -15)
    EdgeTag:SetTextColor(unpack(COLORS.textMuted))
    EdgeTag:SetText("1% Edge")

    -- Roll Under / Roll Over Mode Toggle
    local ModeBar = CreateFrame("Frame", nil, StageFrame)
    ModeBar:SetSize(256, 26)
    ModeBar:SetPoint("TOP", 0, -10)

    ModeUnderBtn = ns.CreateCustomButton(ModeBar, 124, 26, "Roll Under", false)
    ModeUnderBtn:SetPoint("LEFT", 0, 0)
    ModeUnderBtn:SetScript("OnClick", function() SetRollMode("UNDER") end)

    ModeOverBtn = ns.CreateCustomButton(ModeBar, 124, 26, "Roll Over", true)
    ModeOverBtn:SetPoint("RIGHT", 0, 0)
    ModeOverBtn:SetScript("OnClick", function() SetRollMode("OVER") end)

    -- Center Roll Result Readout
    BigRollText = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    BigRollText:SetPoint("TOP", 0, -48)
    local fontPath, _, fontFlags = BigRollText:GetFont()
    if fontPath then
        BigRollText:SetFont(fontPath, 42, fontFlags)
    end
    BigRollText:SetText("--.--")

    SubStatusText = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    SubStatusText:SetPoint("TOP", BigRollText, "BOTTOM", 0, -4)
    SubStatusText:SetText("|cff888899Adjust the slider and click Roll|r")

    -- Interactive 0-100 Slider Track
    TrackBar = CreateFrame("Frame", nil, StageFrame)
    TrackBar:SetSize(TRACK_W, TRACK_H)
    TrackBar:SetPoint("TOP", 0, -148)
    ns.StyleBox(TrackBar, COLORS.bgMain, COLORS.border)

    TrackInner = CreateFrame("Frame", nil, TrackBar)
    TrackInner:SetPoint("TOPLEFT", 1, -1)
    TrackInner:SetPoint("BOTTOMRIGHT", -1, 1)

    LeftZoneTex = TrackInner:CreateTexture(nil, "ARTWORK")
    LeftZoneTex:SetPoint("TOPLEFT", 0, 0)
    LeftZoneTex:SetPoint("BOTTOMLEFT", 0, 0)

    RightZoneTex = TrackInner:CreateTexture(nil, "ARTWORK")
    RightZoneTex:SetPoint("TOPRIGHT", 0, 0)
    RightZoneTex:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Floating Last-Roll Pointer Marker
    ResultMarker = CreateFrame("Frame", nil, TrackBar)
    ResultMarker:SetSize(4, TRACK_H + 2)
    ResultMarker:SetFrameLevel(TrackBar:GetFrameLevel() + 2)
    ResultMarker:Hide()

    ResultLine = ResultMarker:CreateTexture(nil, "OVERLAY")
    ResultLine:SetSize(3, TRACK_H + 2)
    ResultLine:SetPoint("CENTER", 0, 0)

    ResultStem = ResultMarker:CreateTexture(nil, "OVERLAY")
    ResultStem:SetSize(2, 6)
    ResultStem:SetPoint("BOTTOM", ResultLine, "TOP", 0, 0)

    ResultPill = CreateFrame("Frame", nil, ResultMarker)
    ResultPill:SetSize(48, 18)
    ResultPill:SetPoint("BOTTOM", ResultStem, "TOP", 0, 0)
    ns.StyleBox(ResultPill, COLORS.purpleBtn, COLORS.textLight)

    ResultPillText = ResultPill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ResultPillText:SetPoint("CENTER", 0, 0)

    -- Draggable Target Handle Thumb
    ThumbFrame = CreateFrame("Frame", nil, TrackBar)
    ThumbFrame:SetSize(16, 28)
    ThumbFrame:SetFrameLevel(TrackBar:GetFrameLevel() + 4)
    ns.StyleBox(ThumbFrame, COLORS.purpleBright, COLORS.textLight)

    local ThumbGrip = ThumbFrame:CreateTexture(nil, "ARTWORK")
    ThumbGrip:SetSize(2, 14)
    ThumbGrip:SetPoint("CENTER", 0, 0)
    ThumbGrip:SetColorTexture(1, 1, 1, 0.9)

    -- Mouse Drag & Wheel Hit Area
    local SliderHitArea = CreateFrame("Frame", nil, StageFrame)
    SliderHitArea:SetSize(TRACK_W + 16, 36)
    SliderHitArea:SetPoint("CENTER", TrackBar, "CENTER", 0, 0)
    SliderHitArea:SetFrameLevel(TrackBar:GetFrameLevel() + 6)
    SliderHitArea:EnableMouse(true)
    SliderHitArea:EnableMouseWheel(true)

    SliderHitArea:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and state ~= "ROLLING" then
            isDragging = true
            UpdateTargetFromCursor()
        end
    end)

    SliderHitArea:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            isDragging = false
        end
    end)

    SliderHitArea:SetScript("OnHide", function()
        isDragging = false
    end)

    SliderHitArea:SetScript("OnMouseWheel", function(self, delta)
        if state ~= "ROLLING" then
            SetTargetValue(targetValue + (delta > 0 and 1 or -1))
        end
    end)

    -- Scale Labels (0, 25, 50, 75, 100)
    for _, tick in ipairs(SCALE_TICKS) do
        local lbl = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOP", TrackInner, "BOTTOMLEFT", (tick / 100) * TRACK_INNER_W, -10)
        lbl:SetTextColor(unpack(COLORS.textMuted))
        lbl:SetText(tostring(tick))
    end

    -- Bottom 4 Live Stat Cards (4 x 125px + 3 x 6px = 518px inside 538px StageFrame)
    local statCardW = 125
    local statCardH = 58
    local statGap   = 6

    local function CreateStatCard(idx, headerStr)
        local card = CreateFrame("Frame", nil, StageFrame)
        card:SetSize(statCardW, statCardH)
        card:SetPoint("BOTTOMLEFT", 10 + (idx - 1) * (statCardW + statGap), 10)
        ns.StyleBox(card, COLORS.bgPanel, COLORS.border)

        local hdr = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hdr:SetPoint("TOP", 0, -8)
        hdr:SetTextColor(unpack(COLORS.textMuted))
        hdr:SetText(headerStr)

        local val = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        val:SetPoint("BOTTOM", 0, 10)
        return card, hdr, val
    end

    local targetCard
    targetCard, TargetSubText, TargetValText = CreateStatCard(1, "ROLL OVER")

    MinusBtn = ns.CreateCustomButton(targetCard, 20, 20, "-", false)
    MinusBtn:SetPoint("BOTTOMLEFT", 6, 8)
    MinusBtn:SetScript("OnClick", function() SetTargetValue(targetValue - 1) end)

    PlusBtn = ns.CreateCustomButton(targetCard, 20, 20, "+", false)
    PlusBtn:SetPoint("BOTTOMRIGHT", -6, 8)
    PlusBtn:SetScript("OnClick", function() SetTargetValue(targetValue + 1) end)

    local _, _, wcVal = CreateStatCard(2, "WIN CHANCE")
    WinChanceText = wcVal

    local _, _, mVal = CreateStatCard(3, "MULTIPLIER")
    MultText = mVal
    MultText:SetTextColor(0.86, 0.72, 1.00, 1.00)

    local _, _, pVal = CreateStatCard(4, "PROFIT ON WIN")
    ProfitText = pVal
    ProfitText:SetTextColor(unpack(COLORS.purpleBright))

    HiLoFrame:SetScript("OnUpdate", OnUpdateTick)
    HiLoFrame:SetScript("OnHide", function() HiLo:OnHide() end)
    UpdateModeButtons()
    UpdateSliderVisuals()
    UpdateMetrics()
    UpdateResultDisplay()

    return HiLoFrame
end

ns.RegisterGame("HILO", HiLo)
