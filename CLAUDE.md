# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

`AutoRollLite-REQUIREMENTS.md` is the authoritative source of truth — every behavior traces to an FR/AC number in it, and code comments cite those numbers. Read it before changing behavior. Not a git repository.

```
AutoRollLite/AutoRollLite.lua    the whole addon (~400 lines)
AutoRollLite/AutoRollLite.toc
test/test_autoroll.lua           offline harness, not shipped to the client
```

## What this is

AutoRollLite — a client-side World of Warcraft **3.3.5a (WotLK)** Lua addon targeting an AzerothCore private server running mod-playerbots. It auto-rolls Need on rare/epic loot and Greed on uncommon loot. No server component, no build step, no test framework, no package manager.

## Hard environment constraints

These are the constraints most likely to be violated by anyone writing from modern-WoW muscle memory. Details and rationale in §1–§2 of the spec.

- **Lua 5.1.** No `C_Timer`, no `C_LootRoll`, no namespaced `C_*` API at all. Timing must go through a single hidden frame's `OnUpdate` accumulator.
- Interface version is `30300`. Retail/Classic-Era API does not exist here and must not be used.
- Events fire as `OnEvent(self, event, ...)` with varargs — never the 2.x `this`/`arg1` globals.
- `GetLootRollItemInfo(rollID)` returns a flat 12-value tuple, not a table.
- `bindOnPickUp` returns `1`/`nil`, not booleans — use truthiness, never `== true`.
- No external libraries. No Ace3, no LibStub. Single file, dependency-free, target under 350 lines.

## Architecture requirements that span the whole file

The spec's §7 sketches the structure; these are the invariants that make the design work:

- **One frame for the entire addon.** Not one per roll. It owns event registration and the `OnUpdate` tick that drains the pending queue.
- **Never roll inside the `START_LOOT_ROLL` handler.** Decisions are enqueued and executed later (`db.delay`, default 0.75s), staggered by `db.stagger` (default 0.25s) so simultaneous drops don't burst packets.
- **`A:Decide` must stay pure** — primitives in, roll type out, zero WoW API calls, zero side effects, no logging. It is the only part of the addon testable outside the game client. The FR-10 usability verdict is computed impurely at enqueue time and handed in as a tri-state primitive precisely to keep this true.
- **The fallback ladder (FR-2) is mandatory.** `canNeed`/`canGreed` are false far more often than intuition suggests on this core. Never call `RollOnLoot` with an action the server flagged unavailable; resolve downward Need→Greed→(DE)→Pass.

## Conflict avoidance is a primary requirement, not polish

FR-8 exists because this addon must coexist with a dungeon-clear/playerbot control addon. Treat its "Must NOT do" list as inviolable: no `SetScript` on Blizzard frames, no touching `GroupLootFrame1`–`4` / `LootFrame` / `StaticPopup` beyond the one documented `StaticPopup_Hide` call, no secure-frame interaction, no `CHAT_MSG_*` registration, no addon comms, exactly one global (`AutoRollLiteDB`).

The ownership model that enforces this: `hooksecurefunc("RollOnLoot", ...)` records every roll anyone makes; an `inFlight` flag distinguishes our own calls; pending rolls abort if another addon got there first; `CONFIRM_*` events are ignored for rolls we don't own.

## Testing

`test/test_autoroll.lua` stubs the entire 3.3.5 client API (`CreateFrame`, `GetLootRollItemInfo`, `hooksecurefunc`, a controllable `GetTime` clock, …) and drives the addon through its real entry points — the frame's `OnEvent`/`OnUpdate` scripts and `SlashCmdList`. It covers the §8 acceptance criteria plus the fallback ladder, gating, black/whitelist, and late-link paths.

```bash
lua test/test_autoroll.lua     # 38 assertions; exits non-zero on failure
luac -p AutoRollLite/AutoRollLite.lua
```

Run it after any change to `A:Decide`, the queue, or the ownership logic. Note it runs under whatever `lua` is installed (5.4/5.5), not 5.1 — so it catches logic and syntax errors but will *not* catch use of a modern stdlib function that 3.3.5's Lua 5.1 lacks. Check those by eye.

Timing assertions must tolerate tick quantization: fire times are exact, but the `OnUpdate` throttle is 0.1s, so a 0.25s stagger produces observed gaps of 0.2–0.3s.

## In-game notes

The WoW client is on a **separate Windows machine**, not this Mac — it's already installed and wired up there, so treat in-game verification as something the user runs, not something you can do or need to give setup steps for.

- Run `/console scriptErrors 1` before any testing — 3.3.5 silently swallows Lua errors otherwise.
- Set `delay` to `3` for first runs so the default UI frame is visibly dismissed, confirming the roll landed rather than timing out.
- Reload with `/reload`; slash commands are `/arl` (alias `/autoroll`), documented in §4.
- §8 of the spec lists 10 acceptance criteria — use them as the test plan.
- AzerothCore configs can alter need-before-greed rules and DE availability. When `reasonNeed`/`reasonGreed` codes look wrong, dump them raw in debug mode rather than trusting wiki enums.

## Two features that read the tooltip instead of the API

3.3.5 cannot answer either of these questions through a function call, so both go through a hidden scanning tooltip that the addon creates lazily (`A:Tooltip`, global `AutoRollLiteScanTip`). It is ours, never Blizzard's, so FR-8 holds.

