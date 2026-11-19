-- ============================================================================
-- VoidCasino - Games/Crash.lua
-- 60 FPS Curve Engine, Dynamic Segment Scaling & Context-Aware Bet Controls
-- ============================================================================

local ADDON_NAME, ns = ...
local COLORS = ns.COLORS

local Crash = {}

-- Constants
local COUNTDOWN_TIME   = 4.0
local CRASH_HOLD_TIME  = 3.0
local CURVE_SEGMENTS   = 48
local NUM_TICKER_PILLS = 11

-- Runtime State
local CrashFrame
local state = "IDLE" -- "COUNTDOWN", "RUNNING", "CRASHED"
local stateTimer = 0
local crashedElapsedTime = 0
local currentMultiplier = 1.00
local crashPoint = 1.00
local currentRoundHash = ""

local activeBet = 0
local queuedBet = false
local cashedOut = false
local cashoutMult = 0
local autoCashoutEnabled = false
local autoBetEnabled = false

-- UI References
local BetInput, CashoutInput, MainActionBtn, MainActionText
local BigMultText, SubStatusText
local GraphFrame, DotTex
local CurveLines = {}
local GridLabelsY = {}
local GridLabelsX = {}
local TickerPills = {}
local PersonalRows = {}

-- Authentic Crash Distribution (1% House Edge, Instant 1.00x + Heavy Tail)
local function RollAuthenticCrashPoint()
    local u = ns.NextRandomFloat()
    if u < 0.01 then return 1.00 end
    local raw = 0.99 / (1.0 - u)
    local floored = math.floor(raw * 100) / 100
    if floored < 1.00 then floored = 1.00 end
    if floored > 10000.00 then floored = 10000.00 end
    return floored
end

local function GetExactTimeForMultiplier(mult)
    if mult <= 1.00 then return 0 end
    return (math.log(mult) / 0.065) ^ (1 / 1.35)
end

local function LogCrashPersonal(won, betAmt, multVal, profitVal)
    local db = ns.db
    if not db then return end
    table.insert(db.crashPersonalLog, 1, {
        bet    = betAmt,
        mult   = multVal,
        profit = profitVal,
        won    = won,
    })
    while #db.crashPersonalLog > 15 do
        table.remove(db.crashPersonalLog)
    end
end

local function TriggerCashout(targetMult)
    if activeBet <= 0 or cashedOut then return end
    cashedOut = true
    cashoutMult = targetMult or currentMultiplier
    local payout = math.floor(activeBet * cashoutMult * 100) / 100
    local netWin = payout - activeBet

    ns.AddCredits(payout)
    LogCrashPersonal(true, activeBet, cashoutMult, netWin)
    ns.RecordGameOutcome("Crash", true, activeBet, cashoutMult, netWin, string.sub(currentRoundHash, 1, 16))
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
end

local function LockInBet()
    local ok, actual = ns.DeductCredits(BetInput:GetText())
    if not ok then return false end
    BetInput:SetText(string.format("%.2f", actual))
    activeBet = actual
    cashedOut = false
    cashoutMult = 0
    queuedBet = false
    ns.RefreshHub()
    return true
end

local function StartCountdown()
    state = "COUNTDOWN"
    stateTimer = COUNTDOWN_TIME
    crashedElapsedTime = 0
    currentMultiplier = 1.00

    if queuedBet or autoBetEnabled then
        LockInBet()
    end
    ns.RefreshHub()
end

local function StartRound()
    state = "RUNNING"
    stateTimer = 0
    crashedElapsedTime = 0
    currentMultiplier = 1.00
    crashPoint = RollAuthenticCrashPoint()
    currentRoundHash = ns.GenerateRoundHash(crashPoint)
    ns.SetHashText("Round SHA-Seed: " .. string.sub(currentRoundHash, 1, 24) .. "...")
    ns.RefreshHub()
end

