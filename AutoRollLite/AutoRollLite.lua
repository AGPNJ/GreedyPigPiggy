--[[--------------------------------------------------------------------------
    AutoRollLite -- WoW 3.3.5a (WotLK) / AzerothCore
    Auto Need on rare+, Greed on uncommon. Deferred, staggered, conflict-safe.

    Invariants (AutoRollLite-REQUIREMENTS.md):
      Lua 5.1 only, no C_* API, no libraries. ONE frame for the whole addon.
      Never roll inside an event handler -- everything goes through the queue.
      A:Decide() is pure: primitives in, roll type out, no API, no side effects.
      Never touch a Blizzard frame beyond the one documented StaticPopup_Hide.
----------------------------------------------------------------------------]]

local ADDON = "AutoRollLite"

local PASS, NEED, GREED, DISENCHANT = 0, 1, 2, 3
local ROLLNAME  = { [0] = "Pass", [1] = "Need", [2] = "Greed", [3] = "Disenchant" }
local ROLLCOLOR = { [0] = "|cff9d9d9d", [1] = "|cff1eff00", [2] = "|cffffd100", [3] = "|cffa335ee" }

local PIGGY  = "|TInterface\\Icons\\Ability_Hunter_Pet_Boar:14:14:0:0|t"
local PREFIX = PIGGY .. "|cffff77c8AutoRoll|r "

local TICK, ROLL_TTL, EXT_TTL = 0.1, 65, 120

local defaults = {
    version = 1, enabled = true,
    needQuality = 3, greedQuality = 2,      -- min quality for Need / Greed
    delay = 0.75, stagger = 0.25,
    instanceOnly = true, raidEnabled = false,
    bopProtection = false, allowDisenchant = false,
    autoPass = false,                       -- submit Pass, or leave frame to user
    quiet = false, debug = false,
}

-- Toggles reachable from /arl: command -> { key, label }
local TOGGLES = {
    instance = { "instanceOnly",    "instance-only" },
    raid     = { "raidEnabled",     "rolling in raids" },
    bop      = { "bopProtection",   "BoP protection" },
    de       = { "allowDisenchant", "disenchant fallback" },
    autopass = { "autoPass",        "auto-submit Pass" },
    quiet    = { "quiet",           "quiet mode" },
    debug    = { "debug",           "debug logging" },
}

-- the addon table and the one and only frame -------------------------------
local A = {}
local f = CreateFrame("Frame")

A.pending  = {}     -- [rollID] = { quality, action, reason, link, queuedAt, fireAt }
A.ours     = {}     -- [rollID] = rollType we submitted
A.external = {}     -- [rollID] = { type, at, mine }   set by the RollOnLoot hook
A.log      = {}     -- ring buffer, last 20 decisions
A.inFlight = false
A.tick     = 0
A.lastFire = 0

