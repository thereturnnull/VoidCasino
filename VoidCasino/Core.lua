-- ============================================================================
-- VoidCasino - Core.lua
-- Shared Palette, UI Primitives, PRNG, Unified Bankroll & Real-Time Guild Sync
-- ============================================================================

local ADDON_NAME, ns = ...
ns.ADDON_NAME = ADDON_NAME
ns.ADDON_PREFIX = "VOIDCASINO"

local EventFrame = CreateFrame("Frame", "VoidCasinoEventFrame", UIParent)

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(ns.ADDON_PREFIX)
end

-- Palette: Deep Obsidian, Dark Slate, and Neon Purple
ns.COLORS = {
    bgMain       = {0.05, 0.05, 0.07, 0.97},
    bgPanel      = {0.08, 0.08, 0.11, 1.00},
    bgInput      = {0.04, 0.04, 0.06, 1.00},
    border       = {0.16, 0.15, 0.22, 1.00},
    purpleBright = {0.62, 0.31, 0.87, 1.00}, -- #9D4EDD
    purpleBtn    = {0.48, 0.17, 0.75, 1.00}, -- #7B2CBF
    purpleHover  = {0.68, 0.39, 0.93, 1.00},
    purpleDim    = {0.24, 0.12, 0.38, 0.65},
    crashRed     = {0.92, 0.24, 0.32, 1.00},
    crashRedDim  = {0.35, 0.09, 0.13, 0.55},
    textLight    = {0.95, 0.95, 0.98, 1.00},
    textMuted    = {0.55, 0.54, 0.65, 1.00},
}

-- Unified Bankroll Constants
ns.STARTING_CREDITS = 1000
ns.REFILL_COOLDOWN  = 3600 -- 1 hour (3600 seconds) when balance hits 0

-- Game Module Registry & Leaderboard Definitions
ns.GameOrder = {
    { id = "CRASH",     label = "Crash",       tag = "Crash" },
    { id = "BLACKJACK", label = "Blackjack",   tag = "BJ" },
    { id = "ROULETTE",  label = "Roulette",    tag = "Roul" },
    { id = "POKER",     label = "Video Poker", tag = "Poker" },
}

ns.LeaderboardTabs = {
    { id = "OVERALL",   short = "Hub",   title = "Top 5 — Current Balance",     feedTitle = "Top 5 — All-Time Peak Credits" },
    { id = "CRASH",     short = "Crash", title = "Crash — Highest Cashout",     feedTitle = "Recent Crash Wins" },
    { id = "BLACKJACK", short = "BJ",    title = "Blackjack — Biggest Win",     feedTitle = "Recent Blackjack Wins" },
    { id = "ROULETTE",  short = "Roul",  title = "Roulette — Biggest Spin Win", feedTitle = "Recent Roulette Wins" },
    { id = "POKER",     short = "Poker", title = "Video Poker — Biggest Win",   feedTitle = "Recent Video Poker Wins" },
}

ns.Games = {}

function ns.RegisterGame(id, moduleTable)
    ns.Games[id] = moduleTable
end

function ns.NormalizeGameId(raw)
    if not raw then return "CRASH" end
    local up = string.upper(tostring(raw))
    if up == "CRASH" then return "CRASH" end
    if up == "BJ" or up == "BLACKJACK" then return "BLACKJACK" end
    if up == "ROUL" or up == "ROULETTE" then return "ROULETTE" end
    if up == "POKER" or up == "VIDEO POKER" then return "POKER" end
    return "CRASH"
end

function ns.GetGameTag(gameId)
    local norm = ns.NormalizeGameId(gameId)
    for _, info in ipairs(ns.GameOrder) do
        if info.id == norm then return info.tag end
    end
    return "Crash"
end

local function CreateEmptyClanRecords()
    return {
        LIVE      = {},
        PEAK      = {},
        CRASH     = {},
        BLACKJACK = {},
        ROULETTE  = {},
        POKER     = {},
    }
end

local function CreateEmptyGameRecords()
    return {
        CRASH     = { mult = 0, payout = 0 },
        BLACKJACK = { mult = 0, payout = 0 },
        ROULETTE  = { mult = 0, payout = 0 },
        POKER     = { mult = 0, payout = 0 },
    }
end