local function CrashRound()
    state = "CRASHED"
    crashedElapsedTime = GetExactTimeForMultiplier(crashPoint)
    stateTimer = CRASH_HOLD_TIME
    currentMultiplier = crashPoint

    local lostBet = (activeBet > 0 and not cashedOut) and activeBet or 0
    activeBet = 0
    cashedOut = false

    table.insert(ns.db.crashHistory, 1, crashPoint)
    while #ns.db.crashHistory > 15 do
        table.remove(ns.db.crashHistory)
    end

    if lostBet > 0 then
        LogCrashPersonal(false, lostBet, crashPoint, 0)
        ns.RecordGameOutcome("Crash", false, lostBet, crashPoint, 0, string.sub(currentRoundHash, 1, 16))
    else
        ns.CheckBankrollRefill()
        ns.RefreshHub()
    end
end

-- ============================================================================
-- 60 FPS Curve Renderer
-- ============================================================================
local function UpdateGraphVisuals(elapsedRoundTime, isCrashed)
    local w = GraphFrame:GetWidth() - 62
    local h = GraphFrame:GetHeight() - 50
    local startX = 42
    local startY = 26

    local maxMultY = math.max(2.0, currentMultiplier * 1.25)
    local maxTimeX = math.max(8.0, elapsedRoundTime * 1.15)

    local ySteps = {
        1.0,
        1.0 + (maxMultY - 1.0) * 0.25,
        1.0 + (maxMultY - 1.0) * 0.50,
        1.0 + (maxMultY - 1.0) * 0.75,
        maxMultY
    }
    for i = 1, 5 do
        GridLabelsY[i]:SetText(string.format("%.1fx", ySteps[i]))
    end

    for i = 1, 5 do
        local tVal = (maxTimeX / 5) * i
        if maxTimeX < 10.0 then
            GridLabelsX[i]:SetText(string.format("%.1fs", tVal))
        else
            GridLabelsX[i]:SetText(string.format("%.0fs", tVal))
        end
    end

    if state == "COUNTDOWN" then
        for i = 1, CURVE_SEGMENTS do CurveLines[i]:Hide() end
        DotTex:Hide()
        return
    end

    local lineColor = isCrashed and COLORS.crashRed or COLORS.purpleBright

    if elapsedRoundTime <= 0.001 then
        for i = 1, CURVE_SEGMENTS do CurveLines[i]:Hide() end
        DotTex:ClearAllPoints()
        DotTex:SetPoint("CENTER", GraphFrame, "BOTTOMLEFT", startX, startY)
        DotTex:SetColorTexture(unpack(lineColor))
        DotTex:Show()
        return
    end

    local progressX = math.min(0.92, elapsedRoundTime / maxTimeX)
    local progressY = math.min(0.76, ((currentMultiplier - 1.0) / (maxMultY - 1.0)) * 0.76)

    local tipSpanX = math.max(4.0, w * progressX)
    local tipSpanY = math.max(1.5, h * progressY)

    local activeSegs = math.max(1, math.min(CURVE_SEGMENTS, math.floor(tipSpanX / 5)))
    local lastX, lastY = startX, startY

    for i = 1, CURVE_SEGMENTS do
        local seg = CurveLines[i]
        if i <= activeSegs then
            local frac1 = (i - 1) / activeSegs
            local frac2 = i / activeSegs

            local x1 = startX + frac1 * tipSpanX
            local y1 = startY + (frac1 ^ 1.85) * tipSpanY

            local x2 = startX + frac2 * tipSpanX
            local y2 = startY + (frac2 ^ 1.85) * tipSpanY

            seg:SetColorTexture(unpack(lineColor))
            seg:SetStartPoint("BOTTOMLEFT", GraphFrame, x1, y1)
            seg:SetEndPoint("BOTTOMLEFT", GraphFrame, x2, y2)
            seg:Show()

            lastX, lastY = x2, y2
        else
            seg:Hide()
        end
    end

    DotTex:ClearAllPoints()
    DotTex:SetPoint("CENTER", GraphFrame, "BOTTOMLEFT", lastX, lastY)
    DotTex:SetColorTexture(unpack(lineColor))
    DotTex:Show()