local function Say(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end

function A:Debug(msg)
    if self.db and self.db.debug then Say("|cff808080" .. msg .. "|r") end
end

function A:Record(action, what, reason)
    table.insert(self.log, string.format("|cff808080%s|r %s%s|r %s |cff808080(%s)|r",
        date("%H:%M:%S"), ROLLCOLOR[action] or "", ROLLNAME[action] or "--",
        what or "?", reason or ""))
    if #self.log > 20 then table.remove(self.log, 1) end
end

--[[ FR-1 / FR-2 / FR-6 : the pure decision function.
     No WoW API calls, no side effects -- reads config only. This is the one
     piece that can be reasoned about and tested without logging into the game.
     Returns rollType (0-3) and a short reason string.                       ]]

function A:Decide(quality, canNeed, canGreed, canDisenchant, bop, itemID)
    local db = self.db
    if quality == nil then return PASS, "no quality" end
    if itemID and db.never[itemID] then return PASS, "blacklisted" end

    local want, why
    if itemID and db.always[itemID] then
        want, why = db.always[itemID], "whitelisted"
    elseif quality >= db.needQuality then
        want, why = NEED, "quality " .. quality
    elseif quality >= db.greedQuality then
        want, why = GREED, "quality " .. quality
    else
        want, why = PASS, "quality " .. quality
    end

    -- FR-7: BoP protection downgrades Need before the ladder runs.
    if want == NEED and bop and db.bopProtection then
        want, why = GREED, "BoP protection"
    end

    -- FR-2: fallback ladder. Never submit an action the server flagged off.
    if want == NEED and not canNeed then want, why = GREED, "canNeed=false" end
    if want == DISENCHANT and not canDisenchant then want, why = GREED, "canDisenchant=false" end
    if want == GREED and not canGreed then
        if db.allowDisenchant and canDisenchant then
            want, why = DISENCHANT, "canGreed=false -> DE"
        else
            want, why = PASS, "canGreed=false"
        end
    end
    return want, why
end

--[[ FR-7 : scope gating ---------------------------------------------------]]

function A:Allowed()
    local db = self.db
    if not db.enabled then return false, "addon off" end
    if db.instanceOnly and not IsInInstance() then return false, "not in instance" end
    if not db.raidEnabled and GetNumRaidMembers() > 0 then return false, "raid group" end
    return true
end

--[[ FR-3 : deferred, staggered execution ----------------------------------]]

local function ItemIDFromLink(link)
    if not link then return nil end
    return tonumber(string.match(link, "item:(%d+)"))
end

function A:Enqueue(rollID)
    if self.pending[rollID] then return end

    local ok, why = self:Allowed()
    if not ok then return self:Debug("ignoring roll " .. rollID .. " (" .. why .. ")") end

    local _, name, _, quality, bop, canNeed, canGreed, canDisenchant,
          rNeed, rGreed, rDE = GetLootRollItemInfo(rollID)
    if quality == nil then return self:Debug("roll " .. rollID .. " had no item info") end

    -- FR-5: link may be nil for a few frames. It is only used for logging and
    -- blacklist matching, so proceed now and retry at execution time.
    local link = GetLootRollItemLink(rollID)

    -- can*/bop arrive as 1/nil on this client -- coerce, never compare to true.
    canNeed, canGreed = canNeed and true or false, canGreed and true or false
    canDisenchant, bop = canDisenchant and true or false, bop and true or false

    local action, reason = self:Decide(quality, canNeed, canGreed, canDisenchant,
        bop, ItemIDFromLink(link))

    local now = GetTime()
    local fire = now + self.db.delay
    if fire <= self.lastFire then fire = self.lastFire + self.db.stagger end
    self.lastFire = fire

    self.pending[rollID] = { quality = quality, action = action, reason = reason,
        link = link, name = name, hadLink = link and true or false,
        queuedAt = now, fireAt = fire }

    self:Debug(string.format("queue %d q=%d need=%s(%s) greed=%s(%s) de=%s(%s) bop=%s -> %s (%s) in %.2fs",
        rollID, quality, tostring(canNeed), tostring(rNeed), tostring(canGreed), tostring(rGreed),
        tostring(canDisenchant), tostring(rDE), tostring(bop), ROLLNAME[action], reason, fire - now))

    f:SetScript("OnUpdate", A.OnUpdateHandler)
end

function A:Execute(rollID, e)
    -- FR-8: someone else already rolled this one. Stand down.
    local ext = self.external[rollID]
    if ext and not ext.mine then
        local what = e.link or e.name or ("roll " .. rollID)
        Say("|cff808080deferred to another addon on " .. what .. "|r")
        return self:Record(ext.type, what, "deferred to another addon")
    end

    -- FR-9: roll expired or was cancelled while we waited.
    local _, name, _, quality, bop, canNeed, canGreed, canDisenchant = GetLootRollItemInfo(rollID)
    if quality == nil then return self:Debug("roll " .. rollID .. " vanished before execution") end

    -- FR-5: retry the link once; re-decide if it unlocks a black/whitelist match.
    local action, reason, link = e.action, e.reason, e.link
    if not e.hadLink then
        link = GetLootRollItemLink(rollID)
        if link then
            action, reason = self:Decide(quality, canNeed and true or false,
                canGreed and true or false, canDisenchant and true or false,
                bop and true or false, ItemIDFromLink(link))
            if action ~= e.action then
                self:Debug("late link re-decided roll " .. rollID .. " -> " .. ROLLNAME[action])
            end
        end
    end

    local what = link or name or ("roll " .. rollID)
    if action == PASS and not self.db.autoPass then
        self:Debug("not rolling on " .. what .. " (" .. reason .. ")")
        return self:Record(PASS, what, reason .. "; left to user")
    end

    self.inFlight = true
    RollOnLoot(rollID, action)
    self.inFlight = false
    self.ours[rollID] = action

    self:Record(action, what, reason)
    if not self.db.quiet then
        Say((ROLLCOLOR[action] or "") .. ROLLNAME[action] .. "|r on " .. what)
    end
end

function A:OnUpdate(elapsed)
    self.tick = self.tick + elapsed
    if self.tick < TICK then return end
    self.tick = 0
    local now = GetTime()

    for rollID, e in pairs(self.pending) do
        if now - e.queuedAt > ROLL_TTL then
            self.pending[rollID] = nil
            self:Debug("expired stale queue entry " .. rollID)
        elseif now >= e.fireAt then
            self.pending[rollID] = nil
            self:Execute(rollID, e)
        end
    end

    -- FR-9: cap external growth.
    for rollID, ext in pairs(self.external) do
        if now - ext.at > EXT_TTL then self.external[rollID] = nil end
    end

    if not next(self.pending) and not next(self.external) then
        f:SetScript("OnUpdate", nil)
        self.lastFire = 0
    end
end

function A.OnUpdateHandler(_, elapsed) A:OnUpdate(elapsed) end

--[[ FR-8 : record every roll made by anyone; ours are flagged via inFlight.
     A user clicking the default Blizzard frame lands here too, which is
     exactly right -- we then defer to them.                                 ]]

hooksecurefunc("RollOnLoot", function(rollID, rollType)
    A.external[rollID] = { type = rollType, at = GetTime(), mine = A.inFlight }
    if not A.inFlight then
        A:Debug("observed external roll " .. tostring(rollID) .. " -> " .. tostring(ROLLNAME[rollType]))
        f:SetScript("OnUpdate", A.OnUpdateHandler)   -- so the record gets pruned
    end
end)

--[[ FR-4 : confirmations, only for rolls we own ---------------------------]]

function A:Confirm(rollID, rollType, source)
    if self.ours[rollID] == nil then
        return self:Debug(source .. " for roll " .. tostring(rollID) .. " is not ours -- ignoring")
    end
    ConfirmLootRoll(rollID, rollType)
    -- 3.3.5 reuses this popup id for both confirm paths. If your client's
    -- StaticPopup.lua uses a distinct key for DE, add it here.
    StaticPopup_Hide("CONFIRM_LOOT_ROLL")
    self:Debug(source .. " auto-confirmed for roll " .. tostring(rollID))
end

--[[ config ----------------------------------------------------------------]]

function A:LoadConfig()
    if type(AutoRollLiteDB) ~= "table" then AutoRollLiteDB = {} end
    local db = AutoRollLiteDB
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = v end
    end
    if type(db.never)  ~= "table" then db.never  = {} end
    if type(db.always) ~= "table" then db.always = {} end
    db.version = defaults.version
    self.db = db
end

function A:Reset()
    wipe(self.pending); wipe(self.ours); wipe(self.external)
    self.inFlight, self.lastFire, self.tick = false, 0, 0
    f:SetScript("OnUpdate", nil)
end

--[[ events ----------------------------------------------------------------]]

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("START_LOOT_ROLL")
f:RegisterEvent("CONFIRM_LOOT_ROLL")
f:RegisterEvent("CONFIRM_DISENCHANT_ROLL")

f:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "START_LOOT_ROLL" then
        A:Enqueue(arg1)
    elseif event == "CONFIRM_LOOT_ROLL" or event == "CONFIRM_DISENCHANT_ROLL" then
        A:Confirm(arg1, arg2, event)
    elseif event == "PLAYER_ENTERING_WORLD" then
        A:Reset()
    elseif event == "ADDON_LOADED" and arg1 == ADDON then
        A:LoadConfig()
        Say("loaded. |cff808080/arl for options.|r")
    end
end)