local function EnsureRecordTables(targetDb)
    if type(targetDb.gameRecords) ~= "table" then
        targetDb.gameRecords = CreateEmptyGameRecords()
    end
    for _, info in ipairs(ns.GameOrder) do
        if type(targetDb.gameRecords[info.id]) ~= "table" then
            targetDb.gameRecords[info.id] = { mult = 0, payout = 0 }
        end
    end

    if type(targetDb.clanRecords) ~= "table" then
        targetDb.clanRecords = CreateEmptyClanRecords()
    else
        -- Migrate previous OVERALL peak table into PEAK if present
        if type(targetDb.clanRecords.OVERALL) == "table" and type(targetDb.clanRecords.PEAK) ~= "table" then
            targetDb.clanRecords.PEAK = targetDb.clanRecords.OVERALL
            targetDb.clanRecords.OVERALL = nil
        end
        targetDb.clanRecords.LIVE      = type(targetDb.clanRecords.LIVE) == "table" and targetDb.clanRecords.LIVE or {}
        targetDb.clanRecords.PEAK      = type(targetDb.clanRecords.PEAK) == "table" and targetDb.clanRecords.PEAK or {}
        targetDb.clanRecords.CRASH     = type(targetDb.clanRecords.CRASH) == "table" and targetDb.clanRecords.CRASH or {}
        targetDb.clanRecords.BLACKJACK = type(targetDb.clanRecords.BLACKJACK) == "table" and targetDb.clanRecords.BLACKJACK or {}
        targetDb.clanRecords.ROULETTE  = type(targetDb.clanRecords.ROULETTE) == "table" and targetDb.clanRecords.ROULETTE or {}
        targetDb.clanRecords.POKER     = type(targetDb.clanRecords.POKER) == "table" and targetDb.clanRecords.POKER or {}
    end
end

-- Compares whether incoming (mult, payout) beats existing record for a specific game
local function IsBetterGameRecord(gameId, newMult, newPay, existing)
    if not existing then return true end
    local oldMult = existing.mult or 0
    local oldPay  = existing.payout or 0
    if gameId == "CRASH" then
        if newMult ~= oldMult then return newMult > oldMult end
        return newPay > oldPay
    else
        if newPay ~= oldPay then return newPay > oldPay end
        return newMult > oldMult
    end
end

-- Guild Roster & Anti-Echo Caches
local guildRosterCache = {}
local guildFormattedNameMap = {}
local sentRoundHashes = {}
local lastSyncRequestTime = 0

-- ============================================================================
-- Deterministic 32-Bit PRNG & Hash Mixer (Pure Lua 5.1)
-- ============================================================================
local prngState = 1337

function ns.MixSeed(seedVal)
    local s = math.floor(math.abs(seedVal)) % 2147483647
    if s == 0 then s = 987654321 end
    s = (s * 48271) % 2147483647
    return s
end

function ns.NextRandomFloat()
    prngState = ns.MixSeed(prngState + math.floor(GetTime() * 1000))
    return (prngState % 1000000) / 1000000
end

function ns.GenerateRoundHash(salt)
    local h1 = ns.MixSeed(prngState * 31 + math.floor((salt or 1) * 100))
    local h2 = ns.MixSeed(h1 * 17 + GetServerTime())
    local h3 = ns.MixSeed(h2 * 13 + prngState)
    local h4 = ns.MixSeed(h3 * 29 + 7919)
    return string.format("%08x%08x%08x%08x", h1, h2, h3, h4)
end

-- ============================================================================
-- Formatting & Player Name Helpers ("First L." Format)
-- ============================================================================
function ns.FormatCredits(amount)
    return string.format("%.2f", amount or 0)
end

function ns.FormatClock(seconds)
    if seconds <= 0 then return "00:00" end
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d", m, s)
end