end

local function OnUpdateTick(self, elapsed)
    if state == "COUNTDOWN" then
        stateTimer = stateTimer - elapsed
        BigMultText:SetTextColor(unpack(COLORS.textLight))
        BigMultText:SetText(string.format("%.1fs", math.max(0, stateTimer)))
        SubStatusText:SetText("|cff9d4eddNEXT ROUND STARTING...|r")
        UpdateGraphVisuals(0, false)

        if stateTimer <= 0 then
            StartRound()
        end

    elseif state == "RUNNING" then
        stateTimer = stateTimer + elapsed
        currentMultiplier = math.floor(math.exp(0.065 * (stateTimer ^ 1.35)) * 100) / 100
        if currentMultiplier < 1.00 then currentMultiplier = 1.00 end

        if activeBet > 0 and not cashedOut and autoCashoutEnabled then
            local target = tonumber(CashoutInput:GetText()) or 2.00
            if target >= 1.01 and currentMultiplier >= target and crashPoint >= target then
                TriggerCashout(target)
            end
        end

        if currentMultiplier >= crashPoint then
            CrashRound()
            return
        end

        BigMultText:SetTextColor(1, 1, 1, 1)
        BigMultText:SetText(string.format("%.2fx", currentMultiplier))
        if cashedOut then
            SubStatusText:SetText(string.format("|cff9d4eddCASHED OUT @ %.2fx (+%.2f)|r", cashoutMult, activeBet * (cashoutMult - 1)))
        elseif activeBet > 0 then
            SubStatusText:SetText(string.format("|cffd8b4fePayout: %.2f Credits|r", activeBet * currentMultiplier))
        else
            SubStatusText:SetText("|cff888899IN FLIGHT|r")
        end

        if activeBet > 0 and not cashedOut then
            MainActionText:SetText(string.format("Cash Out (%.2f)", activeBet * currentMultiplier))
        end

        UpdateGraphVisuals(stateTimer, false)

    elseif state == "CRASHED" then
        stateTimer = stateTimer - elapsed
        BigMultText:SetTextColor(unpack(COLORS.crashRed))
        BigMultText:SetText(string.format("%.2fx", crashPoint))
        SubStatusText:SetText("|cffe63946CRASHED @ " .. string.format("%.2fx", crashPoint) .. "|r")
        UpdateGraphVisuals(crashedElapsedTime, true)

        if stateTimer <= 0 then
            StartCountdown()
        end
    end
end

-- ============================================================================
-- Module Interface Methods
-- ============================================================================
function Crash:IsBusy()
    return activeBet > 0
end

