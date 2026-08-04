# TooltipLib Compatibility Architecture

How TooltipLib coexists with every other mod that touches PZ's tooltip
pipeline. This is the abstraction layer over six releases of field incidents
(v1.4.1 → v1.6.0): each mechanism below exists because a specific mod class
broke a specific assumption, and each is named so future incidents can be
triaged as "which class is this?" instead of re-derived from scratch.

**Doctrine in one line:** *whoever owns the card, owns the card — TooltipLib
is a clean data provider in their layout when it isn't ours, and a careful
host when it is.* Survival is handled in code; load order only buys cosmetics.

---

## 1. The threat model: five classes of foreign tooltip mod

Every tooltip-touching mod on the Workshop falls into one of these classes.
The class — not the mod — determines what happens and which mechanism answers.

| # | Class | Behavior | Known members | Hazard | TooltipLib's answer |
|---|-------|----------|---------------|--------|---------------------|
| 1 | **Chaining wrapper** | Captures previous `ISToolTipInv.render`, calls it, adds drawing around it | CommonSenseReborn, Better Vanilla ALICE Backpacks, CleanHotBar | None — well-behaved | Nothing needed; chain composes |
| 2 | **Render replacer (bypasser)** | Replaces `render`, calls `item:DoTooltip()` directly or reimplements; never chains to its captured original on the active path | Tempo_PerfKit (measure-cache), Show Weapon Stats Plus (weapons) | Everything wrapped *inside* them goes dark silently | Load order (TL after them) keeps us live; **deferred append** when they own the card but still lay out the ObjectTooltip |
| 3 | **Own-panel renderer (full bypass)** | Replaces `render` AND draws its own ISPanel directly — never touches `self.tooltip` at all | Extensive Health Rework Evolved | Appending onto the stale ObjectTooltip reads back our own writes → unbounded vertical growth (the v1.4.2 incident) | **Laid-out detection + stand-down**: never seen laid out → suppress our content for that item |
| 4 | **Layout host (framework)** | Owns the card but exposes an injection surface (event / provider API) | StarlitLibrary (`onFillItemTooltip`), EuryTooltipController (`getRows`; ships in Better Clothing Info, WS 3604080281, id EURY_CLOTHINGINFO — verified 2026-08: installs at FILE LOAD so TooltipLib always wraps outside it; its default owner dispatches `item:DoTooltip` so non-clothing composes natively, clothing cards are BCI-owned → deferred append; installs once, never reclaims, no cycle risk) | Two frameworks both re-rendering = duplicate cards, flip-flop, misalignment | **Native adapter**: feed provider content into *their* layout; never fight for the card |
| 5 | **Reclaiming wrapper** | "Install late to win": periodically re-takes the render slot, re-capturing whatever is current as its fallback | MagicAccessories, Global Storage SiK | Mutual capture with any other wrapper → A↔B infinite recursion → stack overflow (the v1.6.0 incident) | **Boot-render cycle breaker** (depth guard); their own re-entry guards *cannot* break the loop, ours must |

Plus a sixth adversary that isn't a mod:

| # | Class | Behavior | Hazard | Answer |
|---|-------|----------|--------|--------|
| 6 | **Vanilla itself** | `render` calls `DoTooltip` TWICE (measure pass, then real pass after repositioning); `ISToolTipInv` is reused for non-items (FluidContainer via ISFluidBar); `OnGameStart` refires on every save load in one process | Double-drawn boxes at stale positions (v1.4.1); nil-calls that escape pcall, every frame (v1.5.3); stacked wrappers across reloads (v1.5.2) | **Measure-pass discipline**, **subject-type gate**, **idempotent install** |

Classification test for a new conflict report: grep the foreign mod for
`ISToolTipInv[.:]render` — then ask (a) does its replacement call the
captured original on the *normal* path? (no → class 2/3), (b) does it draw
through `self.tooltip` or its own panel? (own panel → class 3), (c) does it
have an event/provider API? (yes → class 4), (d) does it re-assert ownership
on a timer/event after install? (yes → class 5).

---

## 2. The mechanisms

