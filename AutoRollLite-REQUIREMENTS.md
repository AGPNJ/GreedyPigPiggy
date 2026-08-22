# AutoRollLite — Requirements Spec

**Target:** World of Warcraft 3.3.5a (WotLK) client, AzerothCore private server with mod-playerbots
**Type:** Client-side Lua addon (no server component)
**Goal:** Automatically roll Need on rare/epic loot and Greed on uncommon loot, with zero interference to other running addons (notably a dungeon-clear/playerbot control addon).

---

## 1. Environment Constraints

These are hard constraints. Do not use modern retail API.

- Lua 5.1. No `C_Timer`, no `C_LootRoll`, no `GetLootRollItemInfo` returning a table.
- No `table.wipe` guarantee — use `wipe()` (exists in 3.3.5) or manual clear.
- TOC interface number: `30300`.
- Events fire as `OnEvent(self, event, ...)` — arguments are varargs, not globals (`this`/`arg1` style is 2.x and must not be used).
- `print()` exists. Prefer `DEFAULT_CHAT_FRAME:AddMessage()` for colored output.
- No external libraries (no Ace3, no LibStub). Single-file, dependency-free.

---

## 2. API Contract

### Events to register

| Event | Args | Purpose |
|---|---|---|
| `START_LOOT_ROLL` | `rollID, rollTime` | A group loot roll opened for the player |
| `CONFIRM_LOOT_ROLL` | `rollID, rollType` | Server wants confirmation (BoP Need, or DE) |
| `CONFIRM_DISENCHANT_ROLL` | `rollID, rollType` | Disenchant confirmation |
| `PLAYER_ENTERING_WORLD` | — | Init / cleanup pending queue |
| `ADDON_LOADED` | `addonName` | Load SavedVariables |

### Functions

```lua
texture, name, count, quality, bindOnPickUp,
canNeed, canGreed, canDisenchant,
reasonNeed, reasonGreed, reasonDisenchant,
deSkillRequired = GetLootRollItemInfo(rollID)

link = GetLootRollItemLink(rollID)          -- may be nil for a few frames
timeLeftMs = GetLootRollTimeLeft(rollID)
RollOnLoot(rollID, rollType)                -- 0=Pass 1=Need 2=Greed 3=Disenchant
ConfirmLootRoll(rollID, rollType)
```

**Item quality values:** `0` Poor, `1` Common, `2` Uncommon (green), `3` Rare (blue), `4` Epic (purple), `5` Legendary, `6` Artifact, `7` Heirloom.

**Note:** `bindOnPickUp` may return `1`/`nil` rather than `true`/`false` on this client. Coerce with truthiness checks, never `== true`.

---

## 3. Functional Requirements

### FR-1: Decision matrix

Given a roll, compute a *desired* action from quality, then resolve it against what the server actually permits.

Default desired action by quality (all configurable):

| Quality | Desired |
|---|---|
| 0 Poor | Pass |
| 1 Common | Pass |
| 2 Uncommon | Greed |
| 3 Rare | **Need** |
| 4 Epic | **Need** |
| 5 Legendary | **Need** |
| 6 Artifact / 7 Heirloom | Need |

### FR-2: Fallback ladder

`canNeed` / `canGreed` are frequently false (need-before-greed rules, armor class restrictions, BoE items, core-specific quirks). Never call `RollOnLoot` with an action the server has flagged as unavailable — resolve downward:

```
Need    -> if not canNeed  -> Greed
Greed   -> if not canGreed -> (Disenchant if enabled and canDisenchant) -> Pass
Disench -> if not canDisenchant -> Greed -> Pass
Pass    -> always legal
```

Log the downgrade in debug mode with the `reasonNeed` / `reasonGreed` code so the user can diagnose.

### FR-3: Deferred, staggered execution

Do **not** roll inside the `START_LOOT_ROLL` handler.

- Push `{rollID, quality, decidedAt}` into a pending queue.
- Fire after `db.delay` seconds (default `0.75`, range `0`–`5`).
- When multiple rolls are pending, stagger execution by `db.stagger` seconds each (default `0.25`) so simultaneous drops don't burst packets.
- Implement with a single hidden frame + `OnUpdate` accumulator. One frame total for the whole addon; do not create a frame per roll.

### FR-4: Confirmation handling