function Crash:Refresh()
    local db = ns.db
    if not CrashFrame or not db then return end

    for i = 1, NUM_TICKER_PILLS do
        local pill = TickerPills[i]
        local val = db.crashHistory[i]
        if val then
            pill:Show()
            pill.text:SetText(string.format("%.2fx", val))
            if val >= 2.00 then
                pill.bgTex:SetColorTexture(unpack(COLORS.purpleBtn))
                pill.text:SetTextColor(1, 1, 1, 1)
            else
                pill.bgTex:SetColorTexture(0.13, 0.13, 0.18, 1)
                pill.text:SetTextColor(0.72, 0.72, 0.80, 1)
            end
        else
            pill:Hide()
        end
    end

    for i = 1, 4 do
        local row = PersonalRows[i]
        local entry = db.crashPersonalLog[i]
        if entry then
            row:Show()
            row.left:SetText(string.format("|cffb57edcC|r %.0f |cff888899@%.2fx|r", entry.bet, entry.mult))
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

    if state == "RUNNING" then
        if activeBet > 0 and not cashedOut then
            MainActionBtn.customCol = {0.62, 0.31, 0.87, 1}
            MainActionBtn.bgTex:SetColorTexture(0.62, 0.31, 0.87, 1)
            MainActionText:SetText(string.format("Cash Out (%.2f)", activeBet * currentMultiplier))
        elseif queuedBet then
            MainActionBtn.customCol = {0.32, 0.15, 0.48, 1}
            MainActionBtn.bgTex:SetColorTexture(0.32, 0.15, 0.48, 1)
            MainActionText:SetText("Queued (Cancel)")
        else
            MainActionBtn.customCol = COLORS.purpleBtn
            MainActionBtn.bgTex:SetColorTexture(unpack(COLORS.purpleBtn))
            MainActionText:SetText("Bet (Next Round)")
        end
    elseif state == "COUNTDOWN" then
        if activeBet > 0 then
            MainActionBtn.customCol = {0.32, 0.15, 0.48, 1}
            MainActionBtn.bgTex:SetColorTexture(0.32, 0.15, 0.48, 1)
            MainActionText:SetText(string.format("Bet Locked (%.0f)", activeBet))
        else
            MainActionBtn.customCol = COLORS.purpleBtn
            MainActionBtn.bgTex:SetColorTexture(unpack(COLORS.purpleBtn))
            MainActionText:SetText("Bet")
        end
    else
        if queuedBet then
            MainActionBtn.customCol = {0.32, 0.15, 0.48, 1}
            MainActionBtn.bgTex:SetColorTexture(0.32, 0.15, 0.48, 1)
            MainActionText:SetText("Queued (Cancel)")
        else
            MainActionBtn.customCol = COLORS.purpleBtn
            MainActionBtn.bgTex:SetColorTexture(unpack(COLORS.purpleBtn))
            MainActionText:SetText("Bet (Next Round)")
        end
    end
end

function Crash:OnShow()
    if state == "IDLE" then
        StartCountdown()
    end
    if currentRoundHash ~= "" then
        ns.SetHashText("Round SHA-Seed: " .. string.sub(currentRoundHash, 1, 24) .. "...")
    else
        ns.SetHashText("Round SHA-Seed: Waiting...")
    end
end

function Crash:OnHide()
    queuedBet = false
end