All Layout-surface mechanisms live in `Hook.lua` inside
`installLayoutSurfaceHook` — one implementation, instantiated for both the
`item` (ISToolTipInv) and `itemSlot` (ISToolTipItemSlot) surfaces. The
Starlit adapter lives in `StarlitAdapter.lua`.

### 2.1 Per-render metatable swap (the foundation)

We never permanently replace `item.DoTooltip`. Each render: swap the wrapper
onto the item metatable → pcall the *next* render in the chain → restore,
guaranteed, even on error. Consequences:

- Any mod may hook `render` above or below us; when the chain eventually
  calls `item:DoTooltip()`, our dispatch fires — we don't care who called.
- Whether our wrapper fired is *evidence*, not assumption (see 2.2).
- Nothing we install outlives a single render call, so there is no
  permanent-hook fight to lose.

### 2.2 Ownership proof (`ourWrapperFired` + per-item ownership memory)

We only claim behaviors that require ownership (vanilla-box suppression for
the panel dress, owned-path caching) for an item whose render **provably
fired our wrapper**. Ownership is per-item and re-earned; it is never
assumed from "we installed a hook once." First hover of an owned item eats
one frame of vanilla box under the dress (invisible in the fade-in) rather
than ever blanking a foreign mod's panel.

### 2.3 Deferred append (classes 2 and 4-without-adapter)

When the chain ran but our wrapper never fired, a foreign renderer owns the
card. If it rendered *through* the ObjectTooltip, we append provider content
below its extent. The naive version of this destroyed itself twice; the
hardened version has four parts:

- **Laid-out detection** — snapshot `self.tooltip` ref + height before the
  chain; "the chain touched the tooltip this frame" = new ref or changed
  height. An *unchanged* height is our own last write, never a foreign extent.
- **Per-item foreign-extent memo** — persists across hovers (hosts with
  per-item layout caches never re-lay on re-hover) and is keyed by detail
  state (detail mode legitimately resizes).
- **Stand-down** — an item that has *never* been seen laid out is a class-3
  full bypass: append nothing, ever, for that item (`deferred_standdown`).
- **Thrash clamp** — extents swinging >30%/24px repeatedly means multiple
  mods are fighting over the card; after 3 swings the item is retired to
  plain vanilla for the session (`deferred_thrash`). Stability beats chrome.

### 2.4 Native adapters (class 4)

When a framework offers an injection surface, we use it and stand down from
rendering entirely. StarlitAdapter: listen to `onFillItemTooltip`, run active
item providers with `ctx.layout` bound to *Starlit's* layout — content lands
natively, correct alignment, one pass, authoritative height, zero inference.
`replacesVanilla` claimers stand down (the host already drew vanilla's rows).
If the event *doesn't* fire for an item (someone bypassed the host —
`starlit_fill_bypassed`), that item is re-routed through deferred append.

The adapter is the doctrine made concrete: injection surface > deferred
append > stand-down, in strict preference order.

### 2.5 Boot-render cycle breaker (class 5) — v1.6.0

Snapshot `ISToolTipInv.render` / `ISToolTipItemSlot.render` at **file load**
(before any OnGameStart patcher can install). Each installed wrapper is
depth-guarded: re-entry on the same call stack means the chain looped back
into us — a reclaiming wrapper captured our wrapper as its fallback while we
captured its wrapper as our original. Chaining again would recurse without
bound; instead we call the boot-time render (`render_cycle`). The outer
invocation's DoTooltip wrapper is still armed on the metatable, so provider
dispatch — including the reclaiming mod's own registered provider — still
renders. The crash degrades to a complete, normal tooltip.

Why the *other* mod's re-entry guard can't fix this: its escape path
delegates to its captured fallback, which *is* the other member of the loop.
Only an escape to something outside every capture graph — the boot render —
terminates. The depth counter is pcall-managed so a body error can never
stick it above zero (which would silently retire the hook).

### 2.6 Vanilla discipline (class 6)

- **Measure-pass gate**: every direct draw (accent, textures, container
  preview, detail hint, ellipsis, dress) checks `tooltip:isMeasureOnly()`;
  measurement/state phases run on both passes so heights stay correct.
- **Subject-type gate**: non-`InventoryItem` subjects (FluidContainer,
  Resource) go straight to the original render — first check, both surfaces.
