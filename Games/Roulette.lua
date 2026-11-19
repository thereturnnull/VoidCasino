-- ============================================================================
-- VoidCasino - Games/Roulette.lua
-- European Single-Zero Roulette | Void-Purple 0 | Pop-Out Wheel & Confetti
-- ============================================================================

local ADDON_NAME, ns = ...
local COLORS = ns.COLORS

local Roulette = {}

-- Constants (grouped into CFG to stay well under Lua 5.1's 60-upvalue limit)
local CFG = {
    SPIN_DURATION    = 2.40,
    BALL_DROP_FRAC   = 0.82,
    POPOUT_FADE_TIME = 0.14,
    POCKET_STEP      = (2 * math.pi) / 37,
    NUM_TICKER_PILLS = 11,
    NUM_HISTORY_ROWS = 5,
    CHIP_PRESETS     = { 10, 25, 50, 100 },
    CONFETTI_COUNT   = 36,

    IDLE_WHEEL = {
        size           = 192,
        cx             = 96,
        cy             = 96,
        bezel          = 192,
        well           = 186,
        back           = 170,
        rInner         = 55,
        rOuter         = 84,
        rNum           = 77,
        rBallTrack     = 88,
        rBallPocket    = 63,
        wedgeThick     = 13.8,
        fretThick      = 1.2,
        hubRing        = 112,
        hubInner       = 106,
        turretIn       = 36,
        turretOut      = 51,
        numFontSize    = 8,
        centerFontSize = 30,
        ballSize       = 9,
    },

    BIG_WHEEL = {
        size           = 340,
        cx             = 170,
        cy             = 170,
        bezel          = 340,
        well           = 328,
        back           = 298,
        rInner         = 96,
        rOuter         = 148,
        rNum           = 134,
        rBallTrack     = 156,
        rBallPocket    = 111,
        wedgeThick     = 24.5,
        fretThick      = 1.6,
        hubRing        = 196,
        hubInner       = 184,
        turretIn       = 62,
        turretOut      = 88,
        numFontSize    = 11,
        centerFontSize = 44,
        ballSize       = 12,
    },

    POCKET_COLORS = {
        ZERO  = COLORS.purpleBright,
        RED   = { 0.76, 0.16, 0.24, 1.00 },
        BLACK = { 0.11, 0.11, 0.16, 1.00 },
    },

    POCKET_WIN_COLORS = {
        ZERO  = { 0.72, 0.38, 0.98, 1.00 },
        RED   = { 1.00, 0.36, 0.44, 1.00 },
        BLACK = { 0.38, 0.36, 0.50, 1.00 },
    },

    CELL_COLORS = {
        ZERO  = COLORS.purpleBtn,
        RED   = { 0.56, 0.12, 0.18, 1.00 },
        BLACK = { 0.10, 0.10, 0.14, 1.00 },
    },

    CONFETTI_COLORS = {
        { 0.62, 0.31, 0.87 }, -- Void Purple
        { 0.86, 0.72, 1.00 }, -- Lavender
        { 0.96, 0.82, 0.44 }, -- Champagne Gold
        { 0.95, 0.95, 0.98 }, -- Crisp White
        { 0.92, 0.35, 0.50 }, -- Accent Rose
    },
}

-- Authentic European Single-Zero Clockwise Wheel Order (37 Pockets)
local WHEEL_ORDER = {
    0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10,
    5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26
}

local WHEEL_INDEX = {}
for idx, num in ipairs(WHEEL_ORDER) do
    WHEEL_INDEX[num] = idx
end

local RED_SET = {
    [1]=true,  [3]=true,  [5]=true,  [7]=true,  [9]=true,
    [12]=true, [14]=true, [16]=true, [18]=true, [19]=true,
    [21]=true, [23]=true, [25]=true, [27]=true, [30]=true,
    [32]=true, [34]=true, [36]=true,
}

-- Runtime State (grouped into ST)
local ST = {
    state              = "IDLE", -- "IDLE" or "SPINNING"
    instantRollEnabled = false,
    stagedBets         = {},
    lastRoundBets      = {},
    pendingSpin        = nil,
    lastResult         = nil,
    currentRoundHash   = "",
    statusBannerText   = "|cff888899Place bets on the felt and click Spin|r",
    defaultInfoText    = "|cff888899Straight 35:1 • Doz/Col 2:1 • Even 1:1 • 0 = Void Purple|r",

    -- Wheel Animation State (ballRadiusFrac: 1.0 = outer track, 0.0 = inner pocket)
    wheelAngle     = 0,
    wheelStartA    = 0,
    wheelEndA      = 0,
    ballAngle      = math.pi * 0.5,
    ballStartA     = math.pi * 0.5,
    ballEndA       = math.pi * 0.5,
    ballRadiusFrac = 0.0,
    spinTimer      = 0,
    showWheelBall  = false,

    -- Pop-Out & Confetti Animation State
    popoutFading    = false,
    popoutFadeTimer = 0,
    confettiActive  = false,
}

-- UI References (grouped into UI)
local UI = {
    RouletteFrame      = nil,
    SpinBtn            = nil,
    SpinBtnText        = nil,
    ChipInput          = nil,
    BtnHalf            = nil,
    Btn2x              = nil,
    BtnMax             = nil,
    InstantSwitch      = nil,
    ClearBtn           = nil,
    RebetBtn           = nil,
    DoubleBetsBtn      = nil,
    SubStatusText      = nil,
    WagerSummaryText   = nil,
    HoverInfoText      = nil,
    IdleWheel          = nil,
    BigWheel           = nil,
    PopoutOverlay      = nil,
    PopoutCard         = nil,
    PopoutStatusText   = nil,
    PopoutHintText     = nil,
    PopoutBtnBar       = nil,
    PopoutSpinAgainBtn = nil,
    PopoutTableBtn     = nil,
    ConfettiLayer      = nil,
    ConfettiPool       = {},
    SpotButtons        = {},
    SpotOrder          = {},
    TickerPills        = {},
    PersonalRows       = {},
    PresetButtons      = {},
}

-- ============================================================================
-- Helpers & Roulette Payout Rules
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

local function GetNumberColor(num)
    if num == 0 then return "ZERO" end
    if RED_SET[num] then return "RED" end
    return "BLACK"
end

local function GetSpotReturnMultiplier(spotId, winNum)
    local straight = string.match(spotId, "^N(%d+)$")
    if straight then
        return (tonumber(straight) == winNum) and 36 or 0
    end

    -- All outside bets lose when 0 hits
    if winNum == 0 then return 0 end

    if spotId == "COL1" then return (winNum % 3 == 1) and 3 or 0 end
    if spotId == "COL2" then return (winNum % 3 == 2) and 3 or 0 end
    if spotId == "COL3" then return (winNum % 3 == 0) and 3 or 0 end
    if spotId == "DOZ1" then return (winNum >= 1 and winNum <= 12) and 3 or 0 end
    if spotId == "DOZ2" then return (winNum >= 13 and winNum <= 24) and 3 or 0 end
    if spotId == "DOZ3" then return (winNum >= 25 and winNum <= 36) and 3 or 0 end
    if spotId == "LOW"  then return (winNum >= 1 and winNum <= 18) and 2 or 0 end
    if spotId == "HIGH" then return (winNum >= 19 and winNum <= 36) and 2 or 0 end
    if spotId == "EVEN" then return (winNum % 2 == 0) and 2 or 0 end
    if spotId == "ODD"  then return (winNum % 2 == 1) and 2 or 0 end
    if spotId == "RED"  then return RED_SET[winNum] and 2 or 0 end
    if spotId == "BLACK" then return (not RED_SET[winNum]) and 2 or 0 end
    return 0
end

local function FormatCompactChip(amount)
    if amount >= 10000 then
        return string.format("%.0fk", amount / 1000)
    elseif amount >= 1000 then
        return string.format("%.1fk", amount / 1000)
    elseif math.abs(amount - math.floor(amount + 0.5)) < 0.005 then
        return string.format("%d", math.floor(amount + 0.5))
    end
    return string.format("%.1f", amount)
end

local function GetTotalStagedBet()
    local total = 0
    for _, amt in pairs(ST.stagedBets) do
        total = total + (amt or 0)
    end
    return math.floor(total * 100 + 0.5) / 100
end

local function CopyBetTable(src)
    local out = {}
    for k, v in pairs(src) do
        if v and v > 0 then
            out[k] = v
        end
    end
    return out
end

local function GetChipValue()
    local val = tonumber(UI.ChipInput and UI.ChipInput:GetText()) or 0
    val = math.floor(val * 100 + 1e-6) / 100
    if val < 0.01 then return 0 end
    return val
end

local function LogRoulettePersonal(entry)
    local db = ns.db
    if not db then return end
    db.roulPersonalLog = db.roulPersonalLog or {}
    table.insert(db.roulPersonalLog, 1, entry)
    while #db.roulPersonalLog > 15 do
        table.remove(db.roulPersonalLog)
    end
end

local function LogRouletteTicker(num, colorTag)
    local db = ns.db
    if not db then return end
    db.roulHistory = db.roulHistory or {}
    table.insert(db.roulHistory, 1, {
        num   = num,
        color = colorTag,
    })
    while #db.roulHistory > 15 do
        table.remove(db.roulHistory)
    end
end

-- ============================================================================
-- Pure-Code Reusable Circular Roulette Wheel Factory & Renderer
-- ============================================================================
local function CreateMaskedCircle(parent, layer, diameter, col)
    local tex = parent:CreateTexture(nil, layer)
    tex:SetSize(diameter, diameter)
    tex:SetPoint("CENTER", 0, 0)
    tex:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
    local mask = parent:CreateMaskTexture()
    mask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(tex)
    tex:AddMaskTexture(mask)
    return tex
end

local function GetPocketWorldAngle(idx, curWheelA)
    return (math.pi * 0.5) - (curWheelA + (idx - 1) * CFG.POCKET_STEP)
end

local function CreateWheelWidget(parent, cfg)
    local wheelFrame = CreateFrame("Frame", nil, parent)
    wheelFrame:SetSize(cfg.size, cfg.size)

    local baseLevel = wheelFrame:GetFrameLevel()
    CreateMaskedCircle(wheelFrame, "BACKGROUND", cfg.bezel, COLORS.border)
    CreateMaskedCircle(wheelFrame, "BORDER",     cfg.well,  COLORS.bgMain)
    CreateMaskedCircle(wheelFrame, "ARTWORK",    cfg.back,  { 0.06, 0.06, 0.09, 1.00 })

    local pocketsFrame = CreateFrame("Frame", nil, wheelFrame)
    pocketsFrame:SetAllPoints()
    pocketsFrame:SetFrameLevel(baseLevel + 1)

    local wedges = {}
    local frets  = {}
    for idx = 1, 37 do
        local wedge = pocketsFrame:CreateLine(nil, "ARTWORK")
        wedge:SetThickness(cfg.wedgeThick)
        wedges[idx] = wedge

        local fret = pocketsFrame:CreateLine(nil, "OVERLAY")
        fret:SetThickness(cfg.fretThick)
        fret:SetColorTexture(0.26, 0.25, 0.36, 0.90)
        frets[idx] = fret
    end

    local numbersFrame = CreateFrame("Frame", nil, wheelFrame)
    numbersFrame:SetAllPoints()
    numbersFrame:SetFrameLevel(baseLevel + 2)

    local labels = {}
    for idx = 1, 37 do
        local lbl = numbersFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        local lFontPath = lbl:GetFont()
        if lFontPath then
            lbl:SetFont(lFontPath, cfg.numFontSize, "")
        end
        lbl:SetShadowOffset(1, -1)
        lbl:SetShadowColor(0, 0, 0, 0.95)
        lbl:SetText(tostring(WHEEL_ORDER[idx]))
        labels[idx] = lbl
    end

    local hubFrame = CreateFrame("Frame", nil, wheelFrame)
    hubFrame:SetAllPoints()
    hubFrame:SetFrameLevel(baseLevel + 3)

    CreateMaskedCircle(hubFrame, "BACKGROUND", cfg.hubRing,  COLORS.purpleBtn)
    CreateMaskedCircle(hubFrame, "BORDER",     cfg.hubInner, COLORS.bgPanel)

    local turrets = {}
    for i = 1, 4 do
        local spoke = hubFrame:CreateLine(nil, "ARTWORK")
        spoke:SetThickness(2.0)
        spoke:SetColorTexture(0.62, 0.31, 0.87, 0.55)
        turrets[i] = spoke
    end

    local numText = hubFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    numText:SetPoint("CENTER", 0, 6)
    local fontPath, _, fontFlags = numText:GetFont()
    if fontPath then
        numText:SetFont(fontPath, cfg.centerFontSize, fontFlags)
    end

    local colorText = hubFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    colorText:SetPoint("TOP", numText, "BOTTOM", 0, -1)

    local ballFrame = CreateFrame("Frame", nil, wheelFrame)
    ballFrame:SetAllPoints()
    ballFrame:SetFrameLevel(baseLevel + 4)

    local ballTex = ballFrame:CreateTexture(nil, "OVERLAY")
    ballTex:SetSize(cfg.ballSize, cfg.ballSize)
    ballTex:SetColorTexture(0.96, 0.96, 1.00, 1.00)
    local ballMask = ballFrame:CreateMaskTexture()
    ballMask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    ballMask:SetAllPoints(ballTex)
    ballTex:AddMaskTexture(ballMask)
    ballTex:Hide()

    return {
        frame     = wheelFrame,
        cfg       = cfg,
        wedges    = wedges,
        frets     = frets,
        labels    = labels,
        turrets   = turrets,
        numText   = numText,
        colorText = colorText,
        ballTex   = ballTex,
    }
end

local function RenderWheelWidget(wheel, curWheelA, curBallA, ballRadFrac, highlightIdx, ballVisible, displayNum)
    if not wheel then return end
    local wf  = wheel.frame
    local cfg = wheel.cfg
    local cx, cy = cfg.cx, cfg.cy

    for idx = 1, 37 do
        local num  = WHEEL_ORDER[idx]
        local cKey = GetNumberColor(num)
        local col  = (highlightIdx == idx) and CFG.POCKET_WIN_COLORS[cKey] or CFG.POCKET_COLORS[cKey]

        local a = GetPocketWorldAngle(idx, curWheelA)
        local ca, sa = math.cos(a), math.sin(a)
        local wedge = wheel.wedges[idx]
        wedge:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
        wedge:SetStartPoint("BOTTOMLEFT", wf, cx + cfg.rInner * ca, cy + cfg.rInner * sa)
        wedge:SetEndPoint("BOTTOMLEFT", wf, cx + cfg.rOuter * ca, cy + cfg.rOuter * sa)

        local fa = a - (CFG.POCKET_STEP * 0.5)
        local cf, sf = math.cos(fa), math.sin(fa)
        local fret = wheel.frets[idx]
        fret:SetStartPoint("BOTTOMLEFT", wf, cx + (cfg.rInner - 1) * cf, cy + (cfg.rInner - 1) * sf)
        fret:SetEndPoint("BOTTOMLEFT", wf, cx + (cfg.rOuter + 1) * cf, cy + (cfg.rOuter + 1) * sf)

        local lbl = wheel.labels[idx]
        lbl:ClearAllPoints()
        lbl:SetPoint("CENTER", wf, "BOTTOMLEFT", cx + cfg.rNum * ca, cy + cfg.rNum * sa)
        if highlightIdx == idx then
            lbl:SetTextColor(1.00, 0.96, 0.75, 1.00)
        else
            lbl:SetTextColor(0.95, 0.95, 1.00, 0.95)
        end
    end

    for i = 1, 4 do
        local saAngle = curWheelA + (i - 1) * (math.pi * 0.5)
        local tx, ty = math.cos(saAngle), math.sin(saAngle)
        wheel.turrets[i]:SetStartPoint("BOTTOMLEFT", wf, cx + cfg.turretIn * tx, cy + cfg.turretIn * ty)
        wheel.turrets[i]:SetEndPoint("BOTTOMLEFT", wf, cx + cfg.turretOut * tx, cy + cfg.turretOut * ty)
    end

    if ballVisible then
        local rBall = cfg.rBallPocket + (cfg.rBallTrack - cfg.rBallPocket) * ballRadFrac
        wheel.ballTex:ClearAllPoints()
        wheel.ballTex:SetPoint("CENTER", wf, "BOTTOMLEFT",
            cx + rBall * math.cos(curBallA),
            cy + rBall * math.sin(curBallA))
        wheel.ballTex:Show()
    else
        wheel.ballTex:Hide()
    end

    if displayNum ~= nil then
        local cKey = GetNumberColor(displayNum)
        wheel.numText:SetText(tostring(displayNum))
        if cKey == "ZERO" then
            wheel.numText:SetTextColor(0.86, 0.72, 1.00, 1.00)
            wheel.colorText:SetText("|cff9d4eddVOID 0|r")
        elseif cKey == "RED" then
            wheel.numText:SetTextColor(1.00, 0.36, 0.44, 1.00)
            wheel.colorText:SetText("|cffe63946RED|r")
        else
            wheel.numText:SetTextColor(0.95, 0.95, 0.98, 1.00)
            wheel.colorText:SetText("|cffb0b0c0BLACK|r")
        end
    else
        wheel.numText:SetTextColor(unpack(COLORS.textMuted))
        wheel.numText:SetText("--")
        wheel.colorText:SetText("|cff888899READY|r")
    end
end

-- ============================================================================
-- Subtle Win Confetti & Pop-Out Wheel Overlay Controls
-- ============================================================================
local function StopConfetti()
    ST.confettiActive = false
    for i = 1, #UI.ConfettiPool do
        local p = UI.ConfettiPool[i]
        p.active = false
        p.tex:Hide()
    end
    if UI.ConfettiLayer then
        UI.ConfettiLayer:Hide()
    end
end

local function SpawnConfetti()
    if not UI.ConfettiLayer or #UI.ConfettiPool == 0 then return end
    local w = UI.ConfettiLayer:GetWidth()
    local h = UI.ConfettiLayer:GetHeight()
    if not w or w <= 0 then w = 820 end
    if not h or h <= 0 then h = 600 end

    for i = 1, #UI.ConfettiPool do
        local p   = UI.ConfettiPool[i]
        local col = CFG.CONFETTI_COLORS[((i - 1) % #CFG.CONFETTI_COLORS) + 1]
        p.x       = (ns.NextRandomFloat() * (w - 40)) + 20
        p.y       = h - 30 - (ns.NextRandomFloat() * 55)
        p.vx      = (ns.NextRandomFloat() - 0.5) * 90
        p.vy      = 20 + ns.NextRandomFloat() * 75
        p.baseW   = 5 + math.floor(ns.NextRandomFloat() * 4)
        p.baseH   = 3 + math.floor(ns.NextRandomFloat() * 3)
        p.phase   = ns.NextRandomFloat() * math.pi * 2
        p.freq    = 4 + ns.NextRandomFloat() * 5
        p.sway    = 14 + ns.NextRandomFloat() * 22
        p.life    = 0
        p.maxLife = 1.6 + ns.NextRandomFloat() * 0.8
        p.active  = true

        p.tex:SetColorTexture(col[1], col[2], col[3], 0.85)
        p.tex:SetSize(p.baseW, p.baseH)
        p.tex:SetAlpha(0.85)
        p.tex:ClearAllPoints()
        p.tex:SetPoint("CENTER", UI.ConfettiLayer, "BOTTOMLEFT", p.x, p.y)
        p.tex:Show()
    end

    ST.confettiActive = true
    UI.ConfettiLayer:Show()
end

local function ShowPopout()
    if not UI.PopoutOverlay then return end
    local wasShown = UI.PopoutOverlay:IsShown()
    UI.PopoutOverlay:Show()
    if not wasShown then
        ST.popoutFading    = true
        ST.popoutFadeTimer = 0
        UI.PopoutOverlay:SetAlpha(0)
    else
        ST.popoutFading = false
        UI.PopoutOverlay:SetAlpha(1)
    end
end

local function HidePopout()
    ST.popoutFading = false
    if UI.PopoutOverlay then
        UI.PopoutOverlay:Hide()
    end
    local hlIdx = ST.lastResult and WHEEL_INDEX[ST.lastResult] or nil
    RenderWheelWidget(UI.IdleWheel, ST.wheelAngle, ST.ballAngle, ST.ballRadiusFrac, hlIdx, ST.showWheelBall, ST.lastResult)
end

-- ============================================================================
-- Table Spot Visuals & Staged Bet Controls
-- ============================================================================
local function UpdateTableVisuals()
    local total = GetTotalStagedBet()
    if UI.WagerSummaryText then
        UI.WagerSummaryText:SetText(string.format("Total Bet: |cffd8b4fe%.2f|r", total))
    end

    if UI.SpinBtnText then
        if ST.state == "SPINNING" then
            UI.SpinBtnText:SetText("Spinning...")
        elseif total > 0 then
            UI.SpinBtnText:SetText(string.format("Spin (%.2f)", total))
        else
            UI.SpinBtnText:SetText("Spin")
        end
    end

    local winSpotId = (ST.state ~= "SPINNING" and ST.lastResult ~= nil) and ("N" .. tostring(ST.lastResult)) or nil

    for _, spotId in ipairs(UI.SpotOrder) do
        local btn = UI.SpotButtons[spotId]
        if btn then
            local betAmt = ST.stagedBets[spotId] or 0
            local isWinner = (winSpotId == spotId)

            local borderCol = btn.baseBorder
            if isWinner then
                borderCol = { 0.92, 0.85, 1.00, 1.00 }
            elseif betAmt > 0 then
                borderCol = COLORS.purpleBright
            end
            ns.StyleBox(btn, btn.baseBg, borderCol)

            if betAmt > 0 then
                btn.chipText:SetText(FormatCompactChip(betAmt))
                btn.chipBadge:Show()
                if btn.shiftOnBet then
                    btn.label:ClearAllPoints()
                    btn.label:SetPoint("CENTER", 0, 7)
                end
            else
                btn.chipBadge:Hide()
                if btn.shiftOnBet then
                    btn.label:ClearAllPoints()
                    btn.label:SetPoint("CENTER", 0, 0)
                end
            end
        end
    end

    local curChip = tonumber(UI.ChipInput and UI.ChipInput:GetText()) or 0
    for i = 1, #CFG.CHIP_PRESETS do
        local pBtn = UI.PresetButtons[i]
        if pBtn then
            local active = (math.abs(curChip - CFG.CHIP_PRESETS[i]) < 0.005)
            pBtn.isPrimary = active
            pBtn.customCol = active and COLORS.purpleBtn or COLORS.bgInput
            ns.StyleBox(pBtn, pBtn.customCol, active and COLORS.purpleBright or COLORS.border)
        end
    end

    local canModifyBets = (ST.state ~= "SPINNING") and (total >= 0.01)
    SetButtonEnabled(UI.ClearBtn, canModifyBets)
    SetButtonEnabled(UI.DoubleBetsBtn, canModifyBets)
end

local function ModifySpotBet(spotId, mouseButton)
    if ST.state == "SPINNING" then return end
    if mouseButton == "RightButton" then
        ST.stagedBets[spotId] = nil
        UpdateTableVisuals()
        return
    end

    local chip = GetChipValue()
    if chip < 0.01 then
        ST.statusBannerText = "|cffe63946Enter a valid chip size|r"
        if UI.SubStatusText then UI.SubStatusText:SetText(ST.statusBannerText) end
        return
    end

    ns.CheckBankrollRefill()
    local bal = (ns.db and ns.db.credits) or 0
    local currentTotal = GetTotalStagedBet()
    if currentTotal + chip > bal + 0.001 then
        ST.statusBannerText = "|cffe63946Insufficient credits for chip|r"
        if UI.SubStatusText then UI.SubStatusText:SetText(ST.statusBannerText) end
        return
    end

    ST.stagedBets[spotId] = math.floor(((ST.stagedBets[spotId] or 0) + chip) * 100 + 0.5) / 100
    UpdateTableVisuals()
end

-- ============================================================================
-- Spin Execution & Settlement (Deferred Pop-Out Reveal vs. Instant Roll)
-- ============================================================================
local function SettleSpin(data, skipAnimations)
    if not data then return end
    ST.state            = "IDLE"
    ST.pendingSpin      = nil
    ST.lastResult       = data.winningNum
    ST.currentRoundHash = data.hash
    ST.wheelAngle       = data.finalWheelAngle
    ST.ballAngle        = GetPocketWorldAngle(data.winIdx, ST.wheelAngle)
    ST.ballRadiusFrac   = 0.0
    ST.showWheelBall    = true

    ns.SetHashText("Spin SHA-Seed: " .. string.sub(data.hash, 1, 24) .. "...")

    local totalReturned = 0
    for spotId, betAmt in pairs(data.bets) do
        local retMult = GetSpotReturnMultiplier(spotId, data.winningNum)
        if retMult > 0 then
            totalReturned = totalReturned + (betAmt * retMult)
        end
    end
    totalReturned = math.floor(totalReturned * 100 + 1e-6) / 100

    if totalReturned > 0 then
        ns.AddCredits(totalReturned)
    end

    local netDelta = math.floor((totalReturned - data.totalWager) * 100 + 0.5) / 100
    local effMult  = (data.totalWager > 0) and (math.floor((totalReturned / data.totalWager) * 100 + 1e-6) / 100) or 0
    local cKey     = GetNumberColor(data.winningNum)

    LogRouletteTicker(data.winningNum, cKey)
    LogRoulettePersonal({
        player = data.player,
        num    = data.winningNum,
        color  = cKey,
        bet    = data.totalWager,
        delta  = netDelta,
        won    = (netDelta > 0),
        isPush = (netDelta == 0),
    })

    if netDelta > 0 then
        ST.statusBannerText = string.format("|cffd8b4feWIN!|r |cff9d4edd+%.2f|r |cff888899(%.2fx)|r", netDelta, effMult)
        ns.RecordGameOutcome("ROULETTE", true, data.totalWager, effMult, netDelta, data.shortHash)
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end
        if not skipAnimations then
            SpawnConfetti()
        end
    elseif netDelta < 0 then
        local netLoss = math.abs(netDelta)
        ST.statusBannerText = string.format("|cffe63946MISS|r |cff888899(-%.2f Credits)|r", netLoss)
        ns.RecordGameOutcome("ROULETTE", false, netLoss, effMult, 0, data.shortHash)
    else
        ST.statusBannerText = "|cffd8b4fePUSH|r |cff888899— Returned|r"
        ns.CheckBankrollRefill()
        ns.RefreshHub()
    end

    if UI.PopoutOverlay and UI.PopoutOverlay:IsShown() then
        UI.PopoutStatusText:SetText(ST.statusBannerText)
        UI.PopoutHintText:SetText("Click outside or Back to Table to edit bets")
        UI.PopoutBtnBar:Show()
        RenderWheelWidget(UI.BigWheel, ST.wheelAngle, ST.ballAngle, ST.ballRadiusFrac, data.winIdx, true, data.winningNum)
    end

    Roulette:Refresh()
end

local function ExecuteSpin()
    if ST.state == "SPINNING" then return end
    if UI.ChipInput then UI.ChipInput:ClearFocus() end

    local totalWager = GetTotalStagedBet()
    if totalWager < 0.01 then
        ST.statusBannerText = "|cffe63946Place a bet on the table first|r"
        if UI.SubStatusText then UI.SubStatusText:SetText(ST.statusBannerText) end
        if UI.PopoutOverlay and UI.PopoutOverlay:IsShown() then
            UI.PopoutStatusText:SetText(ST.statusBannerText)
        end
        return
    end

    ns.CheckBankrollRefill()
    local bal = (ns.db and ns.db.credits) or 0
    if bal + 0.001 < totalWager then
        ST.statusBannerText = "|cffe63946Insufficient credits for table bets|r"
        if UI.SubStatusText then UI.SubStatusText:SetText(ST.statusBannerText) end
        if UI.PopoutOverlay and UI.PopoutOverlay:IsShown() then
            UI.PopoutStatusText:SetText(ST.statusBannerText)
            UI.PopoutHintText:SetText("Click outside or Back to Table to edit bets")
        end
        return
    end

    local ok, actualBet = ns.DeductCredits(totalWager)
    if not ok then return end
    if actualBet < totalWager - 0.005 then
        ns.AddCredits(actualBet)
        return
    end
    StopConfetti()

    local betSnapshot = CopyBetTable(ST.stagedBets)
    ST.lastRoundBets = CopyBetTable(ST.stagedBets)

    -- Uniform 37-pocket selection
    local winIdx = math.floor(ns.NextRandomFloat() * 37) + 1
    if winIdx < 1 then winIdx = 1 elseif winIdx > 37 then winIdx = 37 end
    local winningNum = WHEEL_ORDER[winIdx]
    local roundHash  = ns.GenerateRoundHash(winningNum * 100 + totalWager)

    ST.wheelStartA = ST.wheelAngle % (2 * math.pi)
    ST.wheelEndA   = ST.wheelStartA + (1.85 * 2 * math.pi)

    local spinData = {
        winIdx          = winIdx,
        winningNum      = winningNum,
        bets            = betSnapshot,
        totalWager      = totalWager,
        hash            = roundHash,
        shortHash       = string.sub(roundHash, 1, 16),
        player          = ns.FormatPlayerName(ns.GetMyFormattedName()),
        finalWheelAngle = ST.wheelEndA % (2 * math.pi),
    }

    if ST.instantRollEnabled then
        if UI.PopoutOverlay and UI.PopoutOverlay:IsShown() then
            HidePopout()
        end
        SettleSpin(spinData, true)
        return
    end

    -- Synchronized 2-phase spin physics:
    -- Phase 1 (0..BALL_DROP_FRAC): Ball orbits CCW & drops onto exact pocket angle
    -- Phase 2 (BALL_DROP_FRAC..1): Ball locks in winning pocket & coasts CW with wheel
    local dropFracWheel = 1 - ((1 - CFG.BALL_DROP_FRAC) ^ 2.5)
    local wheelAtDrop   = ST.wheelStartA + (ST.wheelEndA - ST.wheelStartA) * dropFracWheel
    local dropPocketA   = GetPocketWorldAngle(winIdx, wheelAtDrop)

    ST.ballStartA = ST.ballAngle % (2 * math.pi)
    local delta = (dropPocketA - ST.ballStartA) % (2 * math.pi)
    if delta < 0 then delta = delta + (2 * math.pi) end
    ST.ballEndA = ST.ballStartA + delta + (3 * 2 * math.pi)

    ST.ballRadiusFrac = 1.0
    ST.showWheelBall  = true
    ST.spinTimer      = 0
    ST.state          = "SPINNING"
    ST.pendingSpin    = spinData

    ns.SetHashText("Spin SHA-Seed: Spinning...")
    ST.statusBannerText = "|cff9d4eddSPINNING...|r"

    ShowPopout()
    if UI.PopoutOverlay then
        UI.PopoutStatusText:SetText("|cff9d4eddSPINNING...|r")
        UI.PopoutHintText:SetText(string.format("Total Bet: %.2f Credits", totalWager))
        UI.PopoutBtnBar:Hide()
    end
    RenderWheelWidget(UI.BigWheel, ST.wheelStartA, ST.ballStartA, ST.ballRadiusFrac, nil, true, nil)

    ns.RefreshHub()
end

local function OnUpdateTick(self, elapsed)
    local dt = math.min(elapsed, 0.05)

    if ST.popoutFading and UI.PopoutOverlay and UI.PopoutOverlay:IsShown() then
        ST.popoutFadeTimer = ST.popoutFadeTimer + dt
        local alpha = ST.popoutFadeTimer / CFG.POPOUT_FADE_TIME
        if alpha >= 1 then
            alpha = 1
            ST.popoutFading = false
        end
        UI.PopoutOverlay:SetAlpha(alpha)
    end

    if ST.state == "SPINNING" and ST.pendingSpin then
        ST.spinTimer = ST.spinTimer + elapsed
        local t = ST.spinTimer / CFG.SPIN_DURATION
        if t >= 1 then
            SettleSpin(ST.pendingSpin, false)
        else
            local wheelEase = 1 - ((1 - t) ^ 2.5)
            ST.wheelAngle = ST.wheelStartA + (ST.wheelEndA - ST.wheelStartA) * wheelEase

            local liveIdx
            if t < CFG.BALL_DROP_FRAC then
                local p = t / CFG.BALL_DROP_FRAC
                local inv = 1 - p
                local ballEase = 1 - (inv * inv * inv)
                ST.ballAngle = ST.ballStartA + (ST.ballEndA - ST.ballStartA) * ballEase

                if p < 0.65 then
                    ST.ballRadiusFrac = 1.0
                else
                    local dropP = (p - 0.65) / 0.35
                    ST.ballRadiusFrac = 1.0 - (dropP * dropP)
                        + math.sin(dropP * math.pi * 3) * (1 - dropP) * 0.16
                end

                local rel = ((math.pi * 0.5) - ST.wheelAngle - ST.ballAngle) % (2 * math.pi)
                if rel < 0 then rel = rel + (2 * math.pi) end
                liveIdx = (math.floor(rel / CFG.POCKET_STEP + 0.5) % 37) + 1
            else
                liveIdx           = ST.pendingSpin.winIdx
                ST.ballAngle      = GetPocketWorldAngle(liveIdx, ST.wheelAngle)
                ST.ballRadiusFrac = 0.0
            end

            RenderWheelWidget(UI.BigWheel, ST.wheelAngle, ST.ballAngle, ST.ballRadiusFrac, liveIdx, true, WHEEL_ORDER[liveIdx])
        end
    end

    if ST.confettiActive and UI.ConfettiLayer then
        local anyAlive = false
        for i = 1, #UI.ConfettiPool do
            local p = UI.ConfettiPool[i]
            if p.active then
                p.life = p.life + dt
                if p.life >= p.maxLife then
                    p.active = false
                    p.tex:Hide()
                else
                    anyAlive = true
                    p.vy = math.max(-150, p.vy - 220 * dt)
                    p.x  = p.x + (p.vx + math.sin(p.life * p.freq + p.phase) * p.sway) * dt
                    p.y  = p.y + p.vy * dt

                    local flutterH = math.max(1.5, p.baseH * math.abs(math.cos(p.life * p.freq * 1.4 + p.phase)))
                    local rem      = p.maxLife - p.life
                    local alpha    = (rem < 0.6) and ((rem / 0.6) * 0.85) or 0.85

                    p.tex:SetSize(p.baseW, flutterH)
                    p.tex:SetAlpha(alpha)
                    p.tex:ClearAllPoints()
                    p.tex:SetPoint("CENTER", UI.ConfettiLayer, "BOTTOMLEFT", p.x, p.y)
                end
            end
        end
        if not anyAlive then
            ST.confettiActive = false
            UI.ConfettiLayer:Hide()
        end
    end
end

-- ============================================================================
-- Module Interface Methods
-- ============================================================================
function Roulette:IsBusy()
    return ST.state == "SPINNING"
end

function Roulette:Refresh()
    local db = ns.db
    if not UI.RouletteFrame or not db then return end
    db.roulHistory     = db.roulHistory or {}
    db.roulPersonalLog = db.roulPersonalLog or {}

    local isIdle = (ST.state ~= "SPINNING")
    SetButtonEnabled(UI.SpinBtn, isIdle)
    SetButtonEnabled(UI.BtnHalf, isIdle)
    SetButtonEnabled(UI.Btn2x, isIdle)
    SetButtonEnabled(UI.BtnMax, isIdle)
    SetButtonEnabled(UI.RebetBtn, isIdle and (next(ST.lastRoundBets) ~= nil))
    for i = 1, #CFG.CHIP_PRESETS do
        SetButtonEnabled(UI.PresetButtons[i], isIdle)
    end
    for _, spotId in ipairs(UI.SpotOrder) do
        local btn = UI.SpotButtons[spotId]
        if btn then
            if isIdle then btn:Enable() else btn:Disable() end
        end
    end
    if UI.ChipInput then
        if isIdle then
            UI.ChipInput:Enable()
        else
            UI.ChipInput:ClearFocus()
            UI.ChipInput:Disable()
        end
    end

    -- Top Ticker Pills (0 is Void Purple)
    for i = 1, CFG.NUM_TICKER_PILLS do
        local pill = UI.TickerPills[i]
        local item = db.roulHistory[i]
        if item then
            pill:Show()
            pill.text:SetText(tostring(item.num))
            if item.color == "ZERO" then
                pill.bgTex:SetColorTexture(unpack(COLORS.purpleBtn))
                pill.text:SetTextColor(1, 1, 1, 1)
            elseif item.color == "RED" then
                pill.bgTex:SetColorTexture(0.62, 0.14, 0.21, 1)
                pill.text:SetTextColor(1, 0.90, 0.92, 1)
            else
                pill.bgTex:SetColorTexture(0.11, 0.11, 0.16, 1)
                pill.text:SetTextColor(0.88, 0.88, 0.94, 1)
            end
        else
            pill:Hide()
        end
    end

    -- Left Sidebar Recent Spins History (formatted with ns.FormatPlayerName)
    local fallbackPlayer = ns.FormatPlayerName(ns.GetMyFormattedName())
    for i = 1, CFG.NUM_HISTORY_ROWS do
        local row   = UI.PersonalRows[i]
        local entry = db.roulPersonalLog[i]
        if entry then
            row:Show()
            local playerDisp = ns.FormatPlayerName(entry.player or fallbackPlayer)
            local numCol = (entry.color == "ZERO") and "|cffd8b4fe"
                or ((entry.color == "RED") and "|cffe63946" or "|cffffffff")
            row.left:SetText(string.format("%s %s%d|r |cff888899(%.0f)|r", playerDisp, numCol, entry.num, entry.bet))
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

    if UI.SubStatusText then
        UI.SubStatusText:SetText(ST.state == "SPINNING" and "|cff9d4eddSPINNING...|r" or ST.statusBannerText)
    end

    if isIdle then
        local hlIdx = ST.lastResult and WHEEL_INDEX[ST.lastResult] or nil
        RenderWheelWidget(UI.IdleWheel, ST.wheelAngle, ST.ballAngle, ST.ballRadiusFrac, hlIdx, ST.showWheelBall, ST.lastResult)
        if UI.PopoutOverlay and UI.PopoutOverlay:IsShown() then
            RenderWheelWidget(UI.BigWheel, ST.wheelAngle, ST.ballAngle, ST.ballRadiusFrac, hlIdx, ST.showWheelBall, ST.lastResult)
        end
    end

    UpdateTableVisuals()
end

function Roulette:OnShow()
    if ST.state == "SPINNING" then
        ns.SetHashText("Spin SHA-Seed: Spinning...")
    elseif ST.currentRoundHash ~= "" then
        ns.SetHashText("Spin SHA-Seed: " .. string.sub(ST.currentRoundHash, 1, 24) .. "...")
    else
        ns.SetHashText("Roulette — European Single-Zero | 0 = Void Purple")
    end
    Roulette:Refresh()
end

function Roulette:OnHide()
    StopConfetti()
    ST.popoutFading = false
    if UI.PopoutOverlay then
        UI.PopoutOverlay:Hide()
    end
    if ST.state == "SPINNING" and ST.pendingSpin then
        SettleSpin(ST.pendingSpin, true)
    end
end

function Roulette:Build(parent)
    UI.RouletteFrame = CreateFrame("Frame", "VoidCasinoRouletteFrame", parent)
    UI.RouletteFrame:SetAllPoints()

    -- 1. Left Controls Panel (230 x 340)
    local LeftPanel = CreateFrame("Frame", nil, UI.RouletteFrame)
    LeftPanel:SetPoint("TOPLEFT", 0, 0)
    LeftPanel:SetSize(230, 340)
    ns.StyleBox(LeftPanel, COLORS.bgPanel, COLORS.border)

    UI.SpinBtn = ns.CreateCustomButton(LeftPanel, 206, 42, "Spin", true)
    UI.SpinBtn:SetPoint("TOP", 0, -12)
    UI.SpinBtnText = UI.SpinBtn.label
    UI.SpinBtn:SetScript("OnClick", ExecuteSpin)

    local ChipLbl = LeftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ChipLbl:SetPoint("TOPLEFT", 12, -62)
    ChipLbl:SetText("Chip Size")
    ChipLbl:SetTextColor(unpack(COLORS.textMuted))

    local ChipBox = CreateFrame("Frame", nil, LeftPanel)
    ChipBox:SetSize(206, 30)
    ChipBox:SetPoint("TOPLEFT", 12, -76)
    ns.StyleBox(ChipBox, COLORS.bgInput, COLORS.border)

    UI.ChipInput = CreateFrame("EditBox", nil, ChipBox)
    UI.ChipInput:SetSize(96, 26)
    UI.ChipInput:SetPoint("LEFT", 8, 0)
    UI.ChipInput:SetFontObject("GameFontHighlight")
    UI.ChipInput:SetAutoFocus(false)
    UI.ChipInput:SetText("25")
    UI.ChipInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    UI.ChipInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    UI.ChipInput:SetScript("OnTextChanged", function() UpdateTableVisuals() end)

    UI.BtnMax = ns.CreateCustomButton(ChipBox, 36, 24, "Max", false)
    UI.BtnMax:SetPoint("RIGHT", -3, 0)
    UI.BtnMax:SetScript("OnClick", function()
        ns.CheckBankrollRefill()
        local bal = (ns.db and ns.db.credits) or 0
        local rem = math.max(0, math.floor((bal - GetTotalStagedBet()) * 100 + 1e-6) / 100)
        UI.ChipInput:SetText(string.format("%.2f", rem))
        UpdateTableVisuals()
    end)

    UI.Btn2x = ns.CreateCustomButton(ChipBox, 32, 24, "2x", false)
    UI.Btn2x:SetPoint("RIGHT", UI.BtnMax, "LEFT", -3, 0)
    UI.Btn2x:SetScript("OnClick", function()
        local cur = tonumber(UI.ChipInput:GetText()) or 0
        local bal = (ns.db and ns.db.credits) or 0
        local nextVal = math.min(bal, cur * 2)
        if bal >= 1 then
            nextVal = math.max(1, nextVal)
        else
            nextVal = math.max(0, math.floor(nextVal * 100 + 1e-6) / 100)
        end
        UI.ChipInput:SetText(string.format("%.2f", nextVal))
        UpdateTableVisuals()
    end)

    UI.BtnHalf = ns.CreateCustomButton(ChipBox, 32, 24, "1/2", false)
    UI.BtnHalf:SetPoint("RIGHT", UI.Btn2x, "LEFT", -3, 0)
    UI.BtnHalf:SetScript("OnClick", function()
        local cur = tonumber(UI.ChipInput:GetText()) or 0
        local bal = (ns.db and ns.db.credits) or 0
        local nextVal = math.floor((cur / 2) * 100 + 1e-6) / 100
        if bal >= 1 then
            nextVal = math.max(1, nextVal)
        elseif bal > 0 then
            nextVal = math.max(0.01, math.min(bal, nextVal))
        else
            nextVal = 0
        end
        UI.ChipInput:SetText(string.format("%.2f", nextVal))
        UpdateTableVisuals()
    end)

    -- Quick Chip Presets
    local ChipPresetBar = CreateFrame("Frame", nil, LeftPanel)
    ChipPresetBar:SetSize(206, 24)
    ChipPresetBar:SetPoint("TOPLEFT", 12, -114)

    for i = 1, #CFG.CHIP_PRESETS do
        local denom = CFG.CHIP_PRESETS[i]
        local pBtn = ns.CreateCustomButton(ChipPresetBar, 48, 22, tostring(denom), false)
        pBtn.label:SetFontObject("GameFontHighlightSmall")
        pBtn:SetPoint("LEFT", (i - 1) * 52 + 1, 0)
        pBtn:SetScript("OnClick", function()
            UI.ChipInput:SetText(tostring(denom))
            UpdateTableVisuals()
        end)
        UI.PresetButtons[i] = pBtn
    end

    -- Instant Roll Toggle (skips pop-out animation & confetti, settles immediately)
    local instantContainer
    instantContainer, UI.InstantSwitch = ns.CreateToggleSwitch(LeftPanel, "Instant Roll", function(val)
        ST.instantRollEnabled = val
        if val and ST.state == "SPINNING" and ST.pendingSpin then
            SettleSpin(ST.pendingSpin, true)
            HidePopout()
        end
    end)
    instantContainer:SetPoint("TOPLEFT", 12, -142)

    local HistLbl = LeftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    HistLbl:SetPoint("TOPLEFT", 12, -174)
    HistLbl:SetText("Recent Spins")
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

    -- 2. Right Wheel & European Betting Table Panel (554 x 340)
    local RightPanel = CreateFrame("Frame", nil, UI.RouletteFrame)
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

    -- Left Column inside StageFrame: Idle Preview Wheel & Bet Utilities
    UI.IdleWheel = CreateWheelWidget(StageFrame, CFG.IDLE_WHEEL)
    UI.IdleWheel.frame:SetPoint("TOPLEFT", 4, -4)

    UI.SubStatusText = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    UI.SubStatusText:SetPoint("TOP", UI.IdleWheel.frame, "BOTTOM", 0, -5)
    UI.SubStatusText:SetWidth(188)
    UI.SubStatusText:SetWordWrap(false)
    UI.SubStatusText:SetText(ST.statusBannerText)

    UI.WagerSummaryText = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    UI.WagerSummaryText:SetPoint("TOP", UI.SubStatusText, "BOTTOM", 0, -3)
    UI.WagerSummaryText:SetWidth(188)
    UI.WagerSummaryText:SetTextColor(unpack(COLORS.textMuted))

    UI.ClearBtn = ns.CreateCustomButton(StageFrame, 58, 24, "Clear", false)
    UI.ClearBtn:SetPoint("BOTTOMLEFT", 9, 10)
    UI.ClearBtn.label:SetFontObject("GameFontHighlightSmall")
    UI.ClearBtn:SetScript("OnClick", function()
        if ST.state == "SPINNING" then return end
        ST.stagedBets = {}
        UpdateTableVisuals()
    end)

    UI.RebetBtn = ns.CreateCustomButton(StageFrame, 58, 24, "Rebet", false)
    UI.RebetBtn:SetPoint("LEFT", UI.ClearBtn, "RIGHT", 5, 0)
    UI.RebetBtn.label:SetFontObject("GameFontHighlightSmall")
    UI.RebetBtn:SetScript("OnClick", function()
        if ST.state == "SPINNING" or next(ST.lastRoundBets) == nil then return end
        local lastTotal = 0
        for _, amt in pairs(ST.lastRoundBets) do
            lastTotal = lastTotal + (amt or 0)
        end
        lastTotal = math.floor(lastTotal * 100 + 0.5) / 100
        ns.CheckBankrollRefill()
        local bal = (ns.db and ns.db.credits) or 0
        if bal + 0.001 < lastTotal then
            ST.statusBannerText = "|cffe63946Insufficient credits to rebet|r"
            if UI.SubStatusText then UI.SubStatusText:SetText(ST.statusBannerText) end
            return
        end
        ST.stagedBets = CopyBetTable(ST.lastRoundBets)
        Roulette:Refresh()
    end)

    UI.DoubleBetsBtn = ns.CreateCustomButton(StageFrame, 58, 24, "2x Bet", false)
    UI.DoubleBetsBtn:SetPoint("LEFT", UI.RebetBtn, "RIGHT", 5, 0)
    UI.DoubleBetsBtn.label:SetFontObject("GameFontHighlightSmall")
    UI.DoubleBetsBtn:SetScript("OnClick", function()
        if ST.state == "SPINNING" then return end
        local total = GetTotalStagedBet()
        if total < 0.01 then return end
        ns.CheckBankrollRefill()
        local bal = (ns.db and ns.db.credits) or 0
        if bal + 0.001 < total * 2 then
            ST.statusBannerText = "|cffe63946Not enough credits to 2x bets|r"
            UI.SubStatusText:SetText(ST.statusBannerText)
            return
        end
        for k, v in pairs(ST.stagedBets) do
            ST.stagedBets[k] = math.floor(v * 2 * 100 + 0.5) / 100
        end
        UpdateTableVisuals()
    end)

    -- Vertical Separator between Wheel Column & Betting Felt
    local Divider = StageFrame:CreateTexture(nil, "BORDER")
    Divider:SetWidth(1)
    Divider:SetPoint("TOPLEFT", 200, -8)
    Divider:SetPoint("BOTTOMLEFT", 200, 8)
    Divider:SetColorTexture(unpack(COLORS.border))

    -- Right Column inside StageFrame: European 0-36 Betting Felt
    local FeltHint = StageFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    FeltHint:SetPoint("TOPLEFT", 205, -8)
    FeltHint:SetTextColor(unpack(COLORS.textMuted))
    FeltHint:SetText("Left-click: Add chip  •  Right-click: Remove")

    local function CreateBetSpot(spotId, x, y, w, h, text, bgCol, brdCol, descText, badgeW)
        local btn = CreateFrame("Button", nil, StageFrame)
        btn:SetSize(w, h)
        btn:SetPoint("TOPLEFT", x, y)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        ns.StyleBox(btn, bgCol, brdCol)

        btn.baseBg     = bgCol
        btn.baseBorder = brdCol
        btn.shiftOnBet = (h <= 46)

        btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.label:SetPoint("CENTER", 0, 0)
        btn.label:SetText(text)
        btn.label:SetTextColor(unpack(COLORS.textLight))

        local cBox = CreateFrame("Frame", nil, btn)
        cBox:SetSize(badgeW or (w - 4), 13)
        cBox:SetPoint("BOTTOM", 0, 2)
        cBox:SetFrameLevel(btn:GetFrameLevel() + 2)
        ns.StyleBox(cBox, COLORS.bgMain, COLORS.purpleBright)
        cBox:Hide()

        btn.chipBadge = cBox
        btn.chipText  = cBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.chipText:SetPoint("CENTER", 0, 0)
        local cFontPath, _, cFontFlags = btn.chipText:GetFont()
        if cFontPath then
            btn.chipText:SetFont(cFontPath, 9, cFontFlags)
        end
        btn.chipText:SetTextColor(0.86, 0.72, 1.00, 1.00)

        local function RefreshSpotHover()
            if not UI.HoverInfoText then return end
            local placed = ST.stagedBets[spotId] or 0
            if placed > 0 then
                UI.HoverInfoText:SetText(string.format("|cffffffff%s|r  |cffd8b4fe(Bet: %.2f)|r", descText, placed))
            else
                UI.HoverInfoText:SetText(string.format("|cffffffff%s|r", descText))
            end
        end

        btn:SetScript("OnClick", function(self, mouseButton)
            ModifySpotBet(spotId, mouseButton)
            RefreshSpotHover()
        end)

        btn:SetScript("OnEnter", function(self)
            if self.IsEnabled and not self:IsEnabled() then return end
            local highlight = {
                math.min(1, self.baseBg[1] + 0.12),
                math.min(1, self.baseBg[2] + 0.10),
                math.min(1, self.baseBg[3] + 0.14),
                1.00
            }
            self.bgTex:SetColorTexture(unpack(highlight))
            RefreshSpotHover()
        end)

        btn:SetScript("OnLeave", function(self)
            self.bgTex:SetColorTexture(unpack(self.baseBg))
            if UI.HoverInfoText then
                UI.HoverInfoText:SetText(ST.defaultInfoText)
            end
        end)

        UI.SpotButtons[spotId] = btn
        table.insert(UI.SpotOrder, spotId)
        return btn
    end

    local gridX = 205
    local gridY = -26

    -- Void-Purple Zero Pocket (replaces green 0)
    CreateBetSpot("N0", gridX, gridY, 24, 134, "0", CFG.CELL_COLORS.ZERO, COLORS.purpleBright, "Zero (0) — Pays 35:1", 20)

    -- 12 x 3 Straight-Up Number Grid (1..36)
    local numStartX = gridX + 26
    for col = 1, 12 do
        for rowIdx = 1, 3 do
            local num = (col * 3) - (rowIdx - 1) -- top: 3..36, mid: 2..35, bot: 1..34
            local cKey = GetNumberColor(num)
            local cName = (cKey == "RED") and "Red" or "Black"
            local bx = numStartX + (col - 1) * 23
            local by = gridY - (rowIdx - 1) * 45
            CreateBetSpot("N" .. tostring(num), bx, by, 22, 44, tostring(num),
                CFG.CELL_COLORS[cKey], COLORS.border,
                string.format("Straight %d (%s) — Pays 35:1", num, cName), 20)
        end
    end

    -- 3 Column "2:1" Spots aligned with the 3 rows
    local colStartX = numStartX + 277
    local colSpots = {
        { id = "COL3", desc = "Top Column (3, 6..36) — Pays 2:1" },
        { id = "COL2", desc = "Middle Column (2, 5..35) — Pays 2:1" },
        { id = "COL1", desc = "Bottom Column (1, 4..34) — Pays 2:1" },
    }
    for r = 1, 3 do
        local info = colSpots[r]
        CreateBetSpot(info.id, colStartX, gridY - (r - 1) * 45, 26, 44, "2:1",
            COLORS.bgPanel, COLORS.border, info.desc, 22)
    end

    -- Dozens Row (1st 12, 2nd 12, 3rd 12)
    local dozSpots = {
        { id = "DOZ1", label = "1st 12", desc = "1st Dozen (1-12) — Pays 2:1" },
        { id = "DOZ2", label = "2nd 12", desc = "2nd Dozen (13-24) — Pays 2:1" },
        { id = "DOZ3", label = "3rd 12", desc = "3rd Dozen (25-36) — Pays 2:1" },
    }
    for i = 1, 3 do
        local info = dozSpots[i]
        CreateBetSpot(info.id, numStartX + (i - 1) * 92, -165, 91, 34, info.label,
            COLORS.bgPanel, COLORS.border, info.desc, 44)
    end

    -- Outside Even-Money Row (1-18, EVEN, RED, BLK, ODD, 19-36)
    local outSpots = {
        { id = "LOW",   label = "1-18",  bg = COLORS.bgPanel,       desc = "Low (1-18) — Pays 1:1" },
        { id = "EVEN",  label = "EVEN",  bg = COLORS.bgPanel,       desc = "Even — Pays 1:1" },
        { id = "RED",   label = "RED",   bg = CFG.CELL_COLORS.RED,   desc = "Red (18 Numbers) — Pays 1:1" },
        { id = "BLACK", label = "BLK",   bg = CFG.CELL_COLORS.BLACK, desc = "Black (18 Numbers) — Pays 1:1" },
        { id = "ODD",   label = "ODD",   bg = COLORS.bgPanel,       desc = "Odd — Pays 1:1" },
        { id = "HIGH",  label = "19-36", bg = COLORS.bgPanel,       desc = "High (19-36) — Pays 1:1" },
    }
    for i = 1, 6 do
        local info = outSpots[i]
        CreateBetSpot(info.id, numStartX + (i - 1) * 46, -203, 45, 38, info.label,
            info.bg, COLORS.border, info.desc, 36)
    end

    -- Bottom Payout / Hover Info Bar
    local InfoBar = CreateFrame("Frame", nil, StageFrame)
    InfoBar:SetSize(329, 34)
    InfoBar:SetPoint("BOTTOMLEFT", 205, 10)
    ns.StyleBox(InfoBar, COLORS.bgPanel, COLORS.border)

    UI.HoverInfoText = InfoBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    UI.HoverInfoText:SetPoint("CENTER", 0, 0)
    UI.HoverInfoText:SetWidth(316)
    UI.HoverInfoText:SetWordWrap(false)
    UI.HoverInfoText:SetText(ST.defaultInfoText)

    -- 3. Pop-Out Zoomed Wheel Overlay (darkens main hub below 42px header)
    local mainParent = _G["VoidCasinoMainFrame"] or StageFrame
    UI.PopoutOverlay = CreateFrame("Button", nil, mainParent)
    if mainParent == _G["VoidCasinoMainFrame"] then
        UI.PopoutOverlay:SetPoint("TOPLEFT", 1, -43)
        UI.PopoutOverlay:SetPoint("BOTTOMRIGHT", -1, 1)
    else
        UI.PopoutOverlay:SetAllPoints(mainParent)
    end
    UI.PopoutOverlay:SetFrameLevel(mainParent:GetFrameLevel() + 40)
    UI.PopoutOverlay:EnableMouse(true)
    ns.StyleBox(UI.PopoutOverlay, { 0.02, 0.02, 0.04, 0.78 }, nil)
    UI.PopoutOverlay:SetScript("OnClick", function()
        if ST.state ~= "SPINNING" then
            HidePopout()
        end
    end)
    UI.PopoutOverlay:Hide()

    UI.PopoutCard = CreateFrame("Frame", nil, UI.PopoutOverlay)
    UI.PopoutCard:SetSize(400, 454)
    UI.PopoutCard:SetPoint("CENTER", 0, 0)
    UI.PopoutCard:EnableMouse(true)
    ns.StyleBox(UI.PopoutCard, COLORS.bgMain, COLORS.purpleBright)

    UI.BigWheel = CreateWheelWidget(UI.PopoutCard, CFG.BIG_WHEEL)
    UI.BigWheel.frame:SetPoint("TOP", 0, -14)

    UI.PopoutStatusText = UI.PopoutCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    UI.PopoutStatusText:SetPoint("TOP", UI.BigWheel.frame, "BOTTOM", 0, -8)
    UI.PopoutStatusText:SetWidth(372)
    UI.PopoutStatusText:SetWordWrap(false)

    UI.PopoutHintText = UI.PopoutCard:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    UI.PopoutHintText:SetPoint("TOP", UI.PopoutStatusText, "BOTTOM", 0, -4)
    UI.PopoutHintText:SetWidth(372)
    UI.PopoutHintText:SetTextColor(unpack(COLORS.textMuted))

    UI.PopoutBtnBar = CreateFrame("Frame", nil, UI.PopoutCard)
    UI.PopoutBtnBar:SetSize(292, 30)
    UI.PopoutBtnBar:SetPoint("BOTTOM", 0, 14)
    UI.PopoutBtnBar:Hide()

    UI.PopoutSpinAgainBtn = ns.CreateCustomButton(UI.PopoutBtnBar, 140, 30, "Spin Again", true)
    UI.PopoutSpinAgainBtn:SetPoint("LEFT", 0, 0)
    UI.PopoutSpinAgainBtn:SetScript("OnClick", ExecuteSpin)

    UI.PopoutTableBtn = ns.CreateCustomButton(UI.PopoutBtnBar, 140, 30, "Back to Table", false)
    UI.PopoutTableBtn:SetPoint("RIGHT", 0, 0)
    UI.PopoutTableBtn:SetScript("OnClick", function()
        if ST.state ~= "SPINNING" then
            HidePopout()
        end
    end)

    -- 4. Subtle Win Confetti Overlay across Main Window
    UI.ConfettiLayer = CreateFrame("Frame", nil, mainParent)
    UI.ConfettiLayer:SetAllPoints(mainParent)
    UI.ConfettiLayer:SetClipsChildren(true)
    UI.ConfettiLayer:EnableMouse(false)
    UI.ConfettiLayer:SetFrameLevel(UI.PopoutOverlay:GetFrameLevel() + 10)
    UI.ConfettiLayer:Hide()

    for i = 1, CFG.CONFETTI_COUNT do
        local tex = UI.ConfettiLayer:CreateTexture(nil, "OVERLAY")
        tex:Hide()
        UI.ConfettiPool[i] = {
            tex    = tex,
            active = false,
        }
    end

    UI.RouletteFrame:SetScript("OnUpdate", OnUpdateTick)
    UI.RouletteFrame:SetScript("OnHide", function() Roulette:OnHide() end)

    RenderWheelWidget(UI.IdleWheel, ST.wheelAngle, ST.ballAngle, ST.ballRadiusFrac, nil, false, nil)
    RenderWheelWidget(UI.BigWheel,  ST.wheelAngle, ST.ballAngle, ST.ballRadiusFrac, nil, false, nil)
    UpdateTableVisuals()

    return UI.RouletteFrame
end

ns.RegisterGame("ROULETTE", Roulette)
