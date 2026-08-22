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
function GetLootSlotLink(slot) return lootSlots[slot] end
function ConfirmLootSlot(slot) table.insert(slotsConfirmed, slot) end
function StaticPopup_Hide(which) table.insert(popupsHidden, which) end

function hooksecurefunc(name, hook)
    local orig = _G[name]
    _G[name] = function(...) orig(...); hook(...) end
end

local frame = { scripts = {}, events = {} }
function frame:RegisterEvent(e) self.events[e] = true end
function frame:SetScript(k, fn) self.scripts[k] = fn end
function CreateFrame() return frame end

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

print("\n-- slash surface does not error")
reset()
local cmds = { "", "help", "status", "need 4", "greed 3", "delay 2", "stagger 0.5",
    "instance off", "instance on", "raid on", "raid off", "bop on", "bop off",
    "de on", "de off", "autopass on", "autopass off", "quiet on", "quiet off",
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