On `CONFIRM_LOOT_ROLL(rollID, rollType)`:
- If `rollID` is one *we* initiated (tracked in `self.ours[rollID]`), call `ConfirmLootRoll(rollID, rollType)` and then `StaticPopup_Hide("CONFIRM_LOOT_ROLL")`.
- If it is **not** one we initiated, do nothing — the user or another addon owns it.

Same logic for `CONFIRM_DISENCHANT_ROLL` with `StaticPopup_Hide("CONFIRM_LOOT_ROLL")` (3.3.5 reuses that popup id; verify against your client's `StaticPopup.lua` and adjust if the DE popup uses a distinct key).

### FR-5: Item link resolution with retry

`GetLootRollItemLink(rollID)` can return `nil` immediately after the event. Since the decision only needs `quality` (available immediately from `GetLootRollItemInfo`), the link is for **logging and blacklist matching only**. If nil at decision time, retry once at execution time; if still nil, proceed with the roll and log by name.

### FR-6: Blacklist / whitelist by itemID

- `db.never[itemID] = true` → always Pass regardless of quality.
- `db.always[itemID] = 1|2|3` → force that roll type (still subject to FR-2 fallback).
- Parse itemID out of the link with `string.match(link, "item:(%d+)")`.
- Slash commands to add the item currently under the cursor or by explicit ID.

### FR-7: Scope gating

Config toggles, all default to the permissive value unless noted:

- `db.enabled` — master switch (default `true`)
- `db.instanceOnly` — only auto-roll when `IsInInstance()` is true (default **`true`**; this is the safest default for a dungeon-farming use case and prevents embarrassing behavior in a pug in the open world)
- `db.raidEnabled` — auto-roll while in a raid group (default **`false`**)
- `db.bopProtection` — never Need on BoP items; downgrade to Greed (default `false`, but expose it prominently — some users want this)
- `db.allowDisenchant` — permit DE as a fallback (default `false`)

### FR-8: Conflict avoidance with other addons

This is a primary requirement, not a nice-to-have. The addon must be provably inert with respect to the dungeon-clear addon.

**Must do:**
- `hooksecurefunc("RollOnLoot", function(rollID, rollType) externalRolls[rollID] = rollType end)` — records every roll made through the API by anyone. Before executing a pending roll, check `externalRolls[rollID]`; if set and it wasn't set by us, **abort and log** ("deferred to another addon").
- Track our own calls with an `inFlight` flag so our own `RollOnLoot` doesn't register as external.
- Bail out of `CONFIRM_*` handling for rolls we don't own (FR-4).

**Must NOT do:**
- No `SetScript` on any Blizzard frame.
- No modification, hiding, reparenting, or reskinning of `GroupLootFrame1`–`4`, `LootFrame`, or any `StaticPopup` frame beyond the single documented `StaticPopup_Hide` call in FR-4.
- No secure/protected frame interaction of any kind (this addon touches nothing that can taint).
- No global namespace pollution — exactly one global: `AutoRollLiteDB` (SavedVariables) and one addon table.
- No `RegisterEvent` on any CHAT_MSG_* event.
- No keybindings, no macro creation, no `SendChatMessage`.
- No `UIParent` visual elements except an optional minimal status frame that is hidden by default.

### FR-9: Queue hygiene

- Drop a pending entry if `GetLootRollItemInfo(rollID)` returns nil at execution time (roll expired or was cancelled).
- Expire entries older than 65 seconds regardless.
- Clear `ours`, `externalRolls`, and the pending queue on `PLAYER_ENTERING_WORLD`.
- Cap `externalRolls` growth: prune entries older than 120s on each queue tick.

---

## 4. Configuration & Commands

SavedVariables: `AutoRollLiteDB` (account-wide is fine; per-character optional).

Slash commands under `/arl` (and alias `/autoroll`):

```
/arl                       -- print current config summary
/arl on | off              -- master toggle
/arl need <quality>        -- set minimum quality that gets Need (default 3)
/arl greed <quality>       -- set minimum quality that gets Greed (default 2)
/arl delay <seconds>       -- roll delay, 0-5
/arl instance on|off       -- instanceOnly gate
/arl raid on|off           -- allow in raid groups
/arl bop on|off            -- BoP protection
/arl de on|off             -- allow disenchant fallback
/arl never <itemID>        -- blacklist
/arl always <itemID> <1|2> -- force need(1)/greed(2)
/arl clear                 -- clear both lists
/arl debug                 -- toggle verbose logging
/arl status                -- dump pending queue + last 10 decisions
```

Config migration: store `db.version`; if absent, seed defaults. Never assume a key exists — always `if db.x == nil then db.x = default end`.

---

## 5. Output / Logging

- **Normal mode:** one short colored line per roll — `[AutoRoll] Need on [Item Link]`. Suppressible with `db.quiet`.
- **Debug mode:** log the full decision trace — quality, canNeed/canGreed/canDisenchant, reason codes, chosen action, any downgrade, and execution timestamp.
- Keep a rolling in-memory log of the last 20 decisions for `/arl status`.

---

## 6. File Layout

```
Interface/AddOns/AutoRollLite/
  AutoRollLite.toc
  AutoRollLite.lua
```

TOC:
```
## Interface: 30300
## Title: AutoRollLite
## Notes: Auto Need on rare/epic, Greed on uncommon. Lightweight, no taint.
## Author: <you>
## Version: 1.0.0
## SavedVariables: AutoRollLiteDB

AutoRollLite.lua
```

Single file. Target under 350 lines including comments.

---

## 7. Code Structure (suggested)

```lua
local ADDON = "AutoRollLite"
local A = {}                      -- addon table, file-local
local f = CreateFrame("Frame")    -- the one and only frame

-- state
A.pending  = {}   -- [rollID] = {quality=, at=, action=}
A.ours     = {}   -- [rollID] = rollType we submitted
A.external = {}   -- [rollID] = {type=, at=}  set by hooksecurefunc
A.inFlight = false
A.log      = {}   -- ring buffer, last 20

-- pure decision function, unit-testable in isolation
function A:Decide(quality, canNeed, canGreed, canDisenchant, bop, itemID)
    -- returns rollType (0-3), reasonString
end

function A:Enqueue(rollID, rollTime) end
function A:Execute(rollID) end
function A:OnUpdate(elapsed) end
```

Keep `A:Decide` free of side effects and of any WoW API calls — it takes primitives and returns a number. That makes it the one thing you can reason about and test without logging into the game.

---

## 8. Acceptance Criteria

1. A green drops in a 5-man → Greed is submitted within `delay ± stagger`, no popup remains on screen.
2. A BoP blue drops and player is eligible → Need submitted, confirmation dialog auto-accepted and dismissed, roll registers server-side.
3. A blue drops that the player cannot Need (`canNeed == false`) → Greed submitted, downgrade logged.
4. Four items drop simultaneously → all four rolled, staggered, none dropped or double-submitted.
5. `/arl off` → no rolls submitted, default UI behaves exactly as vanilla.
6. `db.instanceOnly` on, player in open world → no rolls submitted.
7. Dungeon-clear addon runs a full instance with AutoRollLite loaded → no Lua errors, no visual changes to its frames, no behavior change in its pathing/combat logic.
8. If another addon rolls on a rollID first, AutoRollLite logs a deferral and submits nothing for that rollID.
9. `/console scriptErrors 1` enabled → zero errors across a full dungeon clear.
10. Reload UI mid-dungeon → config persists, pending queue clears cleanly, no orphaned state.

---

## 9. Testing Notes

- Enable `/console scriptErrors 1` before testing; 3.3.5 swallows errors silently otherwise.
- Set `delay` to `3` during first tests so you can watch the default UI frame appear and then get dismissed — confirms the roll actually landed rather than the frame timing out.
- Test with `bopProtection` both on and off; the BoP confirmation path is the most fragile part and the most likely place a core's behavior diverges from retail 3.3.5.
- Verify against your server's actual behavior: some AzerothCore configs alter need-before-greed rules or DE availability. If `reasonNeed` codes look wrong, dump them raw in debug mode rather than trusting the wiki's enum.

---

## 10. Explicit Non-Goals

- No loot-value logic, no item-level comparison, no stat weighting. Quality tier only.
- No UI panel, no Interface Options integration. Slash commands only.
- No group/raid coordination, no addon comms (`SendAddonMessage`).
- No handling of Master Loot, Free-For-All, or Round Robin — those don't generate `START_LOOT_ROLL`.
- No retail/Classic-Era compatibility.
