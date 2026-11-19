-- ============================================================================
-- VoidCasino - Games/HiLo.lua
-- 0-100 Slider Hi-Lo | Roll Over / Roll Under | 1% House Edge | Instant Roll
-- ============================================================================

local ADDON_NAME, ns = ...
local COLORS = ns.COLORS

local HiLo = {}

-- Constants (grouped into CFG to stay well under Lua 5.1's 60-upvalue limit)
local CFG = {
    HOUSE_EDGE_PCT     = 1,
    MIN_TARGET         = 2,
    MAX_TARGET         = 98,
    NUM_TICKER_PILLS   = 11,
    NUM_HISTORY_ROWS   = 5,
    TRACK_W            = 478,
    TRACK_INNER_W      = 476,
    TRACK_H            = 18,
    ROLL_ANIM_DURATION = 0.80,
    MIN_SCRUB_DIST     = 180,
    IDEAL_SCRUB_DIST   = 250,

    WIN_ZONE_COLOR  = COLORS.purpleBtn,
    LOSS_ZONE_COLOR = { 0.55, 0.13, 0.19, 0.85 },
    PRESETS         = { 10, 25, 50, 75 },
    SCALE_TICKS     = { 0, 25, 50, 75, 100 },
}

-- Runtime State (grouped into ST)
local ST = {
    state              = "IDLE", -- "IDLE" or "ROLLING"
    targetValue        = 50,
    rollMode           = "OVER", -- "OVER" or "UNDER"
    instantRollEnabled = false,
    pendingRoll        = nil,
    lastRoll           = nil,
    lastWon            = nil,
    lastTarget         = nil,
    lastMode           = nil,
    currentRoundHash   = "",
    statusBannerText   = "|cff888899Adjust the slider and click Roll|r",
    isDragging         = false,

    -- Scrubbing Animation State (non-spoiler until landing when Instant Roll is off)
    animTimer        = 0,
    scrubStartU      = 50,
    scrubEndU        = 50,
    markerDisplayVal = 50,
}

-- UI References (grouped into UI)
local UI = {
    HiLoFrame      = nil,
    RollBtn        = nil,
    RollBtnText    = nil,
    BetInput       = nil,
    BtnHalf        = nil,
    Btn2x          = nil,
    BtnMax         = nil,
    InstantSwitch  = nil,
    ModeUnderBtn   = nil,
    ModeOverBtn    = nil,
    MinusBtn       = nil,
    PlusBtn        = nil,
    BigRollText    = nil,
    SubStatusText  = nil,
    TrackBar       = nil,
    TrackInner     = nil,
    LeftZoneTex    = nil,
    RightZoneTex   = nil,
    ThumbFrame     = nil,
    ResultMarker   = nil,
    ResultLine     = nil,
    ResultStem     = nil,
    ResultPill     = nil,
    ResultPillText = nil,
    TargetValText  = nil,
    TargetSubText  = nil,
    WinChanceText  = nil,
    MultText       = nil,
    ProfitText     = nil,
    TickerPills    = {},
    PersonalRows   = {},
    PresetButtons  = {},
}

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
            if dist >= CFG.MIN_SCRUB_DIST then
                local diff = math.abs(dist - CFG.IDEAL_SCRUB_DIST)
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
    if rounded < CFG.MIN_TARGET then return CFG.MIN_TARGET end
    if rounded > CFG.MAX_TARGET then return CFG.MAX_TARGET end
    return rounded
end

local function GetWinChance(tgt, mode)
    if mode == "OVER" then
        return 100 - tgt
    end
    return tgt
end

local function GetMultiplier(winChance)
    local rtpNumerator = (100 - CFG.HOUSE_EDGE_PCT) * 100 -- 9900 for 1% house edge
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
    if not UI.ResultMarker or not UI.TrackInner then return end
    local clamped = math.max(0, math.min(100, rollPos))
    local xPos = (clamped / 100) * CFG.TRACK_INNER_W
    UI.ResultMarker:ClearAllPoints()
    UI.ResultMarker:SetPoint("CENTER", UI.TrackInner, "LEFT", xPos, 0)
end

local function UpdateModeButtons()
    if not UI.ModeUnderBtn or not UI.ModeOverBtn then return end
    local underActive = (ST.rollMode == "UNDER")
    local overActive  = (ST.rollMode == "OVER")

    UI.ModeUnderBtn.isPrimary = underActive
    UI.ModeUnderBtn.customCol = underActive and COLORS.purpleBtn or COLORS.bgPanel
    ns.StyleBox(UI.ModeUnderBtn, UI.ModeUnderBtn.customCol, underActive and COLORS.purpleBright or COLORS.border)

    UI.ModeOverBtn.isPrimary = overActive
    UI.ModeOverBtn.customCol = overActive and COLORS.purpleBtn or COLORS.bgPanel
    ns.StyleBox(UI.ModeOverBtn, UI.ModeOverBtn.customCol, overActive and COLORS.purpleBright or COLORS.border)
end

local function UpdateSliderVisuals()
    if not UI.TrackInner then return end
    local frac = ST.targetValue / 100
    local splitX = frac * CFG.TRACK_INNER_W

    UI.LeftZoneTex:SetWidth(math.max(1, splitX))
    UI.RightZoneTex:SetWidth(math.max(1, CFG.TRACK_INNER_W - splitX))

    if ST.rollMode == "OVER" then
        UI.LeftZoneTex:SetColorTexture(unpack(CFG.LOSS_ZONE_COLOR))
        UI.RightZoneTex:SetColorTexture(unpack(CFG.WIN_ZONE_COLOR))
    else
        UI.LeftZoneTex:SetColorTexture(unpack(CFG.WIN_ZONE_COLOR))
        UI.RightZoneTex:SetColorTexture(unpack(CFG.LOSS_ZONE_COLOR))
    end

    UI.ThumbFrame:ClearAllPoints()
    UI.ThumbFrame:SetPoint("CENTER", UI.TrackInner, "LEFT", splitX, 0)
end

local function UpdateMetrics()
    local winChance = GetWinChance(ST.targetValue, ST.rollMode)
    local mult      = GetMultiplier(winChance)
    local betAmt    = tonumber(UI.BetInput and UI.BetInput:GetText()) or 0
    if betAmt < 0 then betAmt = 0 end
    local profit    = ComputeProfitOnWin(betAmt, mult)

    if UI.TargetSubText then
        UI.TargetSubText:SetText(ST.rollMode == "OVER" and "ROLL OVER" or "ROLL UNDER")
    end
    if UI.TargetValText then
        UI.TargetValText:SetText(tostring(ST.targetValue))
    end
    if UI.WinChanceText then
        UI.WinChanceText:SetText(string.format("%.2f%%", winChance))
    end
    if UI.MultText then
        UI.MultText:SetText(string.format("%.2fx", mult))
    end
    if UI.ProfitText then
        UI.ProfitText:SetText(string.format("+%.2f", profit))
    end
    if UI.RollBtnText then
        if ST.state == "ROLLING" then
            UI.RollBtnText:SetText("Rolling...")
        else
            UI.RollBtnText:SetText(string.format("Roll %s %d", ST.rollMode == "OVER" and "Over" or "Under", ST.targetValue))
        end
    end

    for i = 1, #CFG.PRESETS do
        local pBtn = UI.PresetButtons[i]
        if pBtn then
            local active = (winChance == CFG.PRESETS[i])
            pBtn.isPrimary = active
            pBtn.customCol = active and COLORS.purpleBtn or COLORS.bgInput
            ns.StyleBox(pBtn, pBtn.customCol, active and COLORS.purpleBright or COLORS.border)
        end
    end
end

local function ApplyMarkerColors(isWin)
    if isWin then
        UI.BigRollText:SetTextColor(0.86, 0.72, 1.00, 1.00)
        if UI.ResultMarker then
            UI.ResultLine:SetColorTexture(0.86, 0.72, 1.00, 1.00)
            UI.ResultStem:SetColorTexture(0.86, 0.72, 1.00, 1.00)
            ns.StyleBox(UI.ResultPill, COLORS.purpleBtn, COLORS.textLight)
            UI.ResultPillText:SetTextColor(1, 1, 1, 1)
        end
    else
        UI.BigRollText:SetTextColor(unpack(COLORS.crashRed))
        if UI.ResultMarker then
            UI.ResultLine:SetColorTexture(unpack(COLORS.crashRed))
            UI.ResultStem:SetColorTexture(unpack(COLORS.crashRed))
            ns.StyleBox(UI.ResultPill, COLORS.crashRedDim, COLORS.crashRed)
            UI.ResultPillText:SetTextColor(1, 0.85, 0.88, 1)
        end
    end
end

local function RenderScrubFrame(posVal, tgt, mode)
    if not UI.BigRollText then return end
    local shownVal = math.floor(math.max(0, math.min(100, posVal)) * 100 + 0.5) / 100
    local isWinningPos = (mode == "UNDER") and (shownVal < tgt) or (shownVal > tgt)

    UI.BigRollText:SetText(string.format("%.2f", shownVal))
    ApplyMarkerColors(isWinningPos)

    if UI.ResultMarker then
        UI.ResultMarker:Show()
        UI.ResultPillText:SetText(string.format("%.2f", shownVal))
        PositionResultMarker(posVal)
    end
end

local function UpdateResultDisplay()
    if not UI.BigRollText or not UI.SubStatusText then return end
    if ST.state == "ROLLING" and ST.pendingRoll then
        UI.SubStatusText:SetText("|cff9d4eddROLLING...|r")
        RenderScrubFrame(ST.markerDisplayVal, ST.pendingRoll.target, ST.pendingRoll.mode)
        return
    end

    UI.SubStatusText:SetText(ST.statusBannerText)

    if ST.lastRoll == nil then
        UI.BigRollText:SetTextColor(unpack(COLORS.textMuted))
        UI.BigRollText:SetText("--.--")
        if UI.ResultMarker then UI.ResultMarker:Hide() end
        return
    end

    UI.BigRollText:SetText(string.format("%.2f", ST.lastRoll))
    ApplyMarkerColors(ST.lastWon)

    if UI.ResultMarker then
        UI.ResultMarker:Show()
        UI.ResultPillText:SetText(string.format("%.2f", ST.lastRoll))
        PositionResultMarker(ST.lastRoll)
    end
end

local function SetTargetValue(newTarget)
    if ST.state == "ROLLING" then return end
    ST.targetValue = ClampTarget(newTarget)
    UpdateSliderVisuals()
    UpdateMetrics()
end

local function SetRollMode(newMode)
    if ST.state == "ROLLING" then return end
    if newMode ~= "OVER" and newMode ~= "UNDER" then return end
    if ST.rollMode == newMode then return end
    ST.rollMode = newMode
    UpdateModeButtons()
    UpdateSliderVisuals()
    UpdateMetrics()
end

local function UpdateTargetFromCursor()
    if not UI.TrackInner then return end
    local left  = UI.TrackInner:GetLeft()
    local width = UI.TrackInner:GetWidth()
    if not left or not width or width <= 0 then return end
    local scale   = UI.TrackInner:GetEffectiveScale() or 1
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
    ST.state            = "IDLE"
    ST.pendingRoll      = nil
    ST.lastRoll         = data.roll
    ST.lastWon          = data.won
    ST.lastTarget       = data.target
    ST.lastMode         = data.mode
    ST.markerDisplayVal = data.roll
    ST.currentRoundHash = data.hash

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

        ST.statusBannerText = string.format("|cffd8b4feWIN!|r  |cff9d4edd+%.2f Credits|r  |cff888899(%.2fx)|r", netProfit, data.mult)
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
        ST.statusBannerText = string.format("|cffe63946MISS|r  |cff888899(-%.2f • Needed %s %d)|r", data.bet, opSym, data.target)
        ns.RecordGameOutcome("HILO", false, data.bet, data.mult, 0, data.shortHash)
    end

    HiLo:Refresh()
end

local function ExecuteRoll()
    if ST.state == "ROLLING" or not UI.BetInput then return end
    UI.BetInput:ClearFocus()
    ST.isDragging = false

    local ok, actualBet = ns.DeductCredits(UI.BetInput:GetText())
    if not ok then
        if ns.db and (ns.db.credits or 0) >= 0.01 then
            ST.statusBannerText = "|cffe63946Enter a valid bet amount|r"
            UI.SubStatusText:SetText(ST.statusBannerText)
        end
        return
    end
    UI.BetInput:SetText(string.format("%.2f", actualBet))

    local winChance = GetWinChance(ST.targetValue, ST.rollMode)
    local mult      = GetMultiplier(winChance)

    -- Uniform 10,000-outcome roll matching exact winChance / 100 probability
    local raw = math.floor(ns.NextRandomFloat() * 10000)
    local roll, won
    if ST.rollMode == "UNDER" then
        roll = raw / 100 -- 0.00 .. 99.99
        won  = (roll < ST.targetValue)
    else
        roll = (raw + 1) / 100 -- 0.01 .. 100.00
        won  = (roll > ST.targetValue)
    end

    local roundHash = ns.GenerateRoundHash(roll * 100 + actualBet)
    local rollData = {
        roll      = roll,
        won       = won,
        target    = ST.targetValue,
        mode      = ST.rollMode,
        bet       = actualBet,
        mult      = mult,
        hash      = roundHash,
        shortHash = string.sub(roundHash, 1, 16),
        player    = ns.FormatPlayerName(ns.GetMyFormattedName()),
    }

    if ST.instantRollEnabled then
        -- Bypass deferred reveal and settle immediately
        SettleRoll(rollData)
        return
    end

    ST.state            = "ROLLING"
    ST.pendingRoll      = rollData
    ST.scrubStartU      = (ST.lastRoll ~= nil) and ST.lastRoll or ST.targetValue
    ST.scrubEndU        = ComputeScrubEndU(ST.scrubStartU, roll)
    ST.markerDisplayVal = ST.scrubStartU
    ST.animTimer        = 0

    ns.SetHashText("Roll SHA-Seed: Rolling...")
    ns.RefreshHub()
end

local function OnUpdateTick(self, elapsed)
    if ST.isDragging and ST.state ~= "ROLLING" then
        if IsMouseButtonDown("LeftButton") then
            UpdateTargetFromCursor()
        else
            ST.isDragging = false
        end
    end

    if ST.state == "ROLLING" and ST.pendingRoll then
        ST.animTimer = ST.animTimer + elapsed
        local t = ST.animTimer / CFG.ROLL_ANIM_DURATION
        if t >= 1 then
            SettleRoll(ST.pendingRoll)
        else
            -- Smooth cubic ease-out deceleration across sweeps onto final roll
            local inv   = 1 - t
            local eased = 1 - (inv * inv * inv)
            ST.markerDisplayVal = FoldTo0100(ST.scrubStartU + (ST.scrubEndU - ST.scrubStartU) * eased)
            RenderScrubFrame(ST.markerDisplayVal, ST.pendingRoll.target, ST.pendingRoll.mode)
        end
    end
end

-- ============================================================================
-- Module Interface Methods
-- ============================================================================
function HiLo:IsBusy()
    return ST.state == "ROLLING"
end

function HiLo:Refresh()
    local db = ns.db
    if not UI.HiLoFrame or not db then return end
    db.hiloHistory     = db.hiloHistory or {}
    db.hiloPersonalLog = db.hiloPersonalLog or {}

    local isIdle = (ST.state ~= "ROLLING")
    SetButtonEnabled(UI.RollBtn, isIdle)
    SetButtonEnabled(UI.BtnHalf, isIdle)
    SetButtonEnabled(UI.Btn2x, isIdle)
    SetButtonEnabled(UI.BtnMax, isIdle)
    SetButtonEnabled(UI.ModeUnderBtn, isIdle)
    SetButtonEnabled(UI.ModeOverBtn, isIdle)
    SetButtonEnabled(UI.MinusBtn, isIdle)
    SetButtonEnabled(UI.PlusBtn, isIdle)
    for i = 1, #CFG.PRESETS do
        SetButtonEnabled(UI.PresetButtons[i], isIdle)
    end
    if UI.BetInput then
        if isIdle then
            UI.BetInput:Enable()
        else
            UI.BetInput:ClearFocus()
            UI.BetInput:Disable()
        end
    end

    -- Top Ticker Pills
    for i = 1, CFG.NUM_TICKER_PILLS do
        local pill = UI.TickerPills[i]
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
    for i = 1, CFG.NUM_HISTORY_ROWS do
        local row   = UI.PersonalRows[i]
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
    if ST.state == "ROLLING" then
        ns.SetHashText("Roll SHA-Seed: Rolling...")
    elseif ST.currentRoundHash ~= "" then
        ns.SetHashText("Roll SHA-Seed: " .. string.sub(ST.currentRoundHash, 1, 24) .. "...")
    else
        ns.SetHashText("Hi-Lo — 0-100 Slider | 1% House Edge")
    end
    HiLo:Refresh()
end

function HiLo:OnHide()
    ST.isDragging = false
    if ST.state == "ROLLING" and ST.pendingRoll then
        SettleRoll(ST.pendingRoll)
    end
end

function HiLo:Build(parent)
    UI.HiLoFrame = CreateFrame("Frame", "VoidCasinoHiLoFrame", parent)
    UI.HiLoFrame:SetAllPoints()

    -- 1. Left Controls Panel (230 x 340)
    local LeftPanel = CreateFrame("Frame", nil, UI.HiLoFrame)
    LeftPanel:SetPoint("TOPLEFT", 0, 0)
    LeftPanel:SetSize(230, 340)
    ns.StyleBox(LeftPanel, COLORS.bgPanel, COLORS.border)

    UI.RollBtn = ns.CreateCustomButton(LeftPanel, 206, 42, "Roll Over 50", true)
    UI.RollBtn:SetPoint("TOP", 0, -12)
    UI.RollBtnText = UI.RollBtn.label
    UI.RollBtn:SetScript("OnClick", ExecuteRoll)

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
    UI.BetInput:SetText("100")
    UI.BetInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    UI.BetInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    UI.BetInput:SetScript("OnTextChanged", function() UpdateMetrics() end)

    UI.BtnMax = ns.CreateCustomButton(BetBox, 36, 24, "Max", false)
    UI.BtnMax:SetPoint("RIGHT", -3, 0)
    UI.BtnMax:SetScript("OnClick", function()
        ns.CheckBankrollRefill()
        local bal = (ns.db and ns.db.credits) or 0
        UI.BetInput:SetText(string.format("%.2f", math.max(0, bal)))
        UpdateMetrics()
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
        UpdateMetrics()
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
        UpdateMetrics()
    end)

    -- Quick Win-Chance Presets
    local PresetBar = CreateFrame("Frame", nil, LeftPanel)
    PresetBar:SetSize(206, 24)
    PresetBar:SetPoint("TOPLEFT", 12, -114)

    for i = 1, #CFG.PRESETS do
        local pct = CFG.PRESETS[i]
        local pBtn = ns.CreateCustomButton(PresetBar, 48, 22, pct .. "%", false)
        pBtn.label:SetFontObject("GameFontHighlightSmall")
        pBtn:SetPoint("LEFT", (i - 1) * 52 + 1, 0)
        pBtn:SetScript("OnClick", function()
            local newTgt = (ST.rollMode == "OVER") and (100 - pct) or pct
            SetTargetValue(newTgt)
        end)
        UI.PresetButtons[i] = pBtn
    end

    -- Instant Roll Toggle (bypasses scrubbing animation & deferred reveal)
    local instantContainer
    instantContainer, UI.InstantSwitch = ns.CreateToggleSwitch(LeftPanel, "Instant Roll", function(val)
        ST.instantRollEnabled = val
        if val and ST.state == "ROLLING" and ST.pendingRoll then
            SettleRoll(ST.pendingRoll)
        end
    end)
    instantContainer:SetPoint("TOPLEFT", 12, -142)

    local HistLbl = LeftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    HistLbl:SetPoint("TOPLEFT", 12, -174)
    HistLbl:SetText("Recent Rolls")
    HistLbl:SetTextColor(unpack(COLORS.textMuted))

    for i = 1, CFG.NUM_HISTORY_ROWS do
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
        UI.PersonalRows[i] = row
    end

    -- 2. Right Slider & Stage Panel (554 x 340)
    local RightPanel = CreateFrame("Frame", nil, UI.HiLoFrame)
    RightPanel:SetPoint("TOPLEFT", LeftPanel, "TOPRIGHT", 12, 0)
    RightPanel:SetPoint("TOPRIGHT", 0, 0)
    RightPanel:SetHeight(340)
    ns.StyleBox(RightPanel, COLORS.bgPanel, COLORS.border)

    local TickerBar = CreateFrame("Frame", nil, RightPanel)
    TickerBar:SetPoint("TOPLEFT", 8, -8)
    TickerBar:SetPoint("TOPRIGHT", -8, -8)
    TickerBar:SetHeight(22)
    TickerBar:SetClipsChildren(true)

    for i = 1, CFG.NUM_TICKER_PILLS do
        local pill = CreateFrame("Frame", nil, TickerBar)
        pill:SetSize(44, 20)
        pill:SetPoint("LEFT", (i - 1) * 48, 0)
        ns.StyleBox(pill, COLORS.bgInput, nil)
        pill.text = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pill.text:SetPoint("CENTER")
        pill:Hide()
        UI.TickerPills[i] = pill
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

    UI.ModeUnderBtn = ns.CreateCustomButton(ModeBar, 124, 26, "Roll Under", false)
    UI.ModeUnderBtn:SetPoint("LEFT", 0, 0)
    UI.ModeUnderBtn:SetScript("OnClick", function() SetRollMode("UNDER") end)

    UI.ModeOverBtn = ns.CreateCustomButton(ModeBar, 124, 26, "Roll Over", true)
    UI.ModeOverBtn:SetPoint("RIGHT", 0, 0)
    UI.ModeOverBtn:SetScript("OnClick", function() SetRollMode("OVER") end)

    -- Center Roll Result Readout
    UI.BigRollText = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    UI.BigRollText:SetPoint("TOP", 0, -48)
    local fontPath, _, fontFlags = UI.BigRollText:GetFont()
    if fontPath then
        UI.BigRollText:SetFont(fontPath, 42, fontFlags)
    end
    UI.BigRollText:SetText("--.--")

    UI.SubStatusText = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    UI.SubStatusText:SetPoint("TOP", UI.BigRollText, "BOTTOM", 0, -4)
    UI.SubStatusText:SetText("|cff888899Adjust the slider and click Roll|r")

    -- Interactive 0-100 Slider Track
    UI.TrackBar = CreateFrame("Frame", nil, StageFrame)
    UI.TrackBar:SetSize(CFG.TRACK_W, CFG.TRACK_H)
    UI.TrackBar:SetPoint("TOP", 0, -148)
    ns.StyleBox(UI.TrackBar, COLORS.bgMain, COLORS.border)

    UI.TrackInner = CreateFrame("Frame", nil, UI.TrackBar)
    UI.TrackInner:SetPoint("TOPLEFT", 1, -1)
    UI.TrackInner:SetPoint("BOTTOMRIGHT", -1, 1)

    UI.LeftZoneTex = UI.TrackInner:CreateTexture(nil, "ARTWORK")
    UI.LeftZoneTex:SetPoint("TOPLEFT", 0, 0)
    UI.LeftZoneTex:SetPoint("BOTTOMLEFT", 0, 0)

    UI.RightZoneTex = UI.TrackInner:CreateTexture(nil, "ARTWORK")
    UI.RightZoneTex:SetPoint("TOPRIGHT", 0, 0)
    UI.RightZoneTex:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Floating Last-Roll Pointer Marker
    UI.ResultMarker = CreateFrame("Frame", nil, UI.TrackBar)
    UI.ResultMarker:SetSize(4, CFG.TRACK_H + 2)
    UI.ResultMarker:SetFrameLevel(UI.TrackBar:GetFrameLevel() + 2)
    UI.ResultMarker:Hide()

    UI.ResultLine = UI.ResultMarker:CreateTexture(nil, "OVERLAY")
    UI.ResultLine:SetSize(3, CFG.TRACK_H + 2)
    UI.ResultLine:SetPoint("CENTER", 0, 0)

    UI.ResultStem = UI.ResultMarker:CreateTexture(nil, "OVERLAY")
    UI.ResultStem:SetSize(2, 6)
    UI.ResultStem:SetPoint("BOTTOM", UI.ResultLine, "TOP", 0, 0)

    UI.ResultPill = CreateFrame("Frame", nil, UI.ResultMarker)
    UI.ResultPill:SetSize(48, 18)
    UI.ResultPill:SetPoint("BOTTOM", UI.ResultStem, "TOP", 0, 0)
    ns.StyleBox(UI.ResultPill, COLORS.purpleBtn, COLORS.textLight)

    UI.ResultPillText = UI.ResultPill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    UI.ResultPillText:SetPoint("CENTER", 0, 0)

    -- Draggable Target Handle Thumb
    UI.ThumbFrame = CreateFrame("Frame", nil, UI.TrackBar)
    UI.ThumbFrame:SetSize(16, 28)
    UI.ThumbFrame:SetFrameLevel(UI.TrackBar:GetFrameLevel() + 4)
    ns.StyleBox(UI.ThumbFrame, COLORS.purpleBright, COLORS.textLight)

    local ThumbGrip = UI.ThumbFrame:CreateTexture(nil, "ARTWORK")
    ThumbGrip:SetSize(2, 14)
    ThumbGrip:SetPoint("CENTER", 0, 0)
    ThumbGrip:SetColorTexture(1, 1, 1, 0.9)

    -- Mouse Drag & Wheel Hit Area
    local SliderHitArea = CreateFrame("Frame", nil, StageFrame)
    SliderHitArea:SetSize(CFG.TRACK_W + 16, 36)
    SliderHitArea:SetPoint("CENTER", UI.TrackBar, "CENTER", 0, 0)
    SliderHitArea:SetFrameLevel(UI.TrackBar:GetFrameLevel() + 6)
    SliderHitArea:EnableMouse(true)
    SliderHitArea:EnableMouseWheel(true)

    SliderHitArea:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and ST.state ~= "ROLLING" then
            ST.isDragging = true
            UpdateTargetFromCursor()
        end
    end)

    SliderHitArea:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            ST.isDragging = false
        end
    end)

    SliderHitArea:SetScript("OnHide", function()
        ST.isDragging = false
    end)

    SliderHitArea:SetScript("OnMouseWheel", function(self, delta)
        if ST.state ~= "ROLLING" then
            SetTargetValue(ST.targetValue + (delta > 0 and 1 or -1))
        end
    end)

    -- Scale Labels (0, 25, 50, 75, 100)
    for _, tick in ipairs(CFG.SCALE_TICKS) do
        local lbl = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOP", UI.TrackInner, "BOTTOMLEFT", (tick / 100) * CFG.TRACK_INNER_W, -10)
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
    targetCard, UI.TargetSubText, UI.TargetValText = CreateStatCard(1, "ROLL OVER")

    UI.MinusBtn = ns.CreateCustomButton(targetCard, 20, 20, "-", false)
    UI.MinusBtn:SetPoint("BOTTOMLEFT", 6, 8)
    UI.MinusBtn:SetScript("OnClick", function() SetTargetValue(ST.targetValue - 1) end)

    UI.PlusBtn = ns.CreateCustomButton(targetCard, 20, 20, "+", false)
    UI.PlusBtn:SetPoint("BOTTOMRIGHT", -6, 8)
    UI.PlusBtn:SetScript("OnClick", function() SetTargetValue(ST.targetValue + 1) end)

    local _, _, wcVal = CreateStatCard(2, "WIN CHANCE")
    UI.WinChanceText = wcVal

    local _, _, mVal = CreateStatCard(3, "MULTIPLIER")
    UI.MultText = mVal
    UI.MultText:SetTextColor(0.86, 0.72, 1.00, 1.00)

    local _, _, pVal = CreateStatCard(4, "PROFIT ON WIN")
    UI.ProfitText = pVal
    UI.ProfitText:SetTextColor(unpack(COLORS.purpleBright))

    UI.HiLoFrame:SetScript("OnUpdate", OnUpdateTick)
    UI.HiLoFrame:SetScript("OnHide", function() HiLo:OnHide() end)
    UpdateModeButtons()
    UpdateSliderVisuals()
    UpdateMetrics()
    UpdateResultDisplay()

    return UI.HiLoFrame
end

ns.RegisterGame("HILO", HiLo)