function ns.StripRealm(fullName)
    if not fullName or fullName == "" then return "Unknown" end

    local realm = GetRealmName and GetRealmName()
    if realm and realm ~= "" then
        local escaped = string.gsub(realm, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        local stripped = string.match(fullName, "^(.-)%-" .. escaped .. "$")
        if stripped then return stripped end
    end

    local normRealm = GetNormalizedRealmName and GetNormalizedRealmName()
    if normRealm and normRealm ~= "" then
        local escaped = string.gsub(normRealm, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        local stripped = string.match(fullName, "^(.-)%-" .. escaped .. "$")
        if stripped then return stripped end
    end

    return string.match(fullName, "^(.-)%-[^%-]+$") or fullName
end

function ns.IsSelfSender(sender)
    if not sender or sender == "" then return false end
    local myName = UnitName("player") or ""
    if myName == "" then return false end

    local strippedSender = string.lower(ns.StripRealm(sender))
    local shortSender    = string.lower(Ambiguate and Ambiguate(sender, "short") or strippedSender)
    local myLower        = string.lower(ns.StripRealm(myName))

    if strippedSender == myLower or shortSender == myLower then
        return true
    end
    if UnitIsUnit and (UnitIsUnit(sender, "player") or UnitIsUnit(strippedSender, "player")) then
        return true
    end
    return false
end

function ns.FormatPlayerName(rawName, optionalSurname)
    if not rawName or rawName == "" then return "Unknown" end
    local clean = ns.StripRealm(rawName)

    if string.match(clean, "^%S+%s+%a%.$") then
        local f, l = string.match(clean, "^(%S+)%s+(%a)%.$")
        f = string.upper(string.sub(f, 1, 1)) .. string.lower(string.sub(f, 2))
        return f .. " " .. string.upper(l) .. "."
    end

    if optionalSurname and optionalSurname ~= "" then
        local f = string.upper(string.sub(clean, 1, 1)) .. string.lower(string.sub(clean, 2))
        local l = string.upper(string.sub(optionalSurname, 1, 1))
        return f .. " " .. l .. "."
    end

    local first, last = string.match(clean, "^(%S+)[%s_]+(%S+)")
    if first and last and #last >= 1 then
        first = string.upper(string.sub(first, 1, 1)) .. string.lower(string.sub(first, 2))
        return first .. " " .. string.upper(string.sub(last, 1, 1)) .. "."
    end

    local camelFirst, camelLast = string.match(clean, "^(%u%l+)(%u%l*)$")
    if camelFirst and camelLast then
        return camelFirst .. " " .. string.sub(camelLast, 1, 1) .. "."
    end

    if guildFormattedNameMap[clean] then
        return guildFormattedNameMap[clean]
    end

    return string.upper(string.sub(clean, 1, 1)) .. string.sub(clean, 2)
end

function ns.GetMyFormattedName()
    local baseName = UnitName("player") or "Player"
    if string.find(baseName, "[%s_]") then
        return ns.FormatPlayerName(baseName)
    end
    if guildFormattedNameMap[baseName] then
        return guildFormattedNameMap[baseName]
    end
    if UnitPVPName then
        local pvpName = UnitPVPName("player")
        if pvpName and string.find(pvpName, "^" .. baseName .. "%s+%S+") then
            return ns.FormatPlayerName(pvpName)
        end
    end
    return ns.FormatPlayerName(baseName)
end

-- ============================================================================
-- Shared UI Primitives (Zero BackdropTemplate Taint)
-- ============================================================================
function ns.StyleBox(frame, bgCol, borderCol)
    if not frame.bgTex then
        frame.bgTex = frame:CreateTexture(nil, "BACKGROUND")
        frame.bgTex:SetAllPoints()
    end
    frame.bgTex:SetColorTexture(bgCol[1], bgCol[2], bgCol[3], bgCol[4] or 1)

    if borderCol then
        if not frame.borders then
            frame.borders = {}
            for i = 1, 4 do
                frame.borders[i] = frame:CreateTexture(nil, "BORDER")
            end
        end
        local b = frame.borders
        b[1]:SetPoint("TOPLEFT", 0, 0); b[1]:SetPoint("TOPRIGHT", 0, 0); b[1]:SetHeight(1)
        b[2]:SetPoint("BOTTOMLEFT", 0, 0); b[2]:SetPoint("BOTTOMRIGHT", 0, 0); b[2]:SetHeight(1)
        b[3]:SetPoint("TOPLEFT", 0, 0); b[3]:SetPoint("BOTTOMLEFT", 0, 0); b[3]:SetWidth(1)
        b[4]:SetPoint("TOPRIGHT", 0, 0); b[4]:SetPoint("BOTTOMRIGHT", 0, 0); b[4]:SetWidth(1)
        for i = 1, 4 do
            b[i]:SetColorTexture(borderCol[1], borderCol[2], borderCol[3], borderCol[4] or 1)
        end
    end
end

function ns.CreateCustomButton(parent, width, height, label, isPrimary)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width, height)
    local baseCol = isPrimary and ns.COLORS.purpleBtn or ns.COLORS.bgInput
    local brdCol  = isPrimary and ns.COLORS.purpleBright or ns.COLORS.border
    ns.StyleBox(btn, baseCol, brdCol)

    btn.isPrimary = isPrimary
    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    btn.label:SetPoint("CENTER")
    btn.label:SetText(label)
    btn.label:SetTextColor(unpack(ns.COLORS.textLight))

    btn:SetScript("OnEnter", function(self)
        if self.isPrimary then
            self.bgTex:SetColorTexture(unpack(ns.COLORS.purpleHover))
        else
            self.bgTex:SetColorTexture(0.14, 0.13, 0.20, 1)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if self.isPrimary then
            self.bgTex:SetColorTexture(unpack(self.customCol or ns.COLORS.purpleBtn))
        else
            self.bgTex:SetColorTexture(unpack(self.customCol or ns.COLORS.bgInput))
        end
    end)
    return btn
end

function ns.CreateToggleSwitch(parent, labelText, onToggle)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(206, 26)

    local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", 0, 0)
    lbl:SetText(labelText)
    lbl:SetTextColor(unpack(ns.COLORS.textMuted))

    local sw = CreateFrame("Button", nil, container)
    sw:SetSize(40, 20)
    sw:SetPoint("RIGHT", 0, 0)
    ns.StyleBox(sw, ns.COLORS.bgInput, ns.COLORS.border)

    local knob = sw:CreateTexture(nil, "ARTWORK")
    knob:SetSize(14, 14)
    knob:SetPoint("LEFT", 3, 0)
    knob:SetColorTexture(0.45, 0.45, 0.52, 1)

    sw.state = false
    local function UpdateVisual()
        if sw.state then
            sw.bgTex:SetColorTexture(unpack(ns.COLORS.purpleBtn))
            knob:ClearAllPoints()
            knob:SetPoint("RIGHT", -3, 0)
            knob:SetColorTexture(1, 1, 1, 1)
        else
            sw.bgTex:SetColorTexture(unpack(ns.COLORS.bgInput))
            knob:ClearAllPoints()
            knob:SetPoint("LEFT", 3, 0)
            knob:SetColorTexture(0.45, 0.45, 0.52, 1)
        end
    end

    sw:SetScript("OnClick", function()
        sw.state = not sw.state
        UpdateVisual()
        if onToggle then onToggle(sw.state) end
    end)

    return container, sw
end

-- ============================================================================
-- Guild Verification, Roster Cache & Real-Time Sync Packets
-- ============================================================================
function ns.RefreshGuildRosterCache()
    guildRosterCache = {}
    guildFormattedNameMap = {}
    if not IsInGuild or not IsInGuild() then return end
    local numTotal = GetNumGuildMembers and GetNumGuildMembers() or 0
    for i = 1, numTotal do
        local name, _, _, _, _, _, publicNote = GetGuildRosterInfo(i)
        if name then
            local stripped = ns.StripRealm(name)
            local shortKey = Ambiguate and Ambiguate(name, "short") or stripped
            guildRosterCache[shortKey] = true
            guildRosterCache[stripped] = true

            if string.find(stripped, "[%s_]") then
                guildFormattedNameMap[shortKey] = ns.FormatPlayerName(stripped)
            elseif publicNote and string.match(publicNote, "^%a+$") then
                guildFormattedNameMap[shortKey] = ns.FormatPlayerName(stripped, publicNote)
            else
                guildFormattedNameMap[shortKey] = ns.FormatPlayerName(stripped)
            end
        end
    end
    local rawSelf = UnitName("player")
    if rawSelf then
        guildRosterCache[ns.StripRealm(rawSelf)] = true
    end
end

function ns.VerifyAndSyncGuildState()
    local db = ns.db
    if not db then return false end
    EnsureRecordTables(db)

    if not IsInGuild or not IsInGuild() then
        if db.guildName ~= "" then
            db.guildName = ""
            db.clanRecords = CreateEmptyClanRecords()
            db.clanFeed = {}
        end
        return false
    end

    local currentGuild = GetGuildInfo("player")
    if not currentGuild or currentGuild == "" then
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        end
        return false
    end

    ns.RefreshGuildRosterCache()
    local myDisplay = ns.GetMyFormattedName()

    if db.guildName ~= currentGuild then
        db.guildName = currentGuild
        db.clanRecords = CreateEmptyClanRecords()
        db.clanFeed = {}
        local cleanBetLog = {}
        for _, entry in ipairs(db.betLog) do
            if entry.isSelf or entry.player == myDisplay then
                entry.player = myDisplay
                table.insert(cleanBetLog, entry)
            end
        end
        db.betLog = cleanBetLog
    end

    -- Mirror local player's real-time current balance into LIVE board
    db.clanRecords.LIVE[myDisplay] = { val = db.credits or 0 }

    -- Mirror local player's all-time peak balance into PEAK board
    if (db.credits or 0) > (db.peakBalance or 0) then
        db.peakBalance = db.credits
    end
    if (db.peakBalance or 0) > 0 then
        db.clanRecords.PEAK[myDisplay] = { val = db.peakBalance }
    end

    -- Mirror local player's per-game personal bests into each game's board
    for _, info in ipairs(ns.GameOrder) do
        local rec = db.gameRecords[info.id]
        if rec and ((rec.mult or 0) > 0 or (rec.payout or 0) > 0) then
            db.clanRecords[info.id][myDisplay] = {
                mult   = rec.mult or 0,
                payout = rec.payout or 0,
            }
        end
    end

    return true
end

function ns.SendGuildPacket(payload)
    if not ns.VerifyAndSyncGuildState() then return end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(ns.ADDON_PREFIX, payload, "GUILD")
    end
end

function ns.BroadcastLiveBalance()
    local db = ns.db
    if not db then return end
    local myDisplay = ns.GetMyFormattedName()
    local msg = string.format("BAL:%.2f:%.2f:%s",
        db.credits or 0,
        db.peakBalance or db.credits or ns.STARTING_CREDITS,
        myDisplay
    )
    ns.SendGuildPacket(msg)
end

function ns.BroadcastMyBestRecords()
    local db = ns.db
    if not db then return end
    EnsureRecordTables(db)
    local myDisplay = ns.GetMyFormattedName()
    local c = db.gameRecords.CRASH
    local b = db.gameRecords.BLACKJACK
    local r = db.gameRecords.ROULETTE
    local p = db.gameRecords.POKER
    local msg = string.format(
        "SYNC_REP:%.2f:%.2f:%.2f,%.2f:%.2f,%.2f:%.2f,%.2f:%.2f,%.2f:%s",
        db.credits or 0,
        db.peakBalance or ns.STARTING_CREDITS,
        c.mult or 0, c.payout or 0,
        b.mult or 0, b.payout or 0,
        r.mult or 0, r.payout or 0,
        p.mult or 0, p.payout or 0,
        myDisplay
    )
    ns.SendGuildPacket(msg)
end

function ns.RequestGuildLeaderboardSync()
    local now = GetTime()
    if now - lastSyncRequestTime < 5.0 then return end
    lastSyncRequestTime = now
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    end
    ns.SendGuildPacket("SYNC_REQ")
    ns.BroadcastMyBestRecords()
end

-- ============================================================================
-- Unified Bankroll & Cross-Game Outcome API
-- ============================================================================
function ns.HasActiveWager()
    for _, mod in pairs(ns.Games) do
        if mod.IsBusy and mod:IsBusy() then
            return true
        end
    end
    return false
end

function ns.CheckBankrollRefill()
    local db = ns.db
    if not db then return end
    local now = GetServerTime()

    if db.credits < 0.01 and not ns.HasActiveWager() then
        if not db.emptyTimestamp or db.emptyTimestamp == 0 then
            db.emptyTimestamp = now
        else
            local elapsed = now - db.emptyTimestamp
            if elapsed >= ns.REFILL_COOLDOWN then
                db.credits = ns.STARTING_CREDITS
                db.emptyTimestamp = 0
                DEFAULT_CHAT_FRAME:AddMessage("|cff9d4edd[VoidCasino]|r 1-hour lockout expired! Bankroll automatically refilled to |cffd8b4fe1,000.00|r credits.")
                ns.BroadcastLiveBalance()
            end
        end
    else
        db.emptyTimestamp = 0
    end
end

function ns.DeductCredits(amount)
    ns.CheckBankrollRefill()
    local db = ns.db
    if not db then return false, 0 end
    local req = math.floor((tonumber(amount) or 0) * 100) / 100
    if req <= 0 then return false, 0 end
    if req > db.credits then
        req = math.floor(db.credits * 100) / 100
    end
    if req < 0.01 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffe63946[VoidCasino]|r Balance is 0.00! Wait for the 1-hour auto-refill timer to restore your 1,000 credits.")
        return false, 0
    end
    db.credits = math.max(0, math.floor((db.credits - req) * 100 + 0.5) / 100)
    return true, req
end

function ns.AddCredits(amount)
    local db = ns.db
    if not db then return end
    local add = math.floor((tonumber(amount) or 0) * 100) / 100
    if add <= 0 then return end
    db.credits = math.floor((db.credits + add) * 100 + 0.5) / 100
    if db.credits > (db.peakBalance or 0) then
        db.peakBalance = db.credits
    end
end

function ns.RecordGameOutcome(gameRaw, won, betAmt, multVal, profitVal, shortHash)
    local db = ns.db
    if not db then return end
    EnsureRecordTables(db)

    local gameId = ns.NormalizeGameId(gameRaw)
    local gameTag = ns.GetGameTag(gameId)
    local playerName = ns.GetMyFormattedName()
    local hash = shortHash or string.sub(ns.GenerateRoundHash(multVal), 1, 16)
    sentRoundHashes[hash] = true

    if won then
        db.wins = (db.wins or 0) + 1
        db.netProfit = (db.netProfit or 0) + profitVal
        if db.credits > (db.peakBalance or 0) then
            db.peakBalance = db.credits
        end

        local curBest = db.gameRecords[gameId]
        if IsBetterGameRecord(gameId, multVal, profitVal, curBest) then
            db.gameRecords[gameId] = {
                mult   = multVal,
                payout = profitVal,
            }
        end
    else
        db.losses = (db.losses or 0) + 1
        db.netProfit = (db.netProfit or 0) - betAmt
    end

    local entry = {
        game   = gameId,
        tag    = gameTag,
        player = playerName,
        isSelf = true,
        bet    = betAmt,
        mult   = multVal,
        profit = profitVal,
        won    = won,
        hash   = hash,
    }

    table.insert(db.betLog, 1, entry)
    while #db.betLog > 30 do
        table.remove(db.betLog)
    end

    if ns.VerifyAndSyncGuildState() then
        local liveBal = db.credits or 0
        local peakBal = db.peakBalance or liveBal
        if won then
            table.insert(db.clanFeed, 1, {
                game   = gameId,
                tag    = gameTag,
                player = playerName,
                mult   = multVal,
                profit = profitVal,
            })
            while #db.clanFeed > 30 do
                table.remove(db.clanFeed)
            end
            local gRec = db.gameRecords[gameId]
            ns.SendGuildPacket(string.format("WIN:%s:%.2f:%.2f:%.2f:%.2f:%.2f:%.2f:%.2f:%s:%s",
                gameId, betAmt, multVal, profitVal,
                gRec.mult or multVal, gRec.payout or profitVal,
                liveBal, peakBal, hash, playerName))
        else
            ns.SendGuildPacket(string.format("LOSS:%s:%.2f:%.2f:%.2f:%.2f:%s:%s",
                gameId, betAmt, multVal, liveBal, peakBal, hash, playerName))
        end
    end

    ns.CheckBankrollRefill()
    if ns.RefreshHub then ns.RefreshHub() end
end

-- ============================================================================
-- Incoming Guild Addon Packet Handler
-- ============================================================================
local function ApplyPeerGameRecord(gameId, displayKey, multVal, payVal)
    local db = ns.db
    if (multVal or 0) <= 0 and (payVal or 0) <= 0 then return end
    local board = db.clanRecords[gameId]
    if not board then return end
    local cleanKey = ns.FormatPlayerName(displayKey)
    if IsBetterGameRecord(gameId, multVal, payVal, board[cleanKey]) then
        board[cleanKey] = {
            mult   = multVal,
            payout = payVal,
        }
    end
end

local function ApplyPeerLiveBalance(displayKey, liveVal)
    local db = ns.db
    if liveVal == nil or liveVal < 0 then return end
    local cleanKey = ns.FormatPlayerName(displayKey)
    db.clanRecords.LIVE[cleanKey] = { val = liveVal }
end

local function ApplyPeerPeakBalance(displayKey, peakVal)
    local db = ns.db
    if (peakVal or 0) <= 0 then return end
    local cleanKey = ns.FormatPlayerName(displayKey)
    local existing = db.clanRecords.PEAK[cleanKey]
    if not existing or peakVal > (existing.val or 0) then
        db.clanRecords.PEAK[cleanKey] = { val = peakVal }
    end
end

local function HandleIncomingGuildPacket(prefix, message, channel, sender)
    if prefix ~= ns.ADDON_PREFIX or channel ~= "GUILD" then return end
    if not ns.VerifyAndSyncGuildState() then return end
    if ns.IsSelfSender(sender) then return end

    local strippedSender = ns.StripRealm(sender)
    local shortSender = Ambiguate and Ambiguate(sender, "short") or strippedSender
    if not strippedSender or strippedSender == "" then return end

    if next(guildRosterCache) ~= nil and not (guildRosterCache[shortSender] or guildRosterCache[strippedSender]) then
        ns.RefreshGuildRosterCache()
        if next(guildRosterCache) ~= nil and not (guildRosterCache[shortSender] or guildRosterCache[strippedSender]) then
            return
        end
    end

    local db = ns.db
    EnsureRecordTables(db)
    local cmd, rest = string.match(message, "^([^:]+):?(.*)$")

    if cmd == "SYNC_REQ" then
        ns.BroadcastMyBestRecords()

    elseif cmd == "BAL" then
        local liveStr, peakStr, customDisplay = string.match(rest, "^([^:]+):([^:]+):?(.*)$")
        if not liveStr then return end
        local displayKey = (customDisplay and customDisplay ~= "")
            and ns.FormatPlayerName(customDisplay)
            or ns.FormatPlayerName(strippedSender)
        ApplyPeerLiveBalance(displayKey, tonumber(liveStr))
        ApplyPeerPeakBalance(displayKey, tonumber(peakStr) or 0)
        if ns.RefreshClanDrawer then ns.RefreshClanDrawer() end

    elseif cmd == "SYNC_REP" then
        local liveStr, peakStr, cPair, bPair, rPair, pPair, customDisplay =
            string.match(rest, "^([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):?(.*)$")
        if not liveStr then return end

        local displayKey = (customDisplay and customDisplay ~= "")
            and ns.FormatPlayerName(customDisplay)
            or ns.FormatPlayerName(strippedSender)

        ApplyPeerLiveBalance(displayKey, tonumber(liveStr))
        ApplyPeerPeakBalance(displayKey, tonumber(peakStr) or 0)

        local pairsMap = {
            CRASH     = cPair,
            BLACKJACK = bPair,
            ROULETTE  = rPair,
            POKER     = pPair,
        }
        for gid, pairStr in pairs(pairsMap) do
            local mStr, pStr = string.match(pairStr or "", "^([^,]+),([^,]+)$")
            ApplyPeerGameRecord(gid, displayKey, tonumber(mStr) or 0, tonumber(pStr) or 0)
        end

        if ns.RefreshClanDrawer then ns.RefreshClanDrawer() end

    elseif cmd == "WIN" then
        local gameRaw, betStr, multStr, profStr, bestMStr, bestPStr, liveStr, peakStr, hashStr, customDisplay =
            string.match(rest, "^([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]*):?(.*)$")
        if not gameRaw then return end
        if hashStr and hashStr ~= "" and sentRoundHashes[hashStr] then return end

        local gameId   = ns.NormalizeGameId(gameRaw)
        local gameTag  = ns.GetGameTag(gameId)
        local betAmt   = tonumber(betStr) or 0
        local multVal  = tonumber(multStr) or 0
        local profVal  = tonumber(profStr) or 0
        local bestMult = tonumber(bestMStr) or multVal
        local bestPay  = tonumber(bestPStr) or profVal
        local liveVal  = tonumber(liveStr)
        local peakVal  = tonumber(peakStr) or 0
        local displayKey = (customDisplay and customDisplay ~= "")
            and ns.FormatPlayerName(customDisplay)
            or ns.FormatPlayerName(strippedSender)

        if multVal > 0 or profVal > 0 then
            ApplyPeerLiveBalance(displayKey, liveVal)
            ApplyPeerPeakBalance(displayKey, peakVal)
            ApplyPeerGameRecord(gameId, displayKey, bestMult, bestPay)

            table.insert(db.clanFeed, 1, {
                game   = gameId,
                tag    = gameTag,
                player = displayKey,
                mult   = multVal,
                profit = profVal,
            })
            while #db.clanFeed > 30 do
                table.remove(db.clanFeed)
            end

            table.insert(db.betLog, 1, {
                game   = gameId,
                tag    = gameTag,
                player = displayKey,
                isSelf = false,
                bet    = betAmt,
                mult   = multVal,
                profit = profVal,
                won    = true,
                hash   = hashStr or "GuildSync",
            })
            while #db.betLog > 30 do
                table.remove(db.betLog)
            end

            if ns.RefreshHub then ns.RefreshHub() end
        end

    elseif cmd == "LOSS" then
        local gameRaw, betStr, multStr, liveStr, peakStr, hashStr, customDisplay =
            string.match(rest, "^([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]*):?(.*)$")
        if not gameRaw then return end
        if hashStr and hashStr ~= "" and sentRoundHashes[hashStr] then return end

        local gameId  = ns.NormalizeGameId(gameRaw)
        local gameTag = ns.GetGameTag(gameId)
        local betAmt  = tonumber(betStr) or 0
        local multVal = tonumber(multStr) or 1.00
        local liveVal = tonumber(liveStr)
        local peakVal = tonumber(peakStr) or 0
        local displayKey = (customDisplay and customDisplay ~= "")
            and ns.FormatPlayerName(customDisplay)
            or ns.FormatPlayerName(strippedSender)

        if betAmt > 0 then
            ApplyPeerLiveBalance(displayKey, liveVal)
            ApplyPeerPeakBalance(displayKey, peakVal)

            table.insert(db.betLog, 1, {
                game   = gameId,
                tag    = gameTag,
                player = displayKey,
                isSelf = false,
                bet    = betAmt,
                mult   = multVal,
                profit = 0,
                won    = false,
                hash   = hashStr or "GuildSync",
            })
            while #db.betLog > 30 do
                table.remove(db.betLog)
            end
            if ns.RefreshHub then ns.RefreshHub() end
        end
    end
end

-- ============================================================================
-- Initialization & Events
-- ============================================================================
EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
EventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
EventFrame:RegisterEvent("PLAYER_GUILD_UPDATE")
EventFrame:RegisterEvent("CHAT_MSG_ADDON")

EventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName == ADDON_NAME then
            if type(VoidCasinoDB) ~= "table" then
                VoidCasinoDB = {
                    credits          = ns.STARTING_CREDITS,
                    peakBalance      = ns.STARTING_CREDITS,
                    emptyTimestamp   = 0,
                    wins             = 0,
                    losses           = 0,
                    netProfit        = 0,
                    guildName        = "",
                    gameRecords      = CreateEmptyGameRecords(),
                    clanRecords      = CreateEmptyClanRecords(),
                    clanFeed         = {},
                    crashHistory     = {1.49, 12.45, 3.34, 2.00, 2.75, 3.19, 1.04, 5.72},
                    crashPersonalLog = {},
                    betLog           = {},
                }
            end

            VoidCasinoDB.credits          = VoidCasinoDB.credits or ns.STARTING_CREDITS
            VoidCasinoDB.peakBalance      = math.max(VoidCasinoDB.peakBalance or ns.STARTING_CREDITS, VoidCasinoDB.credits)
            VoidCasinoDB.emptyTimestamp   = VoidCasinoDB.emptyTimestamp or 0
            VoidCasinoDB.wins             = VoidCasinoDB.wins or 0
            VoidCasinoDB.losses           = VoidCasinoDB.losses or 0
            VoidCasinoDB.netProfit        = VoidCasinoDB.netProfit or 0
            VoidCasinoDB.guildName        = VoidCasinoDB.guildName or ""
            VoidCasinoDB.clanFeed         = VoidCasinoDB.clanFeed or {}
            VoidCasinoDB.crashHistory     = VoidCasinoDB.crashHistory or {1.49, 12.45, 3.34, 2.00, 2.75, 3.19, 1.04, 5.72}
            VoidCasinoDB.crashPersonalLog = VoidCasinoDB.crashPersonalLog or {}
            VoidCasinoDB.betLog           = VoidCasinoDB.betLog or {}

            EnsureRecordTables(VoidCasinoDB)

            -- Migrate legacy Crash personal best if present from earlier builds
            if (VoidCasinoDB.highestCashoutMult or 0) > (VoidCasinoDB.gameRecords.CRASH.mult or 0) then
                VoidCasinoDB.gameRecords.CRASH.mult   = VoidCasinoDB.highestCashoutMult
                VoidCasinoDB.gameRecords.CRASH.payout = VoidCasinoDB.highestPayout or 0
            end

            ns.db = VoidCasinoDB
            prngState = ns.MixSeed(GetServerTime() + math.floor(GetTime() * 1000))

            ns.CheckBankrollRefill()
            ns.VerifyAndSyncGuildState()
            if ns.BuildHub then ns.BuildHub() end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.CheckBankrollRefill()
        if ns.VerifyAndSyncGuildState() then
            ns.RequestGuildLeaderboardSync()
        end
        if ns.RefreshHub then ns.RefreshHub() end

    elseif event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        ns.VerifyAndSyncGuildState()
        if ns.RefreshClanDrawer then ns.RefreshClanDrawer() end

    elseif event == "CHAT_MSG_ADDON" then
        HandleIncomingGuildPacket(...)
    end
end)