-- ============================================================================
-- VoidCasino - Hub.lua
-- Main Window Shell, Game Switcher Tabs, Shared Round Log & Top-5 Guild Drawer
-- ============================================================================

local ADDON_NAME, ns = ...
local COLORS = ns.COLORS

local MainFrame, ClanDrawer, ClanHeaderSubText
local LbTitleText, ClanWinsTitleText
local BalanceText, LockoutText, ProfitText, HashText
local GameStage
local NavButtons = {}
local DrawerTabButtons = {}
local MountedFrames = {}
local AllBetRows = {}
local LeaderboardRows = {}
local ClanFeedRows = {}

local TOP_N = 5
local activeGameId = nil
local activeDrawerTab = "OVERALL"
local hubTickAccumulator = 0

function ns.SetHashText(text)
    if HashText then
        HashText:SetText(text or "")
    end
end

local function GetDrawerTabInfo(tabId)
    for _, tab in ipairs(ns.LeaderboardTabs) do
        if tab.id == tabId then return tab end
    end
    return ns.LeaderboardTabs[1]
end

local function SelectDrawerTab(tabId)
    activeDrawerTab = tabId
    for id, btn in pairs(DrawerTabButtons) do
        local isSelected = (id == tabId)
        btn.isPrimary = isSelected
        btn.customCol = isSelected and COLORS.purpleBtn or COLORS.bgInput
        ns.StyleBox(btn, btn.customCol, isSelected and COLORS.purpleBright or COLORS.border)
    end
    ns.RefreshClanDrawer()
end