--[[ slash commands --------------------------------------------------------]]

local function OnOff(v) return v and "|cff1eff00on|r" or "|cffff2020off|r" end

local function ParseBool(word, current)
    if word == "on"  or word == "1" or word == "true"  then return true end
    if word == "off" or word == "0" or word == "false" then return false end
    return not current
end

local function CursorItemID()
    local kind, id, link = GetCursorInfo()
    if kind ~= "item" then return nil end
    ClearCursor()
    return tonumber(id) or ItemIDFromLink(link)
end

function A:PrintConfig()
    local db = self.db
    Say("master " .. OnOff(db.enabled) .. "  need>=|cffffffff" .. db.needQuality
        .. "|r  greed>=|cffffffff" .. db.greedQuality .. "|r  delay |cffffffff"
        .. db.delay .. "s|r  stagger |cffffffff" .. db.stagger .. "s|r")
    local parts = {}
    for cmd, t in pairs(TOGGLES) do table.insert(parts, cmd .. " " .. OnOff(db[t[1]])) end
    table.sort(parts)
    Say(table.concat(parts, "  "))
    local n, a = 0, 0
    for _ in pairs(db.never)  do n = n + 1 end
    for _ in pairs(db.always) do a = a + 1 end
    Say("blacklist |cffffffff" .. n .. "|r  whitelist |cffffffff" .. a .. "|r")