- **FR-10 "can this character wear it?"** — `GetItemInfo` returns *localised* class/subclass strings and no numeric `itemClassID` on this client, so a hardcoded "Warlock → Cloth" table breaks on any non-enUS client. The client paints the failed requirement red in the tooltip; scan for a red line instead, since colour is locale-independent (`RED_FONT_COLOR` is `{1.0, 0.1, 0.1}`). Exclude the `ITEM_MIN_LEVEL` line — that requirement fixes itself. Verdict is tri-state and **`nil` (uncached, or an empty tooltip) must never downgrade**.
  - **Scan `TextRight` as well as `TextLeft`.** The equip location is in the left column and the armour type is in the **right** one on the same line — "Chest" left, "Leather" right — and the right-hand text is what reddens. A left-only scan catches "Classes: Warlock" but misses every armour-type mismatch, so the feature looks switched on and does nothing. This shipped once; `test_autoroll.lua` now has two regression tests that fail if the right column is dropped.
- **FR-11 "is this a quest item?"** — `GetLootSlotInfo` on 3.3.5 returns exactly **five** values (`texture, name, quantity, quality, locked`). There is no `isQuestItem`/`questId`; those arrived in a later expansion, and writing from modern muscle memory produces code that silently returns nil. Since quest items are white, a "skip white" filter would then break quest progress. Read `ITEM_BIND_QUEST` / `ITEM_STARTS_QUEST` off `GameTooltip:SetLootItem(slot)` instead.

The test harness stubs `GetLootSlotInfo` with exactly five returns for this reason. Do not widen it.

## The loot filter needs the client's autoloot OFF

`db.lootFilter` makes the addon a selective autoloot. If the client's own autoloot is enabled it has already taken everything before `LOOT_OPENED` reaches us, and the filter is a silent no-op. The addon warns once per session when it sees the autoloot flag set. Unlike rolling, the filter is **not** gated by `instanceOnly` — bags fill fastest in the open world.

## Playerbot inventories are out of reach

Bot looting is decided server-side in mod-playerbots. `NormalLootStrategy::CanLoot` accepts anything whose `ItemUsageValue` is not `ITEM_USAGE_NONE`, and that classifier ends in a catch-all tagging any item with a sell price as `ITEM_USAGE_VENDOR`/`ITEM_USAGE_AH` — so **every grey passes under "normal"**. The other strategies only widen it. No strategy excludes greys and no config option does either. Whisper `s gray` near a vendor to sell, or `nc -loot` to stop a bot looting. No client addon can change this.

## The two "will bind it to you" popups

3.3.5 shows the same `LOOT_NO_DROP` text ("Looting this item will bind it to you.") for two unrelated popups, which makes them easy to conflate when one leaks through:

| Popup | Event | Fires when | Cleared with |
|---|---|---|---|
| `CONFIRM_LOOT_ROLL` | `CONFIRM_LOOT_ROLL(rollID, rollType)` | you *roll* Need on a BoP item | `ConfirmLootRoll(rollID, rollType)` |
| `LOOT_BIND` | `LOOT_BIND_CONFIRM(slot)` | you *pick the item up* | `ConfirmLootSlot(slot)` |

They take different arguments and different clearing functions — `ConfirmLootRoll` will not dismiss the `LOOT_BIND` popup. Handled by `A:Confirm` and `A:ConfirmBind` respectively. Both go through `A:Allowed()`, so `instanceOnly` and the master switch govern them too.

## Deliberate deviations from the spec

- **`db.autoPass` (default `false`)** — the spec's decision matrix says "Pass" for poor/common but never says whether to *submit* Pass or simply not act. Default is to leave the frame alone so the player still has a choice; set `autoPass on` to actively submit Pass. A blacklisted item is never rolled on either way.
- **`SLASH_AUTOROLLLITE1`/`2` globals** — FR-8's "exactly one global" can't be honored literally; the slash API requires these. `SlashCmdList` is a Blizzard table, so indexing it adds no global.
- **`/arl stagger <s>`** — `db.stagger` was configurable per FR-3 but had no listed command.
- **`LOOT_BIND_CONFIRM` handling (`db.autoConfirmBind`, default `true`)** — the spec's event table stops at the roll confirmations, but the pickup-time bind popup still interrupts a dungeon clear. Scoped by `A:Allowed()` and skipped for `db.never` items, so `/arl never` still means "ask me". Turn off with `/arl bind off`. One exception to the scoping: a pickup the FR-11 filter made in the last 2 seconds clears its own popup regardless, since the filter runs outside instances and would otherwise strand the popup on screen.
- **`## IconTexture` in the TOC** — retail-only directive, silently ignored by 3.3.5. Harmless, kept for tooling.
- **The scanning tooltip's globals** — `CreateFrame("GameTooltip", "AutoRollLiteScanTip", …, "GameTooltipTemplate")` creates `AutoRollLiteScanTip` plus its `…TextLeft<n>` children. FR-8's "exactly one global" cannot survive contact with FR-10 and FR-11; both need tooltip text, and reading it requires a named frame. Created lazily, so a session that never enables either feature never makes them.
- **Line count** — the spec targets "under 350 lines". FR-10 and FR-11 put the file near 600. The single-file, dependency-free constraint still holds; the line target does not.

## Non-goals

No item-level or stat comparison (quality tier only), no UI panel or Interface Options integration, no addon comms, no Master Loot / FFA / Round Robin handling, no retail or Classic-Era compatibility.

No auto-selling and no auto-deleting: declined loot is left on the corpse, never destroyed. No reach into playerbot inventories.