function ns.RefreshClanDrawer()
    if not ClanDrawer or not ClanDrawer:IsShown() or not ns.db then return end
    local db = ns.db
    local inValidGuild = ns.VerifyAndSyncGuildState()
    local tabInfo = GetDrawerTabInfo(activeDrawerTab)

    LbTitleText:SetText(tabInfo.title)
    ClanWinsTitleText:SetText(tabInfo.feedTitle)

    if not inValidGuild then
        ClanHeaderSubText:SetText("|cffe63946No Guild Detected|r")
        for i = 1, TOP_N do LeaderboardRows[i]:Hide() end
        for i = 1, TOP_N do ClanFeedRows[i]:Hide() end
        return
    end

    ClanHeaderSubText:SetText("|cff9d4edd<" .. (db.guildName or "Guild") .. ">|r")
    local myDisplay = ns.GetMyFormattedName()

    if activeDrawerTab == "OVERALL" then
        -- Section A: Top 5 Real-Time Current Balance
        local liveBoard = db.clanRecords and db.clanRecords.LIVE or {}
        local liveSorted = {}
        for playerName, rec in pairs(liveBoard) do
            if type(rec) == "table" and rec.val ~= nil then
                table.insert(liveSorted, {
                    name = ns.FormatPlayerName(playerName),
                    val  = rec.val or 0,
                })
            end
        end
        table.sort(liveSorted, function(a, b)
            if a.val == b.val then return a.name < b.name end
            return a.val > b.val
        end)

        for i = 1, TOP_N do
            local row = LeaderboardRows[i]
            local item = liveSorted[i]
            if item then
                row:Show()
                local nameColor = (item.name == myDisplay) and "|cffffffff" or "|cffd8b4fe"
                row.left:SetText(string.format("|cff888899#%d|r %s%s|r", i, nameColor, item.name))
                row.right:SetText(string.format("|cffb57edcC|r |cffffffff%.2f|r", item.val))
            else
                row:Hide()
            end
        end

        -- Section B: Top 5 All-Time Peak Credits
        local peakBoard = db.clanRecords and db.clanRecords.PEAK or {}
        local peakSorted = {}
        for playerName, rec in pairs(peakBoard) do
            if type(rec) == "table" and (rec.val or 0) > 0 then
                table.insert(peakSorted, {
                    name = ns.FormatPlayerName(playerName),
                    val  = rec.val or 0,
                })
            end
        end
        table.sort(peakSorted, function(a, b)
            if a.val == b.val then return a.name < b.name end
            return a.val > b.val
        end)

        for i = 1, TOP_N do
            local row = ClanFeedRows[i]
            local item = peakSorted[i]
            if item then
                row:Show()
                local nameColor = (item.name == myDisplay) and "|cffffffff" or "|cffd8b4fe"
                row.left:SetText(string.format("|cff888899#%d|r %s%s|r", i, nameColor, item.name))
                row.right:SetText(string.format("|cffd8b4feC %.2f|r", item.val))
            else
                row:Hide()
            end
        end
    else
        -- Section A: Per-Game Top 5 Leaderboard
        local board = db.clanRecords and db.clanRecords[activeDrawerTab] or {}
        local sorted = {}
        for playerName, rec in pairs(board) do
            if type(rec) == "table" and ((rec.mult or 0) > 0 or (rec.payout or 0) > 0) then
                table.insert(sorted, {
                    name   = ns.FormatPlayerName(playerName),
                    mult   = rec.mult or 0,
                    payout = rec.payout or 0,
                })
            end
        end
        table.sort(sorted, function(a, b)
            if activeDrawerTab == "CRASH" then
                if a.mult == b.mult then return a.payout > b.payout end
                return a.mult > b.mult
            else
                if a.payout == b.payout then return a.mult > b.mult end
                return a.payout > b.payout
            end
        end)

        for i = 1, TOP_N do
            local row = LeaderboardRows[i]
            local item = sorted[i]
            if item then
                row:Show()
                local nameColor = (item.name == myDisplay) and "|cffffffff" or "|cffd8b4fe"
                row.left:SetText(string.format("|cff888899#%d|r %s%s|r", i, nameColor, item.name))
                if activeDrawerTab == "CRASH" then
                    row.right:SetText(string.format("|cff9d4edd%.2fx|r |cff888899(+%.0f)|r", item.mult, item.payout))
                else
                    row.right:SetText(string.format("|cff9d4edd+%.0f|r |cff888899(%.2fx)|r", item.payout, item.mult))
                end
            else
                row:Hide()
            end
        end

        -- Section B: Recent Guild Wins for the Selected Game
        local filteredWins = {}
        for _, win in ipairs(db.clanFeed) do
            local winGameId = ns.NormalizeGameId(win.game)
            if winGameId == activeDrawerTab then
                table.insert(filteredWins, win)
                if #filteredWins >= TOP_N then break end
            end
        end

        for i = 1, TOP_N do
            local row = ClanFeedRows[i]
            local win = filteredWins[i]
            if win then
                row:Show()
                local dispName = ns.FormatPlayerName(win.player)
                local nameColor = (dispName == myDisplay) and "|cffffffff" or "|cffd8b4fe"
                row.left:SetText(string.format("%s%s|r |cff888899@%.2fx|r", nameColor, dispName, win.mult))
                row.right:SetText(string.format("|cff9d4edd+%.2f|r", win.profit))
            else
                row:Hide()
            end
        end
    end
end