end

SLASH_AUTOROLLLITE1 = "/arl"
SLASH_AUTOROLLLITE2 = "/autoroll"
SlashCmdList["AUTOROLLLITE"] = function(msg)
    local db = A.db
    if not db then return end
    local cmd, a1, a2 = string.match(string.lower(msg or ""), "^(%S*)%s*(%S*)%s*(%S*)")
    cmd = cmd or ""

    local toggle = TOGGLES[cmd]
    if toggle then
        db[toggle[1]] = ParseBool(a1, db[toggle[1]])
        Say(toggle[2] .. " " .. OnOff(db[toggle[1]]))

    elseif cmd == "" or cmd == "help" then
        A:PrintConfig()
        Say("|cff808080on|off, need <q>, greed <q>, delay <s>, stagger <s>, never [id],|r")
        Say("|cff808080always <id> <1|2|3>, clear, status, and toggles: |r"
            .. "|cff808080instance raid bop de autopass quiet debug|r")

    elseif cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        Say("master switch " .. OnOff(db.enabled))

    elseif cmd == "need" or cmd == "greed" then
        local q = tonumber(a1)
        if q and q >= 0 and q <= 7 then
            db[cmd .. "Quality"] = q
            Say(cmd .. " minimum quality set to |cffffffff" .. q .. "|r")
        else Say("usage: /arl " .. cmd .. " <0-7>") end

    elseif cmd == "delay" or cmd == "stagger" then
        local s = tonumber(a1)
        if s and s >= 0 and s <= 5 then
            db[cmd] = s
            Say(cmd .. " set to |cffffffff" .. s .. "s|r")
        else Say("usage: /arl " .. cmd .. " <0-5>") end

    elseif cmd == "never" then
        local id = tonumber(a1) or CursorItemID()
        if id then
            db.never[id], db.always[id] = true, nil
            Say("blacklisted item |cffffffff" .. id .. "|r")
        else Say("usage: /arl never <itemID>  (or pick the item up first)") end

    elseif cmd == "always" then
        local id, rt = tonumber(a1) or CursorItemID(), tonumber(a2)
        if id and rt and rt >= 1 and rt <= 3 then
            db.always[id], db.never[id] = rt, nil
            Say("item |cffffffff" .. id .. "|r forced to " .. ROLLNAME[rt])
        else Say("usage: /arl always <itemID> <1=Need 2=Greed 3=DE>") end

    elseif cmd == "clear" then
        wipe(db.never); wipe(db.always)
        Say("blacklist and whitelist cleared")

    elseif cmd == "status" then
        local n, now = 0, GetTime()
        for rollID, e in pairs(A.pending) do
            n = n + 1
            Say(string.format("pending %d: %s in %.2fs", rollID, ROLLNAME[e.action] or "?", e.fireAt - now))
        end
        if n == 0 then Say("pending queue empty") end
        Say("last " .. #A.log .. " decisions:")
        for i = 1, #A.log do DEFAULT_CHAT_FRAME:AddMessage("  " .. A.log[i]) end

    else
        Say("unknown command '" .. cmd .. "' -- /arl for help")
    end
end
