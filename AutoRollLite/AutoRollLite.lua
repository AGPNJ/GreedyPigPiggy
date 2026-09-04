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
    version = 2, enabled = true,
    needQuality = 3, greedQuality = 2,      -- min quality for Need / Greed
    delay = 0.75, stagger = 0.25,
    usableOnly = false,                     -- FR-10: downgrade gear this class cannot wear
    lootFilter = false,                     -- FR-11: filter the corpse loot window by quality
    lootQuality = 2,                        -- FR-11: min quality to pick up (2 = skip grey/white)
    lootClose = true,                       -- close the window once we have taken our picks
    instanceOnly = true, raidEnabled = false,
    bopProtection = false, allowDisenchant = false,
    autoPass = false,                       -- submit Pass, or leave frame to user
    autoConfirmBind = true,                 -- auto-accept the "will bind to you" popup
    quiet = false, debug = false,
}

-- Toggles reachable from /arl: command -> { key, label }
local TOGGLES = {
    instance = { "instanceOnly",    "instance-only" },
    raid     = { "raidEnabled",     "rolling in raids" },
    bop      = { "bopProtection",   "BoP protection" },
    de       = { "allowDisenchant", "disenchant fallback" },
    autopass = { "autoPass",        "auto-submit Pass" },
    usable   = { "usableOnly",      "usable-gear-only rolling" },
    loot     = { "lootFilter",      "corpse loot filter" },
    lootshut = { "lootClose",       "close loot window after filtering" },
    bind     = { "autoConfirmBind", "auto-confirm bind popup" },
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
A.lastFilterLoot = 0     -- FR-11: timestamp of the last slot the filter looted
A.lootSkipped    = 0     -- FR-11: running count of items left on corpses
A.warnedAutoLoot = false

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

function A:Decide(quality, canNeed, canGreed, canDisenchant, bop, itemID, usable)
    local db = self.db
    if quality == nil then return PASS, "no quality" end
    if itemID and db.never[itemID] then return PASS, "blacklisted" end

    local want, why, forced
    if itemID and db.always[itemID] then
        want, why, forced = db.always[itemID], "whitelisted", true
    elseif quality >= db.needQuality then
        want, why = NEED, "quality " .. quality
    elseif quality >= db.greedQuality then
        want, why = GREED, "quality " .. quality
    else
        want, why = PASS, "quality " .. quality
    end

    -- FR-10: gear this class cannot equip drops one step -- Need becomes Greed
    -- (an unusable blue is still worth gold or a shard), Greed becomes Pass so
    -- off-class greens stop filling the bags. usable == nil means "unknown"
    -- (item not cached yet); unknown never downgrades. A whitelisted item is an
    -- explicit instruction and outranks this.
    if db.usableOnly and usable == false and not forced then
        if want == NEED then want, why = GREED, "not usable by class"
        elseif want == GREED then want, why = PASS, "not usable by class" end
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

--[[ FR-10 : "can this character actually wear it?"

     3.3.5 has no API that answers this directly, and GetItemInfo's class and
     subclass strings are localised, so a hardcoded "Warlock -> Cloth" table
     would break on any non-enUS client. The client already knows the answer
     and paints it red in the tooltip, so read that instead: build our own
     hidden tooltip (never Blizzard's -- FR-8), set the item link on it, and
     look for a red line. Colour is locale-independent.

     Returns true / false / nil, where nil means "cannot tell" -- the item is
     not in the local cache yet, or the check is switched off.               ]]

local LEVELPAT

local function IsLevelRequirement(text)
    if not LEVELPAT then
        local raw = ITEM_MIN_LEVEL or "Requires Level %d"
        raw = string.gsub(raw, "([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
        -- "%d" in the subject must become the pattern "%d+"; the pattern that
        -- matches a literal percent is "%%", so this is "%%d", not "%%%%d".
        LEVELPAT = string.gsub(raw, "%%d", "%%d+")
    end
    return string.find(text, LEVELPAT) ~= nil
end

function A:Tooltip()
    if not self.tip then
        self.tip = CreateFrame("GameTooltip", "AutoRollLiteScanTip", nil, "GameTooltipTemplate")
        self.tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    return self.tip
end

function A:Usable(link)
    if not self.db.usableOnly or not link then return nil end

    local name, _, _, _, _, _, _, _, equipSlot = GetItemInfo(link)
    if not name then return nil end                      -- not cached yet
    if not equipSlot or equipSlot == "" then return true end   -- not gear at all

    local tip = self:Tooltip()
    tip:ClearLines()
    tip:SetHyperlink(link)

    for i = 2, (tip:NumLines() or 0) do
        local fs = _G["AutoRollLiteScanTipTextLeft" .. i]
        local text = fs and fs:GetText()
        if text and text ~= "" then
            local r, g, b = fs:GetTextColor()
            -- red line == a requirement this character fails. "Requires Level"
            -- is excluded: that one fixes itself, and a levelling character
            -- should still roll on gear it will wear in two bars' time.
            if r and r > 0.9 and g and g < 0.2 and b and b < 0.2 and not IsLevelRequirement(text) then
                self:Debug("unusable (" .. text .. "): " .. link)
                return false
            end
        end
    end
    return true
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

    local usable = self:Usable(link)
    local action, reason = self:Decide(quality, canNeed, canGreed, canDisenchant,
        bop, ItemIDFromLink(link), usable)

    local now = GetTime()
    local fire = now + self.db.delay
    if fire <= self.lastFire then fire = self.lastFire + self.db.stagger end
    self.lastFire = fire

    self.pending[rollID] = { quality = quality, action = action, reason = reason,
        link = link, name = name, hadLink = link and true or false,
        usable = usable, queuedAt = now, fireAt = fire }

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
                bop and true or false, ItemIDFromLink(link), self:Usable(link))
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

    -- Claim ownership BEFORE rolling. The client raises CONFIRM_LOOT_ROLL from
    -- inside RollOnLoot for a BoP Need -- it knows the item binds, so there is
    -- no server round trip -- and A:Confirm would not recognise the popup as
    -- ours if we recorded it on the line after. Then the popup just sits there.
    self.ours[rollID] = action
    self.inFlight = true
    RollOnLoot(rollID, action)
    self.inFlight = false

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

--[[ "Looting this item will bind it to you." -- the OTHER one.
     Two different popups share the LOOT_NO_DROP text in 3.3.5:
       CONFIRM_LOOT_ROLL  fires when you roll Need on a BoP item  (above)
       LOOT_BIND          fires when you actually pick the item up
     The second arrives as LOOT_BIND_CONFIRM(slot) and is cleared with
     ConfirmLootSlot(slot), not ConfirmLootRoll. Gated by the same scope
     rules as rolling so it can never fire in the open world by accident,
     and skipped for blacklisted items so /arl never still means "ask me".]]

function A:ConfirmBind(slot)
    if not self.db.autoConfirmBind then return end

    -- FR-11: a BoP item the loot filter just took raises this popup wherever we
    -- are, so a filter-initiated pickup clears its own popup even when
    -- instanceOnly would otherwise gate us out. Without this the popup parks
    -- itself on screen and the grind stops at the first open-world BoP drop.
    local ok, why = self:Allowed()
    if not ok and GetTime() - self.lastFilterLoot > 2 then
        return self:Debug("bind popup left alone (" .. why .. ")")
    end

    local link = GetLootSlotLink(slot)
    local itemID = ItemIDFromLink(link)
    if itemID and self.db.never[itemID] then
        return self:Debug("bind popup left alone (blacklisted)")
    end

    local what = link or ("loot slot " .. tostring(slot))
    ConfirmLootSlot(slot)
    StaticPopup_Hide("LOOT_BIND")
    self:Record(nil, what, "bind confirmed")
    if not self.db.quiet then Say("|cffffd100bind confirmed|r on " .. what) end
end

--[[ FR-11 : corpse loot filter

     The 3.3.5 client's own autoloot is all-or-nothing, so grinding fills the
     bags with vendor trash. With db.lootFilter on we become a selective
     autoloot: walk the slots on LOOT_OPENED, take what clears db.lootQuality,
     leave the rest on the corpse.

     Deliberately NOT scoped by instanceOnly -- bags fill fastest out in the
     world, which is exactly where that gate would switch this off.

     Only the loot API is touched (GetLootSlotInfo / LootSlot / CloseLoot).
     LootFrame itself is never read, hidden or hooked, per FR-8.

     Requires the client's own autoloot to be OFF -- if it is on, the client
     has already taken everything before this event reaches us.             ]]

--[[ Quest items are white, so a naive "skip white" filter would silently
     break quest progress. 3.3.5's GetLootSlotInfo returns only five values --
     texture, name, quantity, quality, locked -- with no isQuestItem flag (that
     arrived in a later expansion), so the flag cannot be read directly. The
     tooltip does carry it, and GameTooltip:SetLootItem(slot) exists on this
     client, so scan for the two marker lines on our own hidden tooltip.     ]]

function A:IsQuestLoot(slot)
    local tip = self:Tooltip()
    tip:ClearLines()
    tip:SetLootItem(slot)
    local bind, starts = ITEM_BIND_QUEST or "Quest Item",
                         ITEM_STARTS_QUEST or "This Item Begins a Quest"
    for i = 1, (tip:NumLines() or 0) do
        local fs = _G["AutoRollLiteScanTipTextLeft" .. i]
        local text = fs and fs:GetText()
        if text == bind or text == starts then return true end
    end
    return false
end

function A:LootSlotWanted(slot)
    local db = self.db

    if LootSlotIsCoin and LootSlotIsCoin(slot) then return true, "coin" end

    local _, _, _, quality, locked = GetLootSlotInfo(slot)
    if locked then return false, "locked" end
    if self:IsQuestLoot(slot) then return true, "quest item" end

    local itemID = ItemIDFromLink(GetLootSlotLink(slot))
    if itemID and db.never[itemID]  then return false, "blacklisted" end
    if itemID and db.always[itemID] then return true, "whitelisted" end

    if quality == nil then return true, "unknown quality" end
    if quality >= db.lootQuality then return true, "quality " .. quality end
    return false, "quality " .. quality
end

function A:LootOpened(autoLoot)
    local db = self.db
    if not db.enabled or not db.lootFilter then return end

    if autoLoot and autoLoot ~= 0 and not self.warnedAutoLoot then
        self.warnedAutoLoot = true
        Say("|cffff2020loot filter cannot work while the client's own autoloot is on.|r")
        Say("|cff808080turn it off in Interface > Controls, or /console autoLootDefault 0|r")
    end

    local n = GetNumLootItems()
    if not n or n == 0 then return end

    local took, left = 0, 0
    -- backwards: looting a slot can renumber the ones after it
    for slot = n, 1, -1 do
        local want, why = self:LootSlotWanted(slot)
        if want then
            self.lastFilterLoot = GetTime()
            LootSlot(slot)
            took = took + 1
        else
            left = left + 1
            self:Debug("skipped loot slot " .. slot .. " (" .. why .. ")")
        end
    end

    -- Deliberately not a chat line: on a grind this fires once per corpse.
    -- The running total is available from /arl status instead.
    self.lootSkipped = (self.lootSkipped or 0) + left
    if db.lootClose then CloseLoot() end
    self:Debug("loot filter took " .. took .. ", left " .. left)
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
    self.lastFilterLoot = 0
    f:SetScript("OnUpdate", nil)
end

--[[ events ----------------------------------------------------------------]]

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("START_LOOT_ROLL")
f:RegisterEvent("CONFIRM_LOOT_ROLL")
f:RegisterEvent("CONFIRM_DISENCHANT_ROLL")
f:RegisterEvent("LOOT_BIND_CONFIRM")
f:RegisterEvent("LOOT_OPENED")

f:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "START_LOOT_ROLL" then
        A:Enqueue(arg1)
    elseif event == "CONFIRM_LOOT_ROLL" or event == "CONFIRM_DISENCHANT_ROLL" then
        A:Confirm(arg1, arg2, event)
    elseif event == "LOOT_BIND_CONFIRM" then
        A:ConfirmBind(arg1)
    elseif event == "LOOT_OPENED" then
        A:LootOpened(arg1)
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
    Say("loot filter " .. OnOff(db.lootFilter) .. "  pick up quality >=|cffffffff"
        .. db.lootQuality .. "|r  usable-only " .. OnOff(db.usableOnly))
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
        Say("|cff808080on|off, need <q>, greed <q>, lootq <q>, delay <s>, stagger <s>,|r")
        Say("|cff808080never [id], always <id> <1|2|3>, clear, status, and toggles:|r")
        Say("|cff808080instance raid bop de autopass bind loot lootshut usable quiet debug|r")

    elseif cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        Say("master switch " .. OnOff(db.enabled))

    elseif cmd == "need" or cmd == "greed" or cmd == "lootq" then
        local q = tonumber(a1)
        local key = (cmd == "lootq") and "lootQuality" or (cmd .. "Quality")
        if q and q >= 0 and q <= 7 then
            db[key] = q
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
        if db.lootFilter then
            Say("loot filter has left |cffffffff" .. (A.lootSkipped or 0) .. "|r items on corpses this session")
        end
        Say("last " .. #A.log .. " decisions:")
        for i = 1, #A.log do DEFAULT_CHAT_FRAME:AddMessage("  " .. A.log[i]) end

    else
        Say("unknown command '" .. cmd .. "' -- /arl for help")
    end
end