function ns.RefreshHub()
    if not MainFrame or not ns.db then return end
    local db = ns.db
    ns.CheckBankrollRefill()

    BalanceText:SetText("|cffb57edcC|r " .. ns.FormatCredits(db.credits))

    local p = db.netProfit or 0
    local peak = db.peakBalance or db.credits or ns.STARTING_CREDITS
    local peakStr = string.format("|cffd8b4fe%.2f|r", peak)

    if p >= 0 then
        ProfitText:SetText(string.format("P/L: |cff9d4edd+%.2f|r (W:%d/L:%d)  |  Peak: %s", p, db.wins or 0, db.losses or 0, peakStr))
    else
        ProfitText:SetText(string.format("P/L: |cffe63946%.2f|r (W:%d/L:%d)  |  Peak: %s", p, db.wins or 0, db.losses or 0, peakStr))
    end

    if db.emptyTimestamp and db.emptyTimestamp > 0 and db.credits < 0.01 and not ns.HasActiveWager() then
        local rem = ns.REFILL_COOLDOWN - (GetServerTime() - db.emptyTimestamp)
        LockoutText:SetText("|cffe63946Refill in " .. ns.FormatClock(rem) .. "|r")
    else
        LockoutText:SetText("|cff888899Refill: Auto @ 0.00 (1h)|r")
    end

    -- Shared Bottom Round Log (Always "First L.")
    local myDisplay = ns.GetMyFormattedName()
    for i = 1, 5 do
        local row = AllBetRows[i]
        local entry = db.betLog[i]
        if entry then
            row:Show()
            local formattedName = entry.isSelf and myDisplay or ns.FormatPlayerName(entry.player or myDisplay)
            local isMe = entry.isSelf or (formattedName == myDisplay)
            local nameCol = isMe and "|cffffffff" or "|cffd8b4fe"
            local gameTag = "|cff9d4edd[" .. (entry.tag or ns.GetGameTag(entry.game)) .. "]|r "
            local clanTag = isMe and "" or " |cff7b2cbf[Clan]|r"
            row.player:SetText(string.format("%s%s%s|r%s   |cffb57edcC|r %.2f", gameTag, nameCol, formattedName, clanTag, entry.bet))
            row.hash:SetText("|cff555566" .. (entry.hash or "") .. "|r")
            if entry.won then
                row.bgTex:SetColorTexture(0.16, 0.10, 0.25, 0.75)
                row.outcome:SetText(string.format("|cffd8b4fe%.2fx   +%.2f|r", entry.mult, entry.profit))
            else
                row.bgTex:SetColorTexture(0.24, 0.08, 0.12, 0.65)
                row.outcome:SetText(string.format("|cffe63946@%.2fx   -%.2f|r", entry.mult, entry.bet))
            end
        else
            row:Hide()
        end
    end

    local curMod = activeGameId and ns.Games[activeGameId]
    if curMod and curMod.Refresh then
        curMod:Refresh()
    end

    if ClanDrawer and ClanDrawer:IsShown() then
        ns.RefreshClanDrawer()
    end
end

local function CreatePlaceholderView(parent, label)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()
    ns.StyleBox(f, COLORS.bgPanel, COLORS.border)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("CENTER", 0, 14)
    title:SetText("|cff9d4edd" .. string.upper(label) .. "|r")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -8)
    sub:SetText("|cff888899Module slot ready — coming soon.|r")

    f:Hide()
    return f
end

function ns.SelectGame(gameId)
    if activeGameId == gameId then return end

    if activeGameId then
        local oldMod = ns.Games[activeGameId]
        if oldMod and oldMod.IsBusy and oldMod:IsBusy() then
            DEFAULT_CHAT_FRAME:AddMessage("|cffe63946[VoidCasino]|r Finish or cancel your active bet before switching games.")
            return
        end
        if oldMod and oldMod.OnHide then
            oldMod:OnHide()
        end
        if MountedFrames[activeGameId] then
            MountedFrames[activeGameId]:Hide()
        end
    end

    activeGameId = gameId

    for id, btn in pairs(NavButtons) do
        local isSelected = (id == gameId)
        btn.isPrimary = isSelected
        btn.customCol = isSelected and COLORS.purpleBtn or COLORS.bgInput
        ns.StyleBox(btn, btn.customCol, isSelected and COLORS.purpleBright or COLORS.border)
    end

    if MountedFrames[gameId] then
        MountedFrames[gameId]:Show()
    end

    local newMod = ns.Games[gameId]
    if newMod and newMod.OnShow then
        newMod:OnShow()
    else
        ns.SetHashText("Module Status: Standby")
    end

    ns.RefreshHub()
end

