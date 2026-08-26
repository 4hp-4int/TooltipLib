# Changelog

All notable changes to TooltipLib are documented here.

## [1.6.2] — 2026-08-26

### Fixed
- **Compatibility with the PZ security patch that removed `loadstring`/`loadstream`.** `Hook.lua` opened with a `loadstring` closure that pre-seeded the Translator's "missing" set for the B42.16 `getText("Item Report")` bug (the key has no prefix, so the lookup always fails). The closure had to be **unattributed** — that was the entire point, so the resulting Translation ERROR wasn't credited to TooltipLib and didn't flag it in `PauseBuggedModList` — and `loadstring` was the only way to build one. With `loadstring` gone the call raises, and although the block was already `pcall`-wrapped, Kahlua logs at the raise site regardless, so every load would have written a stack trace. Removed outright rather than guarded on `loadstring ~= nil`: the pre-seed was only ever the first line of defence, and `snapshotAndClearBuggedFlags` immediately below handles the same failure mode directly by clearing pre-game-start flags whatever raised them. There is no replacement for an unattributed closure — a direct `getText()` call would carry our attribution, which is precisely what the trick existed to avoid.

## [1.6.1] — 2026-08-05

### Added
- **"Hide tooltips while aiming" (Mod Options, default ON).** While the local player holds aim, no TooltipLib-managed tooltip draws at all: the item and crafting-slot surfaces return before the render chain runs (so the vanilla card is skipped too, not just provider content), and the world-object panel hides. Brushing the inventory mid-fight is almost always accidental, and tooltip layout is the most expensive per-frame UI work — suppressing it keeps the frame cheap exactly when it matters most. Suppressed frames mutate no hook state, so ownership and deferred-mode memos resume untouched the moment the aim ends. `isAiming` is field-probed, not pcalled (a nil method call escapes Kahlua's `pcall`). Regression-locked in `tests/test_tooltiplib_dress.lua` (`aiming_gate_suppresses_all_drawing`).

### Fixed
- **Panel-dress chrome vanished for the rest of the session after the first right-click.** Field report: *"I only see the full card when I start the game. After looking at certain items the full card look disappears"* — default settings, no other tooltip framework installed. Both layout surfaces' vanilla renders wrap their **entire body** in a context-menu guard (`ISToolTipInv.lua:45` and `ISToolTipItemSlot.lua:45`: `if not ISContextMenu.instance or not ISContextMenu.instance.visibleCheck`), and `ISContextMenu:render()` sets `visibleCheck` every frame it draws. So while a context menu is open, vanilla's render is a complete **no-op**: `item:DoTooltip` is never called, and the `ourWrapperFired` ownership proof reads false — indistinguishable, from inside the hook, from a foreign framework having replaced our wrapper. The deferred-append branch therefore ran on frames where *nothing had been drawn at all*, latching `TooltipLib._deferrerSeen` on the first right-click of the session; consistency mode (`Core._resolvePanelDress`) reads that latch to stand the dress down **session-wide**, so one right-click cost the player the skin until restart. The deferred branch now skips any frame with a context menu up: nothing was drawn, so there is nothing to append to and nothing to conclude. Regression-locked in `tests/test_tooltiplib_dress.lua` (`context_menu_noop_frame_is_not_a_deferrer`).

- **Provider rows overlapped vanilla's "Contains:" / "Spices:" icon strips.** Reported as *Encumbrance sharing a line with Contains* on an evolved-recipe soup, default settings, all other mods off. `InventoryItem.DoTooltipEmbedded` draws the item name and then **two imperative icon strips** before it hands the layout back — `Contains:` (extra items, `InventoryItem.java:760`) and `Spices:` (`Food.spices`, `java:782`) — each advancing vanilla's own `y` by `lineSpacing + 5`, with the total published in `layoutOverride.offsetY`. That is a Java instance field Kahlua cannot read, and the hook hardcoded the first row's `startY` to `padTop + lineSpacing` (room for the name line only) — so on any item carrying those components the first vanilla row landed *on top of* the icons. The hook now mirrors vanilla's arithmetic and reserves the strips. Existence-guarded by a field probe rather than a `pcall` (a nil method call escapes Kahlua's `pcall`), matching vanilla's own tests exactly — including that `Spices:` is drawn on `spices ~= nil` with no emptiness check — and skipped when a provider claims the vanilla rows, since then the embed never runs and no strip exists. Regression-locked in `tests/test_tooltiplib_dress.lua` (`prelayout_strips_reserved_contains_and_spices`).

- **MP `readObject` flooded dedicated-server command traffic on cursor movement.** `HookWorldObject`'s `OnPreUIDraw` polls `UIManager.getLastPicked()` every frame, and each distinct world object is its own cache key (`x:y:z:objectIndex`) — so `REQUEST_COOLDOWN_MS`, which is keyed *per object*, never applied to objects the cursor merely swept across while the player walked. Every one of them cost an immediate `sendClientCommand` round trip. Measured on a live dedicated server (4 players, ~100 minutes): **41,714 `readObject` commands, 63% of them arriving within 250ms of the previous one** — objects nobody ever settled on — against only 13% that were genuine 2s TTL refreshes. `readObject` alone accounted for 97.5% of the server's logged command volume.

  A new **hover-dwell gate** requires a *previously unseen* object to stay picked for `HOVER_DWELL_MS` (200ms) before it earns a round trip. Objects already in the client cache bypass the gate entirely, so refreshes and re-hovers (cache entries live 30s) are never delayed — only genuinely-new objects pay the 200ms, which is the ordinary feel of a tooltip delay. `REQUEST_COOLDOWN_MS` also raised 500ms → 1500ms: it sat *below* the 2000ms cache TTL, so a rested cursor could re-request several times per cache lifetime.

  No change to what a resting tooltip displays, to the provider API, or to the sandbox `EnableMPSync` gate. Regression-locked in the kit (`tests/test_mpclient.lua`, 9 tests on Kahlua: with the gate removed, the sweep test goes from 0 requests to 50).

### Technical
- No API, provider-contract or persisted-data change. `TooltipLib.VERSION_NUM` 14 → 15 (load-guard stamp only); consumers pinning `>= 1.5.x` need no update.
- TooltipLib's regression suite moved out of `pz-test-kit/uiview/tests/` and into `tests/` here; those files only lived in uiview because that is where `UIView/UIMock` resolved. `pz-test.lua` now declares uiview as a test-only dependency, and uiview keeps the tests that are genuinely its own (scene rendering + golden display lists).
- **69 tests green** in `tests/` (real Kahlua VM), alongside 723 in the kit's `uiview` harness and 80 in SauceTooltips driven against this build.

## [1.6.0] — 2026-08-01

### Added
- **Compatibility diagnostics** (`TooltipLib/Diagnostics.lua`). The hooks now count runtime evidence (`TooltipLib._diag`: owned renders, deferred renders, stand-downs, cycle breaks, thrash retires, Starlit fills/bypasses, chain errors) and record the installed wrapper per surface for a render-slot **ownership probe**. `TooltipLib.diagnose()` — also wired to a *Mod Options → TooltipLib → Run compatibility check* button — turns that evidence plus the user's actual load order (`getActivatedMods()`, cross-referenced against known tooltip-mod classes: Tempo/SWSP bypassers, EHR own-panel, Starlit host, MagicAccessories reclaimer) into an **OK / MITIGATED / ACTION** verdict with concrete instructions ("move TooltipLib BELOW X", "report to Y's author", "copy this check into a bug report"), including circuit-breaker state per provider. An automatic one-shot check ~2 minutes into each session logs a single warning when the verdict is ACTION — never a modal, never repeated. Regression-locked in the kit (`test_tooltiplib_diagnose.lua`).
- **docs/COMPATIBILITY.md** — the compatibility architecture written down as abstractions: the five foreign-mod classes (chaining wrapper, bypasser, own-panel renderer, layout host, reclaiming wrapper) plus vanilla's own hazards, the mechanism answering each, the load-order doctrine, the log-line triage table, and case files for every incident v1.4.1→v1.6.0.

### Fixed
- **Stack-overflow crash on item hover with "reclaiming" tooltip wrapper mods** (reported with *Magic Accessories*, WS 3760442018 — the same crash class it documents with *Global Storage SiK*, WS 3750612158). Mods that wrap `ISToolTipInv.render` with an "install late to win" reclaim loop (re-taking the slot on `OnGameStart`/`OnCreatePlayer`/periodic ticks, re-capturing whatever render is *current* as their fallback) can end up mutually chained with TooltipLib: when such a mod's first install runs before ours, our `InstallHook` captures **its** wrapper as `original_render`, then its reclaim captures **our** wrapper as its fallback — and the first hovered item recurses `A→B→A→…` without bound (its own re-entry guard delegates to its fallback, i.e. right back into the loop) until the VM stack overflows. Whether a given player crashed was a coin flip on mod-list order, and the other mod's suggested workaround ("TooltipLib at the bottom of the load order") is exactly the ordering that forms the cycle. Both the item and itemSlot hooks are now **depth-guarded**: re-entry on the same call stack is detected as a render-slot cycle and broken by calling the **boot-time render** (snapshotted at Hook.lua file load, before any `OnGameStart` patcher installs) instead of chaining. The outer invocation's `DoTooltip` wrapper is still armed on the item metatable at that point, so provider dispatch — including the reclaiming mod's own registered provider — still renders: the crash degrades to a normal, complete tooltip. One-line `render_cycle` diagnostic on first detection. Field-confirmed in game (the diagnostic fired in both load orders, zero stack traces). Regression-locked in the kit (`test_tooltiplib_magicacc.lua`: real Hook.lua against a faithful reclaim-loop sim on Kahlua — pre-fix, 61 wrapper re-entries for a single render, vanilla never reached).
- **Core self-reported version lagged mod.info** (`TooltipLib.VERSION` said 1.5.2 while mod.info shipped 1.5.3); both now read 1.6.0.

### Changed
- **Surface-hook factory**: the ISToolTipInv and ISToolTipItemSlot hooks — previously hand-maintained near-copies — are now one implementation (`installLayoutSurfaceHook`) instantiated per surface, with explicit config for the real asymmetries (provider source, Starlit path, detail hint, itemSlot ctx field, log keys, boot render). No behavior change intended; the itemSlot surface was characterization-tested against the old code before the port (`test_tooltiplib_slot.lua`), and the full kit suite passed after each migration step. Hook.lua ~1,888 → ~1,600 lines; future render-path fixes are written once instead of twice.

## [1.5.3] — 2026-07-11

### Fixed
- **Error spam hovering the liquid tiles in the fluid-details panel** (with StarlitLibrary installed): `Object tried to call nil in render (Hook.lua:915)` every rendered frame. Vanilla reuses `ISToolTipInv` for non-item subjects — `ISFluidBar:activateToolTip` passes a **FluidContainer** (or ResourceFluid) as the tooltip's item — and the render wrapper's Starlit gate read `item:getID()` before any subject-type check; FluidContainer has no `getID`, and a nil-call escapes Kahlua's `pcall`. The wrapper now hands any non-`InventoryItem` subject straight back to vanilla, the same guard the `ISToolTipItemSlot` hook already had. Regression-locked in the kit (`test_tooltiplib_dress.lua`: `non_item_subject_*`), including a repro of the exact Starlit-gate crash.

### Fixed
- **Cumulative circuit-breaker latch under StarlitLibrary** (blanked ALL of a consumer's tooltips for the session). `_recordSuccess` is called only on the owned/deferred render paths, never on the Starlit adapter path — so a provider that threw even occasionally under Starlit accumulated errors that no successful hover ever reset. After 10 it latched `disabled` for the whole Lua VM (surviving in-process save reloads), silently hiding every one of that provider's tooltips until a full restart. The Starlit adapter (`StarlitAdapter.fillFromProviders`) now calls `TooltipLib._recordSuccess(p.id)` after a successful provider callback, restoring the intended "10 **consecutive** errors" semantics (a good hover resets the count). Surfaced by VorpallySauced tooltips vanishing session-wide on StarlitLibrary + heavy-mod setups.
- **Provider content silently lost when another tooltip mod owns the render.** Under StarlitLibrary, TooltipLib feeds provider content through Starlit's `onFillItemTooltip` event. If a *different* tooltip/UI mod (NeatUI/CleanUI-class) replaces `ISToolTipInv.render` outside Starlit so that event never fires, the adapter never ran and content just disappeared — no crash, no error, valid data. The Starlit branch now detects when `onFillItemTooltip` did **not** fire for an item (a `_starlitFillFired` flag set by the adapter, reset before the render chain) and routes that item through the **deferred append path** (with its full growth/thrash protection) on subsequent frames, so content shows anyway. Reachable only when TooltipLib's own render wrapper is in the chain; a one-line `starlit_fill_bypassed` diagnostic advises loading TooltipLib **last** when it is fully bypassed.
- **Render-hook install is now idempotent.** `InstallHook` re-wrapped `ISToolTipInv.render` on every `OnGameStart` — and `OnGameStart` fires again on every save load within the same process (the Lua VM isn't reset). Each reload therefore stacked another TooltipLib wrapper and reshuffled render ownership relative to other tooltip mods across reloads — a plausible "tooltips worked, then broke after a reload" trigger. It now wraps exactly once per VM (`_itemHookInstalled` guard).

## [1.5.1] — 2026-07-05

### Added / Changed
- **The coexistence patch** after 1.5.0. Native StarlitLibrary integration: when Starlit is present it owns the item card, and TooltipLib feeds provider content straight into Starlit's tooltip via its `onFillItemTooltip` hook (one card, one render, correct alignment) instead of stapling a second block below it. Adds an experimental "keep the tooltip skin alongside other tooltip frameworks" consistency option (default off — any registered skin stands down when another framework is detected so every tooltip matches). Fixes flip-flopping provider content/accents, duplicated cards, overlapping stats (Show Weapon Stats Plus), accent-line flicker, detail-toggle strobing, and a first-hover boxless flash under other frameworks. Chaotic multi-framework stacks that thrash a single card retire to plain vanilla for the session. (Full player-facing notes shipped on the Workshop; this entry backfills the source changelog.)

## [1.5.0] — 2026-07-02

### Added
- **Section channel** (`ctx:beginSection(label, color?)`, all surfaces): providers declare "a titled section starts here" instead of hand-rolling header + divider rows. Undressed (or with a dress that has no `ornaments` hook) the framework renders the classic look — an uppercased label row plus a thin divider row, as ordinary layout items. When the active panel dress registers an **`ornaments` hook**, the divider row is omitted and the hook receives the provider rows' **exact geometry** at the end of the real pass — `geom.rows` (per-row y/height/kind/label-and-value widths, **reconstructed from declare-time notes**: the Java `Layout`'s fields aren't Lua-readable, so every ctx method notes the row it adds — kind, measured widths, bar fraction/colour — and positions derive from the rendered end-Y, one lineSpacing per single-line row; labelled progress rows classify as `"bar"` with fraction + declared colour, labelless ones as `"rule"`, so a skin can repaint progress bars exactly — `geom.barH` gives vanilla's bar height for the active font, and `valueRightX` is `width - padRight` by construction of the value-alignment pass), `geom.sections` (each declared section's row), and the value-column edges (`midX`/`valueRightX`) — so a skin can draw row-anchored flourishes (section rules, dot leaders between labels and values) in its own material, pixel-true under the text. Dress spec additions: `ornaments(panel, tooltip, geom, surface, accent)` and `sectionLabelColor` (declare-time styling for section labels). Recorded/replayed for cacheable providers; rich-text and recipe surfaces degrade to header + divider; an `ornaments` error clears the dress (fail-open, same discipline as `draw`).
- **Accent channel** (`ctx:setAccentColor(color)`, item/itemSlot surfaces): the theme accent line becomes *declared data* instead of provider-painted pixels. Providers call `setAccentColor` from callback or postRender (recorded/replayed for cacheable providers); the LAST write wins, preserving the old "later provider draws over the earlier bar" override semantics without the double draw. The framework then renders the classic 2px bar **once** per tooltip (real pass only) — or, when a panel dress is active, skips the bar entirely and passes the colour to the dress (`draw(..., accent)`; accents declared in the **callback** phase run on the measure pass too, warming a per-item cache so the dress paints the right colour on the very first frame — postRender declarers catch up one frame later; the object surface passes `WorldObjectPanel.accentColor` same-frame, and its edge-to-edge bar likewise yields to the dress so nothing cuts across rounded corners). Consumers updated: SauceTooltips' type colours and VorpallySauced's tier colours declare on the channel (with a legacy direct-draw fallback on older TooltipLib), and sauce-invrender's tooltip card tints its title rail with the item's accent.
- **Panel dress API** (`TooltipLib.setPanelDress` / `clearPanelDress` / `getPanelDress`): one consumer mod at a time can *skin the tooltip's background card* — a `draw(panel, tooltip, w, h, surface)` callback paints a textured background (e.g. a nine-patch) in place of the vanilla flat rect + square border on the `item` (ISToolTipInv), `itemSlot` (ISToolTipItemSlot), and `object` (WorldObjectPanel) surfaces. While the dress is active the hooks zero the panel's `backgroundColor`/`borderColor` alphas around the render chain (restored immediately after — the fields are shared vanilla state) and invoke the dress at the start of the **real** draw pass, so it lands over where the flat box was, under all vanilla and provider content, at the post-reposition location (the v1.4.1 measure-pass rules apply: the dress never draws on the measure pass). The dress engages on **every** tooltip, including items no provider is active for — a dress-only render installs a minimal `DoTooltip` wrapper around vanilla's own draw. Spec fields: `id` (owner, required), `draw` (required), `active()` (per-frame stand-down, e.g. texture pack missing or user option off), `surfaces` (opt-in subset). Safety: **deferred/foreign mode is never dressed** — a framework that owns the panel (v1.4.2 stand-down cases included) keeps its vanilla box, via a per-surface foreign-owner latch that also stops the alpha suppression from blanking a foreign panel's background (one discovery frame, then self-corrects); an error from `draw` or `active` clears the dress for the session with one console line and vanilla boxes return the next frame. `HookRecipe`'s panel is not covered yet. (Consumed by sauce-invrender's kraft-ledger tooltip card.)

## [1.4.2] — 2026-06-27

### Fixed
- **Unbounded vertical tooltip growth under mods that fully replace `ISToolTipInv.render`**: When another mod overrides `ISToolTipInv.render` / `ISToolTipItemSlot.render` and draws its own panel directly without ever rendering through `self.tooltip` (reported on *Extensive Health Rework Evolved*, WS 3726328119), TooltipLib's deferred branch read back the `ObjectTooltip` height it had written the previous frame and stacked provider content on its own prior output every frame — the tooltip grew without bound. The hook now snapshots `self.tooltip`'s reference and height before the render chain; if, after the chain, the `ObjectTooltip` is the **same reference with unchanged height**, the foreign renderer bypassed it entirely, so TooltipLib stands down (returns, appends nothing, zeroes the deferred cache) rather than deferring onto stale geometry. Applied symmetrically to the item and itemSlot hooks. Legit deferred hosts (StarlitLibrary, AMS) re-render `self.tooltip` each frame so its height changes and the guard never triggers — they are unaffected. Trade-off: for items a render-replacing mod fully owns, TooltipLib now suppresses its provider content rather than corrupt the layout.

## [1.4.1] — 2026-06-17

### Fixed
- **Duplicate tooltip box / accent bar in context menus and world-object menus**: Hovering an item whose tooltip is shown from a context menu (right-click options) or a world-object context menu (e.g. an item on the ground) drew the provider content **twice** — two boxes, two theme accent bars. Root cause: vanilla `ISToolTipInv.render`/`ISToolTipItemSlot.render` call `DoTooltip` twice per frame — once with `setMeasureOnly(true)` to size the tooltip, then again (after repositioning the tooltip via `adjustPositionToAvoidOverlap`) to draw it. PZ's `Layout.render` honors `measureOnly` and skips its own drawing, but TooltipLib's direct-draw phases (postRender accent bars, texture rows, the container icon preview, the `[Shift] Details` hint, and the overflow indicator) did not — so they painted during the measure pass too, at the *pre-reposition* location. Regular inventory hovers hid it because both passes land at the same spot (the duplicates overlapped); menus reposition between passes, so the measure-pass copy became visible as a second box. The hook now detects the measure pass via `ObjectTooltip:isMeasureOnly()` and defers all direct drawing to the real pass, while still running measurement and state phases (preTooltip/callback/cleanup) on both. As a side benefit, this removes a 2× overdraw of semi-transparent accent bars on every item tooltip.

## [1.4.0] — 2026-06-05

### Added
- **`WorldObjectPanel:setTitle(text, color)`**: Object-surface providers can set a bold header (Medium font) drawn at the very top of the world-object tooltip, above all content rows — typically the hovered object's name. The title is panel-level state (like `accentColor`), reset each frame in `clearEntries()`, and is **not** a content entry: it does not increment the provider's item count, so a title alone never forces the tooltip visible. It only renders when a data provider also adds at least one entry. `measureWidth()` accounts for the title's width; first call per frame wins. (Consumed by SauceTooltips' object-name header.)

## [1.3.2] — 2026-06-05

### Fixed
- **Detail-modifier keybind couldn't be rebound**: Changing the "Detail Modifier Key" in Mod Options had no effect — it always behaved as LShift. Root cause is a vanilla B42 bug: `MainOptions.keyPressHandler` matches a mod keybind by comparing the raw option name against the row's *translated* label text, so any mod keybind whose name has a translation entry can never be rebound (the captured key is dropped). Since TooltipLib localizes `UI_TL_DetailKey`, it tripped this. Worked around by registering the keybind with the already-resolved display string as its name, so both sides of vanilla's comparison match. (Vanilla's `onDefault` uses `getText()` on both sides and is unaffected — confirming the inconsistency.)
- **"[Shift] Details" hint ignored the configured key**: The detail-content hint was hardcoded to "Shift". It now shows the actual configured detail key (e.g. "[LAlt] Details") via `getKeyName(_getDetailKeyCode())`.
- **MP `readObject` not gated client-side by `EnableMPSync`**: Disabling the "Enable MP Tooltip Sync" sandbox option stopped the server from *responding* but not clients from *sending* — so dedicated-server clients kept firing a `readObject` command on every world-object hover, flooding server command logs even with sync disabled. The client send now respects the same sandbox toggle (mirroring the server-side gate), so disabling MP sync silences the traffic entirely.

## [1.3.1] — 2026-05-22

### Fixed
- **`InventoryContainer` icon preview stripped when any item provider is registered**: Vanilla draws a row of contained-item icons at the bottom of backpack/handbag tooltips from `InventoryContainer.DoTooltip(tooltipUI)` (1-arg), but the hook routes through `DoTooltipEmbedded` → `DoTooltip(tooltipUI, layout)` (2-arg), which only adds Capacity/Weight Reduction/Max Item Size and never draws icons. Any consumer mod with a single item provider active silently lost the preview on containers. Hook now reproduces the icon row in a new Phase 2.6 (between texture queue and postRender), so accent bars and other postRender overlays cover it correctly.

## [1.3.0] — 2026-05-18

### Added
- **`TooltipLib.maxTooltipWidth` setting**: Soft cap (logical pixels at Small font) on `ctx:addText` auto-wrap width, scaled by the active tooltip font's glyph ratio so the visual line length stays consistent across Small/Medium/Large. Default `1000`. Set to `nil` to disable the cap. Per-call `maxWidth` arg on `addText` overrides this.
- **`TooltipLib.Helpers.wrapText` public API**: Exposes the internal word-wrap helper (`wrapText(text, wrapAt, font)`) for consumers that want to pre-wrap content manually before passing to `setLabel` — useful for collapsing multi-paragraph lore into a single multi-line layout item with vanilla-equivalent vertical density.

### Fixed
- **`addInteger` crash without `highGood`**: Calling `ctx:addInteger(label, value)` without the third arg used to NPE inside Java's `setValueRight(int, boolean)` because Kahlua can't unbox `nil` to a primitive boolean. All four `addInteger` paths (ContextMT, RichTextContextMT, RecipeContextMT, static `Helpers.addInteger`) now default `highGood` to `true`.
- **Right-aligned values not reaching the tooltip's right edge**: When a wide label-only row (lore, description text) widened the tooltip beyond the value column's natural extent, key-value pairs would right-align at the layout's old narrower right edge with a visible gap to the tooltip's actual edge. Hook now records each `add*` helper's label/value widths into a per-render stats accumulator and applies `setMinValueWidth` before render so values stay flush right. Font-aware via `Core.getOptionTooltipFont()`.
- **Deferred-mode background seam**: When another tooltip framework (StarlitLibrary, AMS, etc.) overrides `DoTooltip`, TooltipLib paints a background extension below the foreign content. If the foreign framework's bg overlay alpha differs from `panel.backgroundColor`, a hard horizontal seam was visible at the boundary. The extension now feathers in with a 5px alpha gradient at the top edge, hiding the transition.

### Notes
- Provider tooltips with multi-paragraph lore (via `<br>` in translations) render unchanged from a layout perspective — Translator already converts `<br>` to `\n`. To match vanilla's vertical density when migrating long item descriptions out of the script `Tooltip` property and into a provider, pre-wrap the paragraphs with `Helpers.wrapText` and pass the joined string to `ctx:addLabel(joined)` as a single multi-line item rather than calling `addText` per paragraph (which adds per-item separators).

## [1.2.0] — Workshop release

### Added
- **`hasDetailContent` provider field**: providers that show extra info when holding the detail key (default: LShift) now display a "[Shift] Details" hint automatically.
- **`TooltipLib.clearBuggedFlag()` API**: consumer mods can opt into the B42.16 error-flag workaround.
- **MP tooltip sync sandbox option**: Server admins can disable the multiplayer tooltip data pipeline via `EnableMPSync` sandbox option.

### Fixed
- **Progress bar alignment**: Provider-added progress bars now render at a width matching vanilla bars (Condition, Sharpness). After vanilla's layout renders, the framework reads its computed width and applies `setMinLabelWidth`/`setMinValueWidth` on the provider layout to sync column dimensions.
- **False `[ERRORS]` flag in pause menu mod list** caused by a B42.16 regression where vanilla translation errors incorrectly flag mods.
- **Workaround for vanilla missing translation "Item Report"** that triggered mod error tracking.
- **All Mod Options labels now use proper translation keys** (fixes Translation ERROR log spam).
- **`inRange` filter crash on invalidated objects**: Items/objects removed from the world between frames can leave a live Java reference with a null `square` field. `getX`/`getY`/`getZ` would then NPE. The filter now guards with a `getSquare` probe before reading coordinates.
- **World object tooltip crash on invalidated picks**: Same root cause as above — `UIManager.getLastPicked()` can return a stale object whose square was nulled. `HookWorldObject` now bails out and hides the tooltip panel when `picked:getSquare()` returns nil instead of letting filters NPE.

## [1.1.1] — 2026-03-31

### Fixed
- **Tooltip width bloat**: Split vanilla and provider content into chained Layout sections with independent column width computation. Prevents vanilla progress bars (Sharpness, Condition) from inflating provider row widths and vice versa — fixes excessively wide tooltips on items with mixed content types (reported with Clean Hotbar)

## [1.1.0] — 2026-03-18

### Added
- **Multiplayer support**: Server-authoritative object data pipeline via `MPClient.lua` / `MPServer.lua` using `sendClientCommand` with whitelisted method names
- **DirectRenderCMT context**: New context type for world object tooltips with `ctx:readObject()` and `ctx:safeCall()` for transparent SP/MP data access
- **WorldObjectPanel**: ISPanel-based renderer for world object tooltips with cross-entry column alignment and content-based width sizing
- **Sandbox option**: `EnableMPSync` toggle lets server admins disable MP tooltip data sync
- **`replaceProvider(id, newOptions)`**: Atomic remove-and-register for mod override use cases
- **`_warn(msg)`**: Always-on warning logger for hook install failures
- **`getHookStatus()`**: Lets consumer mods verify surface hooks are live after OnGameStart
- **Context table pooling**: Reuses context tables across frames on item and object surfaces to reduce GC pressure
- **Accent color support** via panel properties on world object tooltips
- **Periodic MP cache eviction**: 30-second sweep via `EveryOneMinute` event

### Changed
- **Unified world object rendering**: Converged SP and MP onto a single `WorldObjectPanel` + `OnPreUIDraw` path, removing the SP-only `DoSpecialTooltip` handler, object marking system, and two-pass Layout rendering
- **Vanilla farm tooltip suppression**: `CFarmingSystem.DoSpecialTooltip1` is now suppressed only when a `replacesVanilla` provider is active and enabled for the target object
- Moved all code from `shared/` to `client/`, removed unnecessary `isServer()` guards

### Fixed
- **Circuit breaker**: Callback errors now accumulate properly — removed `_recordSuccess` from non-callback phases so broken providers are correctly disabled after 10 consecutive errors

## [1.0.0] — 2026-03-14

### Added
- **Provider registry**: Priority-based ordering with `registerProvider`, `removeProvider`, `hasProvider`, `getProviderCount`
- **Six tooltip surfaces**: item, itemSlot, object, skill, vehicle, recipe — each with dedicated hook files
- **Three context types**: `LayoutContextMT` (item/itemSlot), `RichTextContextMT` (skill/vehicle), `RecipeContextMT` (recipe) with surface-appropriate APIs
- **Context API**: `ctx:addLabel()`, `ctx:addKeyValue()`, `ctx:addProgress()`, `ctx:appendLine()`, `ctx:appendKeyValue()`, and more
- **Texture API**: `ctx:addTexture()` and `ctx:addTextureRow()` with auto-wrapping
- **`postRender` phase**: Phase 3 callback for direct tooltip drawing after layout rendering
- **L1 provider cache**: Per-surface active provider caching with periodic refresh (every 60 frames)
- **L2 display list cache**: Per-provider entry caching for item/itemSlot with `maxAge` expiration
- **`Filters.lua`**: Pre-built item/object type filters with pcall-hardened checks and filter combinators
- **Introspection API**: `getProviders()`, `hasProvider()`, `getProviderCount()`, `checkVersion()`
- **Configuration**: `setProviderEnabled()`, `isProviderEnabled()`, `invalidateCache()`
- **Error isolation**: pcall-wrapped provider callbacks with circuit breaker (10 consecutive errors disables provider)
- **Deferred mode**: Compatibility with other tooltip frameworks that override `DoTooltip`
- **Colors table**: Frozen read-only color constants for consistent tooltip styling
- **EmmyLua annotations**: Full type annotations across all files for IDE support
- **Mod Options integration**: Per-provider toggles via sandbox options

### Fixed
- Progress bar width calculation: compute exact remaining space instead of estimating
- Second layout column width: match vanilla tooltip column sizing for proper alignment
- World object targeting: use `tooltip.object` instead of square iteration
- Deferred mode background: draw background extension using cached dimensions before content
- `addKeyValue` table-form caching: shallow copy prevents cross-frame corruption

## [0.1.0] — 2026-03-12

### Added
- Initial TooltipLib implementation with provider registry, priority-based ordering, and item tooltip hook
- Three-phase dispatch: `preTooltip` → `callback` → `cleanup` with per-provider pcall isolation
