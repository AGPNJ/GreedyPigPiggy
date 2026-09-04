-- Offline harness: stubs the 3.3.5 client API and drives AutoRollLite through
-- the acceptance criteria in section 8 of the requirements spec.

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("  PASS  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

----------------------------------------------------------------- client stubs
local clock, chat, popupsHidden, confirmed, submitted = 0, {}, {}, {}, {}
local rolls, inInstance, raidMembers = {}, true, 0

function GetTime() return clock end
function date(fmt) return "12:00:00" end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function IsInInstance() return inInstance, inInstance and "party" or "none" end
function GetNumRaidMembers() return raidMembers end
function GetCursorInfo() return nil end
function ClearCursor() end

DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
SlashCmdList = {}

function GetLootRollItemInfo(id)
    local r = rolls[id]
    if not r then return nil end
    return "tex", r.name, 1, r.quality, r.bop, r.canNeed, r.canGreed, r.canDE,
           r.rNeed, r.rGreed, r.rDE, 0
end
function GetLootRollItemLink(id) local r = rolls[id]; return r and r.link or nil end
function RollOnLoot(id, t) table.insert(submitted, { id = id, type = t, at = clock }) end
function ConfirmLootRoll(id, t) table.insert(confirmed, { id = id, type = t }) end

local lootSlots, slotsConfirmed = {}, {}
function ConfirmLootSlot(slot) table.insert(slotsConfirmed, slot) end
function StaticPopup_Hide(which) table.insert(popupsHidden, which) end

------------------------------------------------------- item info / tooltip
-- itemInfo[itemID] = { equipSlot = "INVTYPE_CHEST", red = "Plate" }
-- red is the text of a red tooltip line, i.e. a requirement this character
-- fails. absent itemID = not in the local cache yet.
WorldFrame = {}
local cvars = { autoLootDefault = "0" }
function GetCVar(k) return cvars[k] end
function SetCVar(k, v) cvars[k] = tostring(v) end
-- forward declaration: the tooltip stub below reads it, reset() rewrites it
local lootItems, looted, lootClosed = {}, {}, 0
ITEM_MIN_LEVEL = "Requires Level %d"
ITEM_BIND_QUEST = "Quest Item"
ITEM_STARTS_QUEST = "This Item Begins a Quest"
local itemInfo = {}

local function LinkID(link) return link and tonumber(string.match(link, "item:(%d+)")) end

function GetItemInfo(link)
    local info = itemInfo[LinkID(link)]
    if not info then return nil end
    return "Item", link, 2, 80, 70, "Armor", "Cloth", 1, info.equipSlot or "", "tex"
end

-- The real client puts the equip location in the LEFT column and the armour
-- type in the RIGHT one on the same line, and reddens the right-hand text for
-- gear the character cannot wear. The stub models both columns for that reason.
local tipLines = { TextLeft = {}, TextRight = {} }
local function TipLine(side, i)
    local col = tipLines[side]
    if not col[i] then
        local fs = {}
        function fs:GetText() return self.text end
        function fs:GetTextColor() return self.r or 1, self.g or 1, self.b or 1 end
        col[i] = fs
        _G["AutoRollLiteScanTip" .. side .. i] = fs
    end
    return col[i]
end

-- A tooltip with no owner accepts Set* calls and populates nothing. Modelled
-- here so a scan that forgets to (re-)own the tooltip fails loudly instead of
-- silently reporting zero lines forever.
local tooltip = { n = 0, owned = false }
function tooltip:SetOwner() self.owned = true end
function tooltip:ClearLines()
    self.owned = false
    for _, side in ipairs({ "TextLeft", "TextRight" }) do
        for i = 1, self.n do
            local l = TipLine(side, i)
            l.text, l.r, l.g, l.b = nil, 1, 1, 1
        end
    end
    self.n = 0
end
function tooltip:SetHyperlink(link)
    if not self.owned then self.n = 0; return end
    local info = itemInfo[LinkID(link)]
    if not info then self.n = 0; return end       -- uncached: tooltip stays empty
    TipLine("TextLeft", 1).text = "Item"
    TipLine("TextLeft", 2).text = "Binds when equipped"
    TipLine("TextLeft", 3).text = info.equipSlot ~= "" and "Chest" or nil
    if info.red then
        local l = TipLine("TextLeft", 3)
        l.text, l.r, l.g, l.b = info.red, 1.0, 0.1, 0.1
    end
    if info.redRight then
        local l = TipLine("TextRight", 3)
        l.text, l.r, l.g, l.b = info.redRight, 1.0, 0.1, 0.1
    end
    self.n = 3
end
function tooltip:SetLootItem(slot)
    if not self.owned then self.n = 0; return end
    local e = lootItems[slot] or {}
    TipLine("TextLeft", 1).text = "Slot" .. slot
    TipLine("TextLeft", 2).text = e.quest
    self.n = e.quest and 2 or 1
end
function tooltip:NumLines() return self.n end

---------------------------------------------------------------- corpse loot
-- lootItems[slot] = { coin =, quality =, itemID =, quest =, locked = }
function GetNumLootItems() return #lootItems end
function GetLootSlotInfo(slot)
    local e = lootItems[slot]
    if not e then return nil end
    return "tex", "Slot" .. slot, 1, e.quality, e.locked
end
function GetLootSlotLink(slot)
    local e = lootItems[slot]
    if e then return e.itemID and ("|Hitem:" .. e.itemID .. ":0|h[Slot" .. slot .. "]|h") or nil end
    return lootSlots[slot]
end
function LootSlotIsCoin(slot) return lootItems[slot] and lootItems[slot].coin end
function LootSlot(slot) table.insert(looted, slot) end
function CloseLoot() lootClosed = lootClosed + 1 end

function hooksecurefunc(name, hook)
    local orig = _G[name]
    _G[name] = function(...) orig(...); hook(...) end
end

local frame = { scripts = {}, events = {} }
function frame:RegisterEvent(e) self.events[e] = true end
function frame:SetScript(k, fn) self.scripts[k] = fn end
function CreateFrame(kind, name, parent, template)
    if template == "GameTooltipTemplate" then return tooltip end
    return frame
end

----------------------------------------------------------------- test drivers
local function fire(event, a, b) frame.scripts.OnEvent(frame, event, a, b) end

local function advance(seconds, step)
    step = step or 0.1
    local left = seconds
    while left > 0 do
        local d = math.min(step, left)
        clock = clock + d
        if frame.scripts.OnUpdate then frame.scripts.OnUpdate(frame, d) end
        left = left - d
    end
end

local function reset(cfg)
    chat, popupsHidden, confirmed, submitted, rolls = {}, {}, {}, {}, {}
    lootItems, looted, lootClosed = {}, {}, 0
    cvars.autoLootDefault = "0"
    inInstance, raidMembers = true, 0
    clock = clock + 300               -- push past any TTL from the last test
    fire("PLAYER_ENTERING_WORLD")
    for k, v in pairs(cfg or {}) do AutoRollLiteDB[k] = v end
end

local function drop(id, quality, opts)
    opts = opts or {}
    rolls[id] = {
        name = "Item" .. id, quality = quality,
        bop = opts.bop, link = opts.link ~= false and ("|Hitem:" .. (opts.itemID or (5000 + id)) .. ":0|h[Item" .. id .. "]|h") or nil,
        canNeed = opts.canNeed ~= false and 1 or nil,
        canGreed = opts.canGreed ~= false and 1 or nil,
        canDE = opts.canDE and 1 or nil,
        rNeed = 0, rGreed = 0, rDE = 0,
    }
    fire("START_LOOT_ROLL", id, 60000)
end

local function only(id)
    local hits = {}
    for _, s in ipairs(submitted) do if s.id == id then table.insert(hits, s.type) end end
    return hits
end

------------------------------------------------------------------------- load
assert(loadfile("/Users/tony/GreedyPigPiggy/AutoRollLite/AutoRollLite.lua"))()
fire("ADDON_LOADED", "AutoRollLite")
check("loads and seeds SavedVariables", type(AutoRollLiteDB) == "table" and AutoRollLiteDB.needQuality == 3)
check("registers all five events", frame.events.START_LOOT_ROLL and frame.events.CONFIRM_LOOT_ROLL
    and frame.events.CONFIRM_DISENCHANT_ROLL and frame.events.PLAYER_ENTERING_WORLD and frame.events.ADDON_LOADED)

print("\n-- AC1: green in a 5-man -> Greed within delay")
reset()
drop(1, 2)
advance(0.5)
check("nothing submitted before the delay elapses", #submitted == 0)
advance(0.5)
check("Greed submitted after delay", only(1)[1] == 2, only(1)[1])
check("exactly one submission", #only(1) == 1)

print("\n-- AC2: BoP blue, eligible -> Need + auto-confirm + popup dismissed")
reset()
drop(2, 3, { bop = 1 })
advance(1)
check("Need submitted on BoP blue", only(2)[1] == 1, only(2)[1])
fire("CONFIRM_LOOT_ROLL", 2, 1)
check("confirmation forwarded", confirmed[1] and confirmed[1].id == 2 and confirmed[1].type == 1)
check("popup hidden", popupsHidden[1] == "CONFIRM_LOOT_ROLL")

print("\n-- AC3: blue we cannot Need -> Greed, downgrade logged")
reset({ debug = true })
drop(3, 3, { canNeed = false })
advance(1)
check("downgraded to Greed", only(3)[1] == 2, only(3)[1])
local sawReason = false
for _, m in ipairs(chat) do if string.find(m, "canNeed=false", 1, true) then sawReason = true end end
check("downgrade reason logged in debug", sawReason)
AutoRollLiteDB.debug = false

print("\n-- AC4: four simultaneous drops -> all rolled, staggered, none doubled")
reset()
local t0 = clock
drop(10, 2); drop(11, 3); drop(12, 4); drop(13, 2)
advance(3)
check("all four submitted", #submitted == 4, #submitted)
local seen = {}
for _, s in ipairs(submitted) do seen[s.id] = (seen[s.id] or 0) + 1 end
check("no double submissions", seen[10] == 1 and seen[11] == 1 and seen[12] == 1 and seen[13] == 1)
check("greens greed, blue/epic need", only(10)[1] == 2 and only(11)[1] == 1 and only(12)[1] == 1 and only(13)[1] == 2)
local times, spaced, burst = {}, true, false
for _, s in ipairs(submitted) do table.insert(times, s.at) end
table.sort(times)
for i = 2, #times do
    local gap = times[i] - times[i - 1]
    -- stagger 0.25 quantized to the 0.1s OnUpdate tick -> expect >= 0.25 - 0.1
    if gap < 0.15 then spaced = false end
    if gap == 0 then burst = true end
end
check("submissions are staggered, not bursted", spaced and not burst,
    string.format("%.2f %.2f %.2f %.2f", times[1] - t0, times[2] - t0, times[3] - t0, times[4] - t0))
check("first roll lands at ~delay", math.abs((times[1] - t0) - 0.75) <= 0.15, times[1] - t0)
print(string.format("      submission offsets: %.2f %.2f %.2f %.2f",
    times[1] - t0, times[2] - t0, times[3] - t0, times[4] - t0))

print("\n-- AC5: /arl off -> nothing submitted")
reset()
SlashCmdList["AUTOROLLLITE"]("off")
drop(4, 4)
advance(2)
check("master switch suppresses rolls", #submitted == 0, #submitted)
SlashCmdList["AUTOROLLLITE"]("on")

print("\n-- AC6: instanceOnly, player in open world -> nothing submitted")
reset({ instanceOnly = true })
inInstance = false
drop(5, 4)
advance(2)
check("open-world gate holds", #submitted == 0, #submitted)
inInstance = true

print("\n-- FR-7: raid gating")
reset({ raidEnabled = false })
raidMembers = 25
drop(6, 4)
advance(2)
check("raid suppressed by default", #submitted == 0, #submitted)
reset({ raidEnabled = true })
raidMembers = 25
drop(7, 4)
advance(2)
check("raid allowed when enabled", only(7)[1] == 1, only(7)[1])
raidMembers = 0

-- Enabling raids must not change 5-man behaviour: the raid gate is guarded by
-- GetNumRaidMembers() > 0, which is 0 in a party, so the flag is unreachable.
local partyResults = {}
for _, flag in ipairs({ false, true }) do
    reset({ raidEnabled = flag })
    raidMembers = 0                                  -- 5-man party
    drop(100, 2); drop(101, 3); drop(102, 4); drop(103, 0)
    advance(3)
    local sig = {}
    for _, s in ipairs(submitted) do table.insert(sig, s.id .. "=" .. s.type) end
    table.sort(sig)
    partyResults[tostring(flag)] = table.concat(sig, ",")
end
check("5-man behaviour identical with raid off and on",
    partyResults["false"] == partyResults["true"],
    "off=[" .. partyResults["false"] .. "] on=[" .. partyResults["true"] .. "]")
print("      party rolls either way: " .. partyResults["true"])

print("\n-- AC8: another addon rolls first -> defer, submit nothing")
reset()
drop(8, 4)
RollOnLoot(8, 2)                       -- the other addon acts during our delay
local before = #submitted
advance(2)
check("no roll of our own after deferral", #submitted == before, #submitted - before)
local deferred = false
for _, m in ipairs(chat) do if string.find(m, "deferred to another addon", 1, true) then deferred = true end end
check("deferral logged", deferred)

print("\n-- bind popup: LOOT_BIND_CONFIRM -> ConfirmLootSlot + hide LOOT_BIND")
reset()
slotsConfirmed, popupsHidden = {}, {}
lootSlots[3] = "|Hitem:40395:0|h[Torch of Holy Fire]|h"
fire("LOOT_BIND_CONFIRM", 3)
check("bind confirmed for the right slot", slotsConfirmed[1] == 3, slotsConfirmed[1])
check("LOOT_BIND popup hidden", popupsHidden[1] == "LOOT_BIND", popupsHidden[1])
local namedItem = false
for _, m in ipairs(chat) do if string.find(m, "Torch of Holy Fire", 1, true) then namedItem = true end end
check("bind confirmation names the item", namedItem)

print("\n-- bind popup respects gating and the toggle")
reset()
slotsConfirmed = {}
inInstance = false
fire("LOOT_BIND_CONFIRM", 3)
check("bind popup left alone in the open world", #slotsConfirmed == 0, #slotsConfirmed)
inInstance = true
reset({ autoConfirmBind = false })
slotsConfirmed = {}
fire("LOOT_BIND_CONFIRM", 3)
check("bind popup left alone when toggled off", #slotsConfirmed == 0, #slotsConfirmed)
reset({ autoConfirmBind = true })
slotsConfirmed = {}
SlashCmdList["AUTOROLLLITE"]("never 40395")
fire("LOOT_BIND_CONFIRM", 3)
check("blacklisted item still asks", #slotsConfirmed == 0, #slotsConfirmed)
SlashCmdList["AUTOROLLLITE"]("clear")
slotsConfirmed = {}
fire("LOOT_BIND_CONFIRM", 3)
check("confirms again once un-blacklisted", slotsConfirmed[1] == 3, slotsConfirmed[1])

print("\n-- FR-4: BoP confirmation arrives synchronously inside RollOnLoot")
-- The real 3.3.5 client raises CONFIRM_LOOT_ROLL from inside RollOnLoot when
-- you Need a BoP item -- it knows the item binds, so there is no server round
-- trip. Any ownership bookkeeping done *after* the RollOnLoot call is therefore
-- too late to recognise the confirmation as ours.
reset()
confirmed, popupsHidden = {}, {}
local realRoll = RollOnLoot
function RollOnLoot(id, t)
    realRoll(id, t)
    if rolls[id] and rolls[id].bop and t == 1 then fire("CONFIRM_LOOT_ROLL", id, t) end
end
drop(90, 3, { bop = 1 })
advance(1)
check("Need submitted on BoP blue", only(90)[1] == 1, only(90)[1])
check("synchronous confirmation is recognised as ours", confirmed[1] and confirmed[1].id == 90,
    confirmed[1] and confirmed[1].id or "never confirmed")
check("popup dismissed", popupsHidden[1] == "CONFIRM_LOOT_ROLL", popupsHidden[1])
RollOnLoot = realRoll

print("\n-- FR-4: confirmations for rolls we do not own are ignored")
reset()
confirmed = {}
fire("CONFIRM_LOOT_ROLL", 999, 1)
check("foreign confirmation ignored", #confirmed == 0, #confirmed)

print("\n-- FR-7: BoP protection downgrades Need to Greed")
reset({ bopProtection = true })
drop(20, 4, { bop = 1 })
advance(1)
check("BoP epic downgraded to Greed", only(20)[1] == 2, only(20)[1])
reset({ bopProtection = false })
drop(21, 4, { bop = 1 })
advance(1)
check("BoP epic still Need with protection off", only(21)[1] == 1, only(21)[1])

print("\n-- FR-2: fallback ladder bottom")
reset({ allowDisenchant = false })
drop(30, 3, { canNeed = false, canGreed = false })
advance(1)
check("no legal action -> nothing submitted (Pass left to user)", #submitted == 0, #submitted)
reset({ allowDisenchant = true })
drop(31, 3, { canNeed = false, canGreed = false, canDE = true })
advance(1)
check("disenchant used as last resort when enabled", only(31)[1] == 3, only(31)[1])
AutoRollLiteDB.allowDisenchant = false

print("\n-- FR-1: poor/common are not rolled on")
reset()
drop(40, 0); drop(41, 1)
advance(2)
check("poor and common left alone", #submitted == 0, #submitted)
reset({ autoPass = true })
drop(42, 0)
advance(2)
check("autoPass submits Pass when enabled", only(42)[1] == 0, only(42)[1])
AutoRollLiteDB.autoPass = false

print("\n-- FR-6: blacklist and whitelist by itemID")
reset()
SlashCmdList["AUTOROLLLITE"]("never 12345")
drop(50, 4, { itemID = 12345 })
advance(2)
check("blacklisted epic not rolled", #submitted == 0, #submitted)
SlashCmdList["AUTOROLLLITE"]("always 999 2")
drop(51, 4, { itemID = 999 })
advance(2)
check("whitelisted epic forced to Greed", only(51)[1] == 2, only(51)[1])
SlashCmdList["AUTOROLLLITE"]("clear")
check("clear empties both lists", next(AutoRollLiteDB.never) == nil and next(AutoRollLiteDB.always) == nil)

print("\n-- FR-5: link nil at decision time, arrives before execution")
reset()
drop(60, 4, { link = false, itemID = 777 })
rolls[60].link = "|Hitem:777:0|h[LateItem]|h"      -- link resolves a moment later
advance(2)
check("still rolls with a late link", only(60)[1] == 1, only(60)[1])
reset()
SlashCmdList["AUTOROLLLITE"]("never 888")
drop(61, 4, { link = false, itemID = 888 })
rolls[61].link = "|Hitem:888:0|h[LateBlacklisted]|h"
advance(2)
check("late link re-decides against the blacklist", #submitted == 0, #submitted)
SlashCmdList["AUTOROLLLITE"]("clear")

print("\n-- FR-9: queue hygiene")
reset()
drop(70, 4)
rolls[70] = nil                                     -- roll cancelled server-side
advance(2)
check("vanished roll is dropped, not submitted", #submitted == 0, #submitted)
reset()
drop(71, 4)
advance(2)
check("pending queue drains", true)

print("\n-- AC10: reload mid-dungeon clears state, config persists")
reset()
drop(80, 4)
fire("PLAYER_ENTERING_WORLD")
advance(3)
check("pending queue cleared on zone/reload", #submitted == 0, #submitted)
check("config survives", AutoRollLiteDB.needQuality == 3 and AutoRollLiteDB.instanceOnly == true)

print("\n-- FR-10: usable-gear-only rolling")
reset({ usableOnly = false })
itemInfo[6001] = { equipSlot = "INVTYPE_CHEST", red = "Plate" }
itemInfo[6002] = { equipSlot = "INVTYPE_CHEST" }
itemInfo[6003] = { equipSlot = "INVTYPE_CHEST", red = "Requires Level 80" }
-- the common real-world case: armour type sits in the tooltip's RIGHT column
itemInfo[6005] = { equipSlot = "INVTYPE_CHEST", redRight = "Leather" }
drop(200, 2, { itemID = 6001 })
advance(2)
check("off-class green still Greeded with the check off", only(200)[1] == 2, only(200)[1])

reset({ usableOnly = true })
drop(201, 2, { itemID = 6001 })
advance(2)
check("off-class green passed when usable-only is on", #submitted == 0, #submitted)

reset({ usableOnly = true })
drop(202, 3, { itemID = 6001 })
advance(2)
check("off-class blue downgraded Need -> Greed", only(202)[1] == 2, only(202)[1])

reset({ usableOnly = true })
drop(203, 2, { itemID = 6002 })
advance(2)
check("on-class green still Greeded", only(203)[1] == 2, only(203)[1])

reset({ usableOnly = true })
drop(204, 2, { itemID = 6003 })
advance(2)
check("red 'Requires Level' line is not treated as unusable", only(204)[1] == 2, only(204)[1])

reset({ usableOnly = true })
drop(205, 2, { itemID = 6099 })          -- not in the item cache at all
advance(2)
check("uncached item is not downgraded", only(205)[1] == 2, only(205)[1])

reset({ usableOnly = true })
SlashCmdList["AUTOROLLLITE"]("always 6001 1")
drop(206, 2, { itemID = 6001 })
advance(2)
check("whitelist outranks the usability check", only(206)[1] == 1, only(206)[1])
SlashCmdList["AUTOROLLLITE"]("clear")

reset({ usableOnly = true })
drop(208, 2, { itemID = 6005 })
advance(2)
check("off-class armour type in the RIGHT column is caught", #submitted == 0, #submitted)

reset({ usableOnly = true })
drop(209, 3, { itemID = 6005 })
advance(2)
check("right-column blue downgraded Need -> Greed", only(209)[1] == 2, only(209)[1])

reset({ usableOnly = true })
itemInfo[6004] = { equipSlot = "", red = "Plate" }   -- red line but no equip slot
drop(207, 2, { itemID = 6004 })
advance(2)
check("non-equippable item skips the tooltip scan", only(207)[1] == 2, only(207)[1])
AutoRollLiteDB.usableOnly = false

print("\n-- FR-11: corpse loot filter")
reset({ lootFilter = false })
lootItems = { { quality = 0, itemID = 7001 }, { quality = 3, itemID = 7002 } }
fire("LOOT_OPENED", 0)
check("filter off leaves the loot window alone", #looted == 0 and lootClosed == 0, #looted)

reset({ lootFilter = true, lootQuality = 2 })
lootItems = {
    { coin = true },                       -- 1 money
    { quality = 0, itemID = 7001 },        -- 2 grey
    { quality = 1, itemID = 7002 },        -- 3 white
    { quality = 2, itemID = 7003 },        -- 4 green
    { quality = 4, itemID = 7004 },        -- 5 epic
    { quality = 1, itemID = 7005, quest = "Quest Item" },        -- 6 white quest item
    { quality = 1, itemID = 7006, quest = "This Item Begins a Quest" },  -- 7 quest starter
}
fire("LOOT_OPENED", 0)
local tookSlot = {}
for _, sl in ipairs(looted) do tookSlot[sl] = true end
check("money always taken", tookSlot[1])
check("grey left on the corpse", not tookSlot[2])
check("white left on the corpse", not tookSlot[3])
check("green taken", tookSlot[4])
check("epic taken", tookSlot[5])
check("white quest item taken anyway", tookSlot[6])
check("white quest starter taken anyway", tookSlot[7])
check("took exactly five slots", #looted == 5, #looted)
check("loot window closed once", lootClosed == 1, lootClosed)

reset({ lootFilter = true, lootQuality = 3 })
lootItems = { { quality = 2, itemID = 7003 }, { quality = 3, itemID = 7004 } }
fire("LOOT_OPENED", 0)
check("lootq 3 leaves greens behind too", #looted == 1 and looted[1] == 2, #looted)

reset({ lootFilter = true, lootQuality = 2 })
SlashCmdList["AUTOROLLLITE"]("never 7004")
SlashCmdList["AUTOROLLLITE"]("always 7001 2")
lootItems = { { quality = 0, itemID = 7001 }, { quality = 4, itemID = 7004 } }
fire("LOOT_OPENED", 0)
check("whitelisted grey is taken", looted[1] == 1 or looted[2] == 1)
check("blacklisted epic is left", not (looted[1] == 2 or looted[2] == 2))
SlashCmdList["AUTOROLLLITE"]("clear")

reset({ lootFilter = true, lootQuality = 2 })
lootItems = { { quality = 2, itemID = 7003, locked = 1 } }
fire("LOOT_OPENED", 0)
check("locked slot skipped", #looted == 0, #looted)

reset({ lootFilter = true, lootQuality = 2, lootClose = false })
lootItems = { { quality = 4, itemID = 7004 } }
fire("LOOT_OPENED", 0)
check("window left open when lootshut is off", lootClosed == 0, lootClosed)

reset({ lootFilter = true, lootQuality = 2 })
cvars.autoLootDefault = "1"
lootItems = { { quality = 4, itemID = 7004 } }
fire("LOOT_OPENED", 1)
check("client autoloot is switched off when it beats the filter",
    cvars.autoLootDefault == "0", cvars.autoLootDefault)
local told = false
for _, m in ipairs(chat) do if string.find(m, "turned it off", 1, true) then told = true end end
check("and the user is told it happened", told)

reset({ lootFilter = true, lootQuality = 2 })
lootItems = { { quality = 4, itemID = 7004 } }
fire("LOOT_OPENED", 1)                        -- autolooted, but the cvar reads off
local warned = false
for _, m in ipairs(chat) do if string.find(m, "something auto-looted", 1, true) then warned = true end end
check("warns when something else auto-loots and the cvar is already off", warned)

reset({ lootFilter = false })
cvars.autoLootDefault = "1"
SlashCmdList["AUTOROLLLITE"]("loot on")
check("/arl loot on switches client autoloot off immediately",
    cvars.autoLootDefault == "0", cvars.autoLootDefault)
AutoRollLiteDB.lootFilter = false

reset({ lootFilter = true })
SlashCmdList["AUTOROLLLITE"]("off")
lootItems = { { quality = 4, itemID = 7004 } }
fire("LOOT_OPENED", 0)
check("master switch also stops the loot filter", #looted == 0, #looted)
SlashCmdList["AUTOROLLLITE"]("on")

print("\n-- FR-11: a filtered pickup clears its own bind popup in the open world")
reset({ lootFilter = true, instanceOnly = true, autoConfirmBind = true })
slotsConfirmed = {}
inInstance = false
lootItems = { { quality = 4, itemID = 7004 } }
fire("LOOT_OPENED", 0)
fire("LOOT_BIND_CONFIRM", 1)
check("bind popup cleared for a filter-initiated pickup", slotsConfirmed[1] == 1, slotsConfirmed[1])
inInstance = true
AutoRollLiteDB.lootFilter = false

print("\n-- slash surface does not error")
reset()
local cmds = { "", "help", "status", "need 4", "greed 3", "delay 2", "stagger 0.5",
    "instance off", "instance on", "raid on", "raid off", "bop on", "bop off",
    "de on", "de off", "autopass on", "autopass off", "quiet on", "quiet off",
    "loot on", "loot off", "lootshut on", "lootshut off", "usable on", "usable off",
    "lootq 3", "lootq 2", "lootq 99", "check", "check 6005", "check 6099",
    "debug on", "debug off", "never", "always 5", "need 99", "delay 99", "bogus" }
local allOk = true
for _, c in ipairs(cmds) do
    local ok, err = pcall(SlashCmdList["AUTOROLLLITE"], c)
    if not ok then allOk = false; print("      errored on '" .. c .. "': " .. tostring(err)) end
end
check("every slash command runs without error", allOk)
SlashCmdList["AUTOROLLLITE"]("need 3")
SlashCmdList["AUTOROLLLITE"]("delay 0.75")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