function Crash:Build(parent)
    CrashFrame = CreateFrame("Frame", "VoidCasinoCrashFrame", parent)
    CrashFrame:SetAllPoints()

    -- Left Controls Panel
    local LeftPanel = CreateFrame("Frame", nil, CrashFrame)
    LeftPanel:SetPoint("TOPLEFT", 0, 0)
    LeftPanel:SetSize(230, 340)
    ns.StyleBox(LeftPanel, COLORS.bgPanel, COLORS.border)

    MainActionBtn = ns.CreateCustomButton(LeftPanel, 206, 42, "Bet", true)
    MainActionBtn:SetPoint("TOP", 0, -12)
    MainActionText = MainActionBtn.label

    MainActionBtn:SetScript("OnClick", function()
        if state == "RUNNING" then
            if activeBet > 0 and not cashedOut then
                TriggerCashout(currentMultiplier)
            else
                queuedBet = not queuedBet
                Crash:Refresh()
            end
        elseif state == "COUNTDOWN" then
            if activeBet > 0 then
                ns.AddCredits(activeBet)
                activeBet = 0
                queuedBet = false
                ns.RefreshHub()
            else
                LockInBet()
            end
        else
            queuedBet = not queuedBet
            Crash:Refresh()
        end
    end)

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

    local BtnMax = ns.CreateCustomButton(BetBox, 36, 24, "Max", false)
    BtnMax:SetPoint("RIGHT", -3, 0)
    BtnMax:SetScript("OnClick", function()
        ns.CheckBankrollRefill()
        BetInput:SetText(string.format("%.2f", math.max(0, ns.db.credits)))
    end)

    local Btn2x = ns.CreateCustomButton(BetBox, 32, 24, "2x", false)
    Btn2x:SetPoint("RIGHT", BtnMax, "LEFT", -3, 0)
    Btn2x:SetScript("OnClick", function()
        local cur = tonumber(BetInput:GetText()) or 0
        local nextVal = math.min(ns.db.credits, cur * 2)
        BetInput:SetText(string.format("%.2f", math.max(1, nextVal)))
    end)

    local BtnHalf = ns.CreateCustomButton(BetBox, 32, 24, "1/2", false)
    BtnHalf:SetPoint("RIGHT", Btn2x, "LEFT", -3, 0)
    BtnHalf:SetScript("OnClick", function()
        local cur = tonumber(BetInput:GetText()) or 0
        BetInput:SetText(string.format("%.2f", math.max(1, math.floor((cur / 2) * 100) / 100)))
    end)

    local coContainer = ns.CreateToggleSwitch(LeftPanel, "Cash Out At (x)", function(val)
        autoCashoutEnabled = val
    end)
    coContainer:SetPoint("TOPLEFT", 12, -118)

    local CoInputBox = CreateFrame("Frame", nil, LeftPanel)
    CoInputBox:SetSize(64, 20)
    CoInputBox:SetPoint("LEFT", coContainer, "LEFT", 94, 0)
    ns.StyleBox(CoInputBox, COLORS.bgInput, COLORS.border)

    CashoutInput = CreateFrame("EditBox", nil, CoInputBox)
    CashoutInput:SetAllPoints()
    CashoutInput:SetJustifyH("CENTER")
    CashoutInput:SetFontObject("GameFontHighlightSmall")
    CashoutInput:SetAutoFocus(false)
    CashoutInput:SetText("2.00")
    CashoutInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    CashoutInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local abContainer = ns.CreateToggleSwitch(LeftPanel, "Auto Bet Each Round", function(val)
        autoBetEnabled = val
    end)
    abContainer:SetPoint("TOPLEFT", 12, -148)

    local HistLbl = LeftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    HistLbl:SetPoint("TOPLEFT", 12, -184)
    HistLbl:SetText("Your Crash History")
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

    -- Right Graph & Ticker Panel
    local RightPanel = CreateFrame("Frame", nil, CrashFrame)
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

    GraphFrame = CreateFrame("Frame", nil, RightPanel)
    GraphFrame:SetPoint("TOPLEFT", 8, -36)
    GraphFrame:SetPoint("BOTTOMRIGHT", -8, 8)
    GraphFrame:SetClipsChildren(true)
    ns.StyleBox(GraphFrame, COLORS.bgInput, COLORS.border)

    for i = 1, 5 do
        local yLbl = GraphFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        yLbl:SetPoint("BOTTOMLEFT", 8, 22 + (i - 1) * 58)
        yLbl:SetTextColor(unpack(COLORS.textMuted))
        GridLabelsY[i] = yLbl

        local xLbl = GraphFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        xLbl:SetPoint("BOTTOMLEFT", 48 + (i - 1) * 102, 8)
        xLbl:SetTextColor(unpack(COLORS.textMuted))
        GridLabelsX[i] = xLbl
    end

    BigMultText = GraphFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    BigMultText:SetPoint("CENTER", -20, 44)
    local fontPath, _, fontFlags = BigMultText:GetFont()
    if fontPath then
        BigMultText:SetFont(fontPath, 44, fontFlags)
    end
    BigMultText:SetText("1.00x")

    SubStatusText = GraphFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    SubStatusText:SetPoint("TOP", BigMultText, "BOTTOM", 0, -6)
    SubStatusText:SetText("WAITING FOR NEXT ROUND")

    for i = 1, CURVE_SEGMENTS do
        local line = GraphFrame:CreateLine(nil, "ARTWORK")
        line:SetThickness(2.8)
        line:Hide()
        CurveLines[i] = line
    end

    DotTex = GraphFrame:CreateTexture(nil, "OVERLAY")
    DotTex:SetSize(10, 10)
    local CircleMask = GraphFrame:CreateMaskTexture()
    CircleMask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    CircleMask:SetAllPoints(DotTex)
    DotTex:AddMaskTexture(CircleMask)
    DotTex:Hide()

    CrashFrame:SetScript("OnUpdate", OnUpdateTick)
    return CrashFrame
end

ns.RegisterGame("CRASH", Crash)