- **Idempotent install**: wrap exactly once per Lua VM
  (`_itemHookInstalled`); OnGameStart refiring on save reload must not stack
  wrappers or reshuffle chain ownership. (Note: reclaimers *do* re-wrap per
  reload — one reason cycles were observed even in "safe" load orders after
  in-session mod-list changes. The cycle breaker covers it.)

### 2.7 Error containment

- Every provider phase is pcall'd; a provider error never takes down the
  tooltip or another provider.
- **Circuit breaker**: 10 *consecutive* errors disables a provider for the
  session; any successful run resets the count — on every dispatch path,
  including the Starlit adapter (the v1.5.2 cumulative-latch lesson: a path
  that can record errors must also record successes).
- **Fail-open chrome**: an error from a panel-dress `draw`/`active`/
  `ornaments` clears the dress for the session; vanilla boxes return next
  frame. Cosmetics are never worth a broken tooltip.
- **Keyed one-shot diagnostics** (`_logOnce`): every detected pattern logs
  exactly once per session under a stable key (see §4).

### 2.8 Single-slot chrome + consistency (dress-level compat)

One mod at a time owns the panel dress. The dress never engages on a
foreign-owned panel (ownership proof, §2.2), and the optional consistency
mode ("keep the tooltip skin alongside other tooltip frameworks", default
OFF) retires the dress session-wide the moment any deferrer is seen — every
tooltip matches rather than alternating dressed/vanilla.

---

## 3. The chain and load order

Wrap time maps inversely to chain depth: **earlier load = inner wrapper**.
File-load patchers (EHR, Starlit-on-require) wrap before any OnGameStart
patcher (TooltipLib, MagicAccessories, Tempo). Reclaimers end up outermost
regardless of list position.

Ideal ordering — owners inner, injectors middle, reclaimers outer:

```
mod list (top→bottom)          resulting chain (outer→inner)
─────────────────────          ─────────────────────────────
StarlitLibrary                 MagicAccessories   (reclaimer, self-promotes)
...other frameworks...           └─ TooltipLib    (injector, chains)
TooltipLib                            └─ Starlit  (card owner)
MagicAccessories                           └─ vanilla
```

- **TooltipLib after every other tooltip framework.** Covers both the
  bypasser case (class 2: only mods loaded after them stay live) and the
  host case (class 4: our wrapper stays in the executing chain, so accent/
  skin draw).
- **Reclaimers last.** Post-1.6.0 their position doesn't affect survival,
  but last = the boot chain already matches their steady state (no reclaim
  churn), and it is the crash-safe order for users still on TL ≤ 1.5.3.
- The only *enforceable* order in PZ is `require=` in mod.info; everything
  else is user discipline.

---

## 4. Diagnostic triage: log line → meaning → action

**This whole table is automated:** `TooltipLib.diagnose()` (Lua console) or
*Mod Options → TooltipLib → Run compatibility check* turns the session's
runtime evidence into an OK / MITIGATED / ACTION verdict with load-order
advice, cross-referenced against the user's actual mod list. An automatic
one-shot check ~2 minutes into each session logs a single warning when the
verdict is ACTION. The rows below are the manual version for log-readers.

All keys appear at most once per session; the itemSlot surface prefixes
`slot_`. `[TooltipLib]`-tagged in the debug log.

| Key | Detected pattern | Severity | Action |
|-----|------------------|----------|--------|
| `deferred_mode` | Foreign framework owns the card; appending below it | Info | None — working as designed |
| `deferred_standdown` | Class-3 full bypass (own-panel renderer) | Info | Provider content suppressed for its items — expected; identify the mod if users miss content |
| `deferred_thrash` | Multiple mods fighting over card extents | Warning | Affected items retired to vanilla; simplify the tooltip-mod stack |
| `render_cycle` | Class-5 mutual-capture loop, broken via boot render | Warning on fresh boot / Info after in-session mod-list changes | Fresh-boot occurrence: identify the reclaimer, suggest the BOOT_RENDER pattern to its author |
| `starlit_fill_bypassed` | Starlit present but its event didn't fire — something owns render outside it | Warning | Items re-routed through deferred append (one frame late); check load order, TL last |
| `render_chain_error` | The next render in the chain threw | Warning | The *foreign* mod errored; we restored state and logged — triage the named error |
| `layout_error` / `deferred_layout_error` | Layout API failed mid-dispatch | Error | Fell back to vanilla content; usually a PZ build change — check API probe lines |
| `dimension_error` | Tooltip setHeight/setWidth failed | Error | Same family as above |
| `starlit_render_error` | Render error under the Starlit adapter path | Warning | Check the named error; adapter continues |

Plus install-time lines: `... hook installed (N providers)` per surface
(absence = the probe failed; `getHookStatus()` returns per-surface status),
and `API probe passed (item/itemSlot)` once each.

---

## 5. Case files (the incidents that bred the mechanisms)

| Incident | Class | Root cause | Mechanism it produced |
|----------|-------|-----------|----------------------|
| Duplicate boxes in context menus (v1.4.1) | 6 | Direct draws ran on vanilla's measure pass; menus reposition between passes | Measure-pass discipline |
| EHR unbounded tooltip growth (v1.4.2) | 3 | Deferred append read back its own height writes from a never-touched ObjectTooltip | Laid-out detection + stand-down |
| Tempo "VPS tooltips gone" (2026-06) | 2 | Tempo's cache calls `item:DoTooltip()` directly, never chains; wrapped TL out of existence | "TL last" doctrine; deferred hardening |
| Starlit flip-flop / duplicate cards (v1.5.1) | 4 | Two frameworks both re-rendering the same card; innermost DoTooltip wrapper wins per load order | StarlitAdapter (native injection); consistency option |
| Breaker latch blanking a mod for the session (v1.5.2) | — | Adapter path recorded errors but never successes; 10 *cumulative* ≠ 10 *consecutive* | Success recording on every dispatch path |
| Fluid-bar nil-call spam (v1.5.3) | 6 | ISToolTipInv reused with a FluidContainer subject | Subject-type gate |
| MagicAccessories stack overflow (v1.6.0) | 5 | Mutual capture: their reclaim took our wrapper as fallback after we took theirs as original; their re-entry guard delegates back into the loop | Boot-render cycle breaker |
| ArmorMakesSense Burden rows invisible under Starlit (2026-08) | 2+5 hybrid | AMS re-takes the render slot per UI tick (reclaimer) and injects its rows via a per-render `DoTooltip` metatable swap — the same technique we use. Whoever swaps LAST wins the dispatch, and under Starlit nobody dispatches `DoTooltip` at all (Starlit builds via `DoTooltipEmbedded` + its event) — AMS's rows can't reach the surviving card in any load order. AMS only integrates with EuryTooltipController. | KNOWN_MODS note in diagnostics; author ask = register a TooltipLib provider (its Eury provider infra makes this ~15 lines) and skip the render patch when a framework owns the card |

Regression locks: `tests/` (run with `pz-test-kit/pztest` from the repo root) —
`test_tooltiplib_dress.lua`
(ownership, suppression, measure-pass, subject gate), `test_tooltiplib_starlit.lua`
(adapter contract), `test_tooltiplib_magicacc.lua` (item-surface cycle),
`test_tooltiplib_slot.lua` (itemSlot surface characterization + cycle).

---

## 6. Advice we give other mod authors

When a conflicting mod's author is receptive, the asks in preference order:

1. **Best: register a TooltipLib provider** and don't touch `render` at all
   when TooltipLib is present. Their content joins the managed pipeline —
   ordering, caching, error isolation, and every host adapter for free.
2. **Good: chain honestly.** Capture the previous render at install time,
   call it on every path, add drawing around it. Never re-capture later.
3. **If they must reclaim: escape to a boot snapshot.** A re-entry guard
   whose escape path is `return fallback_render(self)` *feeds* capture
   loops. Escape to the render captured at file load instead:

   ```lua
   local BOOT_RENDER = ISToolTipInv.render   -- file scope, pre-OnGameStart
   -- in the guard:
   if isRendering then return BOOT_RENDER(self) end
   ```
4. **Never advise users to reorder against the doctrine** — "put TooltipLib
   at the bottom" was precisely the cycle-forming order for one reclaimer
   (§5, v1.6.0).
