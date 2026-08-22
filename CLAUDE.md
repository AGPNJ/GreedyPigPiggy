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
- **`A:Decide` must stay pure** — primitives in, roll type out, zero WoW API calls, zero side effects, no logging. It is the only part of the addon testable outside the game client.
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

## In-game installation

Copy `AutoRollLite/` into `Interface/AddOns/`. Then:

- Run `/console scriptErrors 1` before any testing — 3.3.5 silently swallows Lua errors otherwise.
- Set `delay` to `3` for first runs so the default UI frame is visibly dismissed, confirming the roll landed rather than timing out.
- Reload with `/reload`; slash commands are `/arl` (alias `/autoroll`), documented in §4.
- §8 of the spec lists 10 acceptance criteria — use them as the test plan.
- AzerothCore configs can alter need-before-greed rules and DE availability. When `reasonNeed`/`reasonGreed` codes look wrong, dump them raw in debug mode rather than trusting wiki enums.

## Deliberate deviations from the spec

- **`db.autoPass` (default `false`)** — the spec's decision matrix says "Pass" for poor/common but never says whether to *submit* Pass or simply not act. Default is to leave the frame alone so the player still has a choice; set `autoPass on` to actively submit Pass. A blacklisted item is never rolled on either way.
- **`SLASH_AUTOROLLLITE1`/`2` globals** — FR-8's "exactly one global" can't be honored literally; the slash API requires these. `SlashCmdList` is a Blizzard table, so indexing it adds no global.
- **`/arl stagger <s>`** — `db.stagger` was configurable per FR-3 but had no listed command.
- **`## IconTexture` in the TOC** — retail-only directive, silently ignored by 3.3.5. Harmless, kept for tooling.

## Non-goals

No item-level or stat comparison (quality tier only), no UI panel or Interface Options integration, no addon comms, no Master Loot / FFA / Round Robin handling, no retail or Classic-Era compatibility.