function ns.BuildHub()
    MainFrame = CreateFrame("Frame", "VoidCasinoMainFrame", UIParent)
    MainFrame:SetSize(820, 600)
    MainFrame:SetPoint("CENTER")
    MainFrame:SetMovable(true)
    MainFrame:EnableMouse(true)
    MainFrame:RegisterForDrag("LeftButton")
    MainFrame:SetScript("OnDragStart", MainFrame.StartMoving)
    MainFrame:SetScript("OnDragStop", MainFrame.StopMovingOrSizing)
    ns.StyleBox(MainFrame, COLORS.bgMain, COLORS.border)
    MainFrame:Hide()

    -- 1. Top Header Bar
    local Header = CreateFrame("Frame", nil, MainFrame)
    Header:SetPoint("TOPLEFT", 1, -1)
    Header:SetPoint("TOPRIGHT", -1, -1)
    Header:SetHeight(42)
    ns.StyleBox(Header, COLORS.bgPanel, COLORS.border)

    local Title = Header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    Title:SetPoint("LEFT", 16, 0)
    Title:SetText("|cffffffffVOID|r|cff9d4eddCASINO|r")

    ProfitText = Header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ProfitText:SetPoint("LEFT", Title, "RIGHT", 16, 0)

    local CloseBtn = ns.CreateCustomButton(Header, 26, 24, "X", false)
    CloseBtn:SetPoint("RIGHT", -10, 0)
    CloseBtn:SetScript("OnClick", function() MainFrame:Hide() end)

    local ClanBtn = ns.CreateCustomButton(Header, 56, 24, "Guild", true)
    ClanBtn:SetPoint("RIGHT", CloseBtn, "LEFT", -6, 0)

    local BalBox = CreateFrame("Frame", nil, Header)
    BalBox:SetSize(136, 26)
    BalBox:SetPoint("RIGHT", ClanBtn, "LEFT", -8, 0)
    ns.StyleBox(BalBox, COLORS.bgInput, COLORS.purpleBright)

    BalanceText = BalBox:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    BalanceText:SetPoint("CENTER", 0, 0)

    LockoutText = Header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    LockoutText:SetPoint("RIGHT", BalBox, "LEFT", -10, 0)

    -- 2. Game Switcher Navigation Bar
    local NavBar = CreateFrame("Frame", nil, MainFrame)
    NavBar:SetPoint("TOPLEFT", 12, -50)
    NavBar:SetPoint("TOPRIGHT", -12, -50)
    NavBar:SetHeight(30)

    local numGames = #ns.GameOrder
    local gap = 8
    local tabWidth = math.floor((796 - (gap * (numGames - 1))) / numGames)

    for i, info in ipairs(ns.GameOrder) do
        local btn = ns.CreateCustomButton(NavBar, tabWidth, 28, info.label, false)
        btn:SetPoint("LEFT", (i - 1) * (tabWidth + gap), 0)
        btn:SetScript("OnClick", function()
            ns.SelectGame(info.id)
        end)
        NavButtons[info.id] = btn
    end

    -- 3. Center Game Stage Container (340px tall)
    GameStage = CreateFrame("Frame", "VoidCasinoGameStage", MainFrame)
    GameStage:SetPoint("TOPLEFT", 12, -88)
    GameStage:SetPoint("TOPRIGHT", -12, -88)
    GameStage:SetHeight(340)

    for _, info in ipairs(ns.GameOrder) do
        local mod = ns.Games[info.id]
        if mod and mod.Build then
            local frame = mod:Build(GameStage)
            frame:Hide()
            MountedFrames[info.id] = frame
        else
            MountedFrames[info.id] = CreatePlaceholderView(GameStage, info.label)
        end
    end

    -- 4. Bottom Shared Round Log Panel
    local BottomPanel = CreateFrame("Frame", nil, MainFrame)
    BottomPanel:SetPoint("TOPLEFT", GameStage, "BOTTOMLEFT", 0, -10)
    BottomPanel:SetPoint("BOTTOMRIGHT", -12, 12)
    ns.StyleBox(BottomPanel, COLORS.bgPanel, COLORS.border)

    local FeedTitle = BottomPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    FeedTitle:SetPoint("TOPLEFT", 12, -8)
    FeedTitle:SetText("Casino Round Log & Guild Live Feed")
    FeedTitle:SetTextColor(unpack(COLORS.textMuted))

    HashText = BottomPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    HashText:SetPoint("TOPRIGHT", -12, -8)
    HashText:SetTextColor(0.45, 0.45, 0.55, 1)
    HashText:SetText("Round SHA-Seed: Initializing...")

    for i = 1, 5 do
        local row = CreateFrame("Frame", nil, BottomPanel)
        row:SetPoint("TOPLEFT", 10, -26 - (i - 1) * 23)
        row:SetPoint("TOPRIGHT", -10, -26 - (i - 1) * 23)
        row:SetHeight(20)
        ns.StyleBox(row, COLORS.bgInput, nil)

        row.player = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.player:SetPoint("LEFT", 10, 0)

        row.hash = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.hash:SetPoint("CENTER", 0, 0)

        row.outcome = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.outcome:SetPoint("RIGHT", -10, 0)

        row:Hide()
        AllBetRows[i] = row
    end

    -- 5. Pop-Out Guild Leaderboard & Per-Game Filter Side Drawer
    ClanDrawer = CreateFrame("Frame", "VoidCasinoClanDrawer", MainFrame)
    ClanDrawer:SetSize(250, 600)
    ClanDrawer:SetPoint("TOPLEFT", MainFrame, "TOPRIGHT", 6, 0)
    ns.StyleBox(ClanDrawer, COLORS.bgMain, COLORS.border)
    ClanDrawer:Hide()

    local DrawerHeader = CreateFrame("Frame", nil, ClanDrawer)
    DrawerHeader:SetPoint("TOPLEFT", 1, -1)
    DrawerHeader:SetPoint("TOPRIGHT", -1, -1)
    DrawerHeader:SetHeight(42)
    ns.StyleBox(DrawerHeader, COLORS.bgPanel, COLORS.border)

    local DrawerTitle = DrawerHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    DrawerTitle:SetPoint("TOPLEFT", 12, -8)
    DrawerTitle:SetText("|cffffffffGUILD|r |cff9d4eddLEADERBOARD|r")

    ClanHeaderSubText = DrawerHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ClanHeaderSubText:SetPoint("BOTTOMLEFT", 12, 6)
    ClanHeaderSubText:SetText("|cff888899Syncing...|r")

    local SyncBtn = ns.CreateCustomButton(DrawerHeader, 46, 22, "Sync", false)
    SyncBtn:SetPoint("RIGHT", -36, 0)
    SyncBtn:SetScript("OnClick", function()
        ns.RequestGuildLeaderboardSync()
        ns.RefreshClanDrawer()
    end)

    local DrawerClose = ns.CreateCustomButton(DrawerHeader, 22, 22, "X", false)
    DrawerClose:SetPoint("RIGHT", -8, 0)
    DrawerClose:SetScript("OnClick", function() ClanDrawer:Hide() end)

    -- Drawer Category Tabs: Hub | Crash | BJ | Roul | Poker
    local DrawerTabBar = CreateFrame("Frame", nil, ClanDrawer)
    DrawerTabBar:SetPoint("TOPLEFT", 10, -48)
    DrawerTabBar:SetPoint("TOPRIGHT", -10, -48)
    DrawerTabBar:SetHeight(24)

    local dGap = 3
    local dTabW = math.floor((230 - (dGap * (#ns.LeaderboardTabs - 1))) / #ns.LeaderboardTabs)
    for i, tab in ipairs(ns.LeaderboardTabs) do
        local btn = ns.CreateCustomButton(DrawerTabBar, dTabW, 22, tab.short, false)
        btn.label:SetFontObject("GameFontHighlightSmall")
        btn:SetPoint("LEFT", (i - 1) * (dTabW + dGap), 0)
        btn:SetScript("OnClick", function()
            SelectDrawerTab(tab.id)
        end)
        DrawerTabButtons[tab.id] = btn
    end

    -- Section A: Top 5 Live Balance (Hub) or Per-Game Leaderboard
    local LbPanel = CreateFrame("Frame", nil, ClanDrawer)
    LbPanel:SetPoint("TOPLEFT", 10, -78)
    LbPanel:SetPoint("TOPRIGHT", -10, -78)
    LbPanel:SetHeight(245)
    ns.StyleBox(LbPanel, COLORS.bgPanel, COLORS.border)

    LbTitleText = LbPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    LbTitleText:SetPoint("TOPLEFT", 10, -10)
    LbTitleText:SetText("Top 5 — Current Balance")
    LbTitleText:SetTextColor(unpack(COLORS.textMuted))

    for i = 1, TOP_N do
        local row = CreateFrame("Frame", nil, LbPanel)
        row:SetPoint("TOPLEFT", 8, -32 - (i - 1) * 41)
        row:SetPoint("TOPRIGHT", -8, -32 - (i - 1) * 41)
        row:SetHeight(34)
        ns.StyleBox(row, COLORS.bgInput, COLORS.border)

        row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.left:SetPoint("LEFT", 8, 0)

        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.right:SetPoint("RIGHT", -8, 0)

        row:Hide()
        LeaderboardRows[i] = row
    end

    -- Section B: Top 5 All-Time Peak Credits (Hub) or Recent Game Wins
    local FeedPanel = CreateFrame("Frame", nil, ClanDrawer)
    FeedPanel:SetPoint("TOPLEFT", LbPanel, "BOTTOMLEFT", 0, -10)
    FeedPanel:SetPoint("BOTTOMRIGHT", -10, 12)
    ns.StyleBox(FeedPanel, COLORS.bgPanel, COLORS.border)

    ClanWinsTitleText = FeedPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ClanWinsTitleText:SetPoint("TOPLEFT", 10, -10)
    ClanWinsTitleText:SetText("Top 5 — All-Time Peak Credits")
    ClanWinsTitleText:SetTextColor(unpack(COLORS.textMuted))

    for i = 1, TOP_N do
        local row = CreateFrame("Frame", nil, FeedPanel)
        row:SetPoint("TOPLEFT", 8, -32 - (i - 1) * 42)
        row:SetPoint("TOPRIGHT", -8, -32 - (i - 1) * 42)
        row:SetHeight(34)
        ns.StyleBox(row, COLORS.purpleDim, nil)

        row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.left:SetPoint("LEFT", 8, 0)

        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.right:SetPoint("RIGHT", -8, 0)

        row:Hide()
        ClanFeedRows[i] = row
    end

    ClanBtn:SetScript("OnClick", function()
        if ClanDrawer:IsShown() then
            ClanDrawer:Hide()
        else
            ns.VerifyAndSyncGuildState()
            ClanDrawer:Show()
            ns.RequestGuildLeaderboardSync()
            SelectDrawerTab(activeDrawerTab)
        end
    end)

    -- 1-second background ticker for bankroll refill countdown
    MainFrame:SetScript("OnUpdate", function(self, elapsed)
        hubTickAccumulator = hubTickAccumulator + elapsed
        if hubTickAccumulator >= 1.0 then
            hubTickAccumulator = 0
            ns.CheckBankrollRefill()
            ns.RefreshHub()
        end
    end)

    -- Default to Crash tab on main stage & Hub tab in Guild Drawer
    SelectDrawerTab("OVERALL")
    ns.SelectGame("CRASH")
end

-- Slash Commands: /casino, /voidcasino, /crash, /voidcrash
SLASH_VOIDCASINO1 = "/casino"
SLASH_VOIDCASINO2 = "/voidcasino"
SLASH_VOIDCASINO3 = "/crash"
SLASH_VOIDCASINO4 = "/voidcrash"
SlashCmdList["VOIDCASINO"] = function()
    if not MainFrame then return end
    if MainFrame:IsShown() then
        MainFrame:Hide()
    else
        ns.CheckBankrollRefill()
        if ns.VerifyAndSyncGuildState() then
            ns.RequestGuildLeaderboardSync()
        end
        ns.RefreshHub()
        MainFrame:Show()
    end
end