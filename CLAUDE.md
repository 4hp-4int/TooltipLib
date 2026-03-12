# CLAUDE.md

Internal architecture guide for TooltipLib. This file is for codeowners and AI assistants working on the framework itself.

## What This Is

TooltipLib is a shared tooltip framework for Project Zomboid Build 42 mods. Multiple mods add content to tooltips through a provider registration API — zero conflicts, automatic alignment, error isolation.

## File Map

```
media/lua/shared/TooltipLib/
  Core.lua        -- Provider registry, version guard, semver API, cache invalidation,
                     introspection API, debug mode, error circuit breaker, target routing,
                     shared hook helpers (_readDetailKey, _evaluateProviders)
  Filters.lua     -- Pre-built enabled() filters (pcall-hardened), combinators,
                     customType factory, world object filters (generator, rainCollector,
                     farmPlant, objectSprite), range filter (inRange)

media/lua/client/TooltipLib/
  Helpers.lua     -- Frozen Colors, shared formatting helpers (resolveKeyValueArgs,
                     formatSignedValue, rtColorTag), ContextMT (Layout surfaces: bound
                     methods incl. texture support, addText, addFloat, addPercentage),
                     RichTextContextMT (Rich Text surfaces: unified add* methods + native
                     appendLine/appendRichText/setName), RecipeContentPanel (ISPanel
                     subclass for recipe rendering via drawText/drawRect in prerender),
                     RecipeContextMT (Recipe surface: unified add* methods adding entries
                     to RecipeContentPanel), RecordingContextMT +
                     RecordingRichTextContextMT (cache with __index proxy forwarding +
                     __newindex warning), auto-separator (maybeInsertSeparator +
                     maybeInsertRichTextSeparator + maybeInsertRecipeSeparator +
                     _itemCount), replay dispatch (replayDispatch +
                     richTextReplayDispatch), shared hook helpers
                     (_processTextureQueue, _installPostRenderWrap), static helpers
  Hook.lua        -- ISToolTipInv + ISToolTipItemSlot hooks, shared doLayoutDispatch
                     (5-phase dispatch), L1+L2 caching with maxAge, auto-separator
                     orchestration, circuit breaker integration, height cap, frame counter,
                     boot probe, first-render probe, ctx.surface field. Uses shared
                     _readDetailKey and _evaluateProviders from Core.lua
  HookWorldObject.lua -- World object tooltip hook (DoSpecialTooltip event listener),
                     height cap, two-pass measure+render. Uses shared helpers from Core.lua
  HookSkill.lua   -- Skill tooltip hook (ISSkillProgressBar:updateTooltip). Full pipeline:
                     preTooltip + auto-separator + unified add* methods via RichTextContextMT.
                     Uses shared helpers from Core.lua
  HookVehicle.lua -- Vehicle tooltip hook (ISVehicleMechanics:doMenuTooltip). Full pipeline:
                     preTooltip + auto-separator + unified add* methods via RichTextContextMT.
                     Uses shared helpers from Core.lua
  HookRecipe.lua  -- Recipe tooltip hook (ISCraftRecipeTooltip:createDynamicChildren). Full
                     pipeline: preTooltip + auto-separator + unified add* methods via
                     RecipeContextMT + RecipeContentPanel. Direct rootTable access preserved.
                     Uses shared helpers from Core.lua
  Options.lua     -- PZAPI.ModOptions integration: configurable detail key binding,
                     dynamic per-provider enable/disable tick boxes, _getDetailKeyCode
                     accessor, _refreshProviderOptions, graceful fallback when absent
```

shared/ files run on both client and server. client/ files are guarded with `if isServer() then return end`.

## Architecture

### Multi-Surface Design

TooltipLib supports 6 tooltip surface targets organized into 3 rendering families:

| Target | PZ Class | Family | Context Subject |
|--------|----------|--------|-----------------|
| `"item"` | ISToolTipInv | Layout | `ctx.item` |
| `"itemSlot"` | ISToolTipItemSlot | Layout | `ctx.item`, `ctx.itemSlot` |
| `"object"` | IsoObject.DoSpecialTooltip | Layout | `ctx.object`, `ctx.square` |
| `"skill"` | ISSkillProgressBar | Rich Text | `ctx.perk`, `ctx.level`, `ctx.player` |
| `"vehicle"` | ISVehicleMechanics | Rich Text | `ctx.part`, `ctx.vehicle`, `ctx.player` |
| `"recipe"` | ISCraftRecipeTooltip | Recipe | `ctx.recipe`, `ctx.rootTable`, `ctx._panel` |

**Provider target routing**: `Core.lua` stores a `target` field on each provider (default: `"item"`). `_providersByTarget` maps target strings to sorted provider arrays. Each hook file reads from `_getProvidersForTarget(target)`.

**Item providers auto-apply to itemSlot**: When ISToolTipItemSlot renders an InventoryItem, both `target = "item"` and `target = "itemSlot"` providers are evaluated. Providers can check `ctx.surface == "itemSlot"` to distinguish.

**Enabled filter signatures vary by target**:
| Target | `enabled()` receives |
|--------|---------------------|
| `item`, `itemSlot` | `(item)` |
| `object` | `(object, square)` |
| `skill` | `(perk, level)` |
| `vehicle` | `(part, vehicle)` |
| `recipe` | `(recipe)` |

### Hook Pipeline (Layout Family)

```
ISToolTipInv.render / ISToolTipItemSlot.render (our wrapper)
  -> Boot probe: ISToolTipInv.render exists?
  -> First-render probe: DoTooltip/DoTooltipEmbedded on metatable?
  -> Detail key: read GameKeyboard.isKeyDown for configurable modifier
  -> Level 1 cache: which providers are active for this item?
     (refreshes every 60 frames, keyed on item + providerVersion + detailState)
     - Circuit breaker: skip disabled providers
     - detailOnly: skip when detail key not held
  -> Metatable swap: replace item.DoTooltip temporarily
     -> item:DoTooltip (our wrapper, called by vanilla render chain)
        -> doLayoutDispatch() [shared function]
           -> Phase 1: preTooltip (all active providers)
           -> Phase 2: Layout
              -> tooltip:beginLayout()
              -> item:DoTooltipEmbedded(tooltip, layout, 0)  -- vanilla items
              -> Auto-separator orchestration (prevAddedContent tracking)
              -> Provider callbacks add to SAME layout       -- aligned columns
              -> layout:render() + tooltip:endLayout()
           -> Phase 2.5: Textures (framework processes _textureQueue per provider)
           -> Phase 3: postRender (direct drawing on tooltip surface)
           -> Height cap: clamp to screenHeight - 20, draw "..." if capped
           -> Phase 4: cleanup (guaranteed, even on error)
  -> Restore original DoTooltip on metatable (always runs via pcall)
  -> Interop guard: if ourWrapperFired == false, another framework
     overwrote our DoTooltip swap. Fall back to deferred layout:
     -> Read tooltip:getHeight() (where foreign content ends)
     -> doLayoutDispatch() with deferStartY (skips DoTooltipEmbedded)
     -> Provider content appended below foreign framework output
     -> Alignment: providers align with each other, not vanilla rows
```

### Hook Pipeline (Rich Text Family — Skill/Vehicle)

```
ISSkillProgressBar.updateTooltip / ISVehicleMechanics.doMenuTooltip
  -> Let vanilla build the tooltip first
  -> Detail key: _readDetailKey() (shared helper)
  -> Evaluate providers: _evaluateProviders() (shared helper)
  -> Build per-provider RichTextContextMT contexts with shared _lines accumulator
  -> Phase 1: preTooltip (all active providers)
  -> Phase 2: Provider callbacks with auto-separator orchestration
     -> ctx:addLabel, ctx:addKeyValue, etc. append rich text markup to _lines
     -> ctx:appendLine, ctx:appendRichText also available for raw control
  -> Concatenate lines with " <LINE> " and append to self.message / tooltip.description
  -> Phase 4: cleanup (guaranteed, reuses callback ctx)
```

### Hook Pipeline (Recipe — RecipeContentPanel Family)

```
ISCraftRecipePanel.createDynamicChildren / ISCraftRecipeTooltip.createDynamicChildren
  -> Let vanilla build the widget tree first
  -> Detail key: _readDetailKey() (shared helper)
  -> Evaluate providers: _evaluateProviders() (shared helper)
  -> Create single shared RecipeContentPanel (ISPanel subclass)
  -> Build per-provider RecipeContextMT contexts (all share the panel)
  -> Phase 1: preTooltip (all active providers)
  -> Phase 2: Provider callbacks with auto-separator orchestration
     -> ctx:addLabel, ctx:addKeyValue, etc. add entries to shared RecipeContentPanel
     -> ctx.rootTable still accessible for direct ISTableLayout widget control
  -> After callbacks: shared panel (if non-empty) is initialise()'d and added to rootTable
  -> Force layout recalculation (xuiRecalculateLayout or dirtyLayout)
  -> Phase 4: cleanup (guaranteed, reuses callback ctx)
```

### Auto-Separator Between Providers

TooltipLib inserts spacer lines between providers automatically on all surfaces. The pattern uses deferred insertion:

1. Each hook file sets `ctx._needsSeparator = prevAddedContent and p.separator ~= false` and `ctx._itemCount = 0` before each callback
2. Every content-adding method calls its surface's separator function at the top:
   - Layout: `maybeInsertSeparator(self)` — adds a blank layout item
   - Rich Text: `maybeInsertRichTextSeparator(self)` — adds an empty line to `_lines`
   - Recipe: `maybeInsertRecipeSeparator(self)` — adds a spacer entry to `_panel`
3. After each callback, the hook checks `_itemCount > 0` to update `prevAddedContent`

This means: if a provider adds nothing (early return), no stale spacer appears. The separator fires on the first content-adding call only.

`addHeader` has additional intra-provider spacing: it inserts a spacer before itself when `_itemCount > 0` (i.e., not the first item in the provider). This creates section breaks within a single provider without doubling with the auto-separator.

### Error Circuit Breaker

Tracks consecutive errors per provider in `_errorCounts`. After 10 consecutive errors (`ERROR_THRESHOLD`), the provider is auto-disabled for the session. A single success resets the count. `resetProvider(id)` re-enables manually.

The breaker is checked at L1 evaluation (not mid-loop) so disabled providers drop out on next L1 refresh (max 60 frames). This avoids Lua 5.1's lack of `goto`.

Circuit breaker calls (`_recordError`/`_recordSuccess`) are integrated at all pcall sites across all hook files.

### Detail Mode

A configurable modifier key (default: LShift) sets `ctx.detail = true` on all provider contexts. Providers can:
- Check `ctx.detail` for conditional content
- Set `detailOnly = true` to only appear when the key is held

The detail state is part of both L1 and L2 cache keys. Toggling the key forces full re-evaluation.

Options.lua creates a PZAPI.ModOptions keybind panel. If PZAPI is unavailable, `_getDetailKeyCode()` falls back to `Keyboard.KEY_LSHIFT`.

### Provider Override System (User Configuration)

Players can enable/disable individual providers via Mod Options or the API:

**API (Core.lua)**:
- `setProviderEnabled(id, false)` — disables a provider, sets `_providerOverrides[id] = false`
- `setProviderEnabled(id, true)` — re-enables (clears override), sets `_providerOverrides[id] = nil`
- `isProviderEnabled(id)` — returns `nil` (default) or `false` (disabled)
- `resetProvider(id)` — clears BOTH circuit breaker AND user override

**Integration with _isDisabled**: `_isDisabled(id)` checks `_providerOverrides` first, then the circuit breaker. Since all 5 hook files already call `_isDisabled()` as their first check, provider overrides work across all surfaces with zero hook changes.

**Mod Options UI (Options.lua)**: On game start, `_refreshProviderOptions()` iterates all registered providers. Each provider with a `description` field gets a tick box in the TooltipLib options panel. PZAPI.ModOptions auto-persists to modOptions.ini. Providers without descriptions are considered internal and are hidden from the UI.

**`getProviders()` output** includes a `userDisabled` boolean field.

### Caching (Two Levels)

**Level 1 -- Active Provider Cache** (Hook.lua closure locals, per surface):
- Key: `itemId + _providerVersion + frameCounter + detailState`
- Value: list of providers that passed `enabled()` (or nil for "none")
- Invalidation: automatic on item change, `_providerVersion` bump, detail toggle, or every 60 frames (L1_REFRESH_INTERVAL)
- ISToolTipInv and ISToolTipItemSlot each have independent L1 caches

**Level 2 -- Callback Display List Cache** (opt-in per provider):
- Key: `providerId -> { itemId, cacheKey, displayList, frameRecorded, detailHeld }`
- Value: array of recorded `ctx:` method calls like `{ "addLabel", text, color }`
- Recording: RecordingContextMT / RecordingRichTextContextMT proxy
- Replay: replayDispatch / richTextReplayDispatch tables
- Invalidation: automatic on item change, `invalidateCache(providerId)`, cacheKey mismatch, maxAge expiration, detailHeld mismatch
- maxAge: default 60 frames (~1s), configurable per provider, 0 = infinite
- Note: Recipe providers cannot use caching (XUI widgets are stateful)

Display list entries are arrays accessed by numeric index (`entry[2]`, `entry[3]`). `nil` holes are safe because we never use `#` on these tables.

### RecordingContextMT Proxy Forwarding

RecordingContextMT uses a function-based `__index` that checks for recording wrapper methods first, then falls back to the real context. This ensures custom fields set by `preTooltip` (e.g., `ctx._savedClip`) are visible in cacheable callbacks without explicit forwarding.

`__newindex` forwards writes to the real context and logs a debug warning for non-internal fields, since these writes are not replayed from cache.

### Height Cap

After all content is added (post textures + postRender), the tooltip height is clamped to `screenHeight - 20`. If capped, a "..." indicator is drawn at the bottom center. Applies to both item tooltips (Hook.lua) and world object tooltips (HookWorldObject.lua).

### Frozen Colors

Colors are frozen via metatables that error on `__newindex`. Each individual color array is also frozen. Consumers who need mutable colors should copy: `{unpack(TooltipLib.Colors.GREEN)}`.

### Version Guard

Core.lua uses `VERSION_NUM` (integer) for the load guard:
```lua
if TooltipLib and TooltipLib.VERSION_NUM >= CURRENT_VERSION_NUM then return end
```
This ensures the newest version always wins when multiple mods bundle TooltipLib.

All internal state tables use `= TooltipLib._xxx or {}` initialization to preserve existing registrations when a newer version takes over from an older one. This prevents state loss if providers were registered between the two versions loading.

`VERSION` (string like "1.3.0") is the public-facing version. `VERSION_NUM` is internal.

### Semver Contract

Documented in Core.lua header. The contract:
- **Major**: may break public API
- **Minor**: additive only -- new methods, filters, options. Existing code unchanged.
- **Patch**: bug fixes only

Public API surface is enumerated in the Core.lua comment block. Everything prefixed with `_` is internal and may change.

## Key Design Decisions

### Single Layout Approach
All tooltip content (vanilla + all providers) goes into ONE layout. This means column widths (labels, values, progress bars) are computed together, giving perfect alignment. The alternative (separate layouts per provider) would cause misaligned columns.

### Texture Queue (Phase 2.5)
`ctx:addTexture()` and `ctx:addTextureRow()` queue draw operations during the callback phase. The framework processes them between layout render and postRender. This means providers don't need to write postRender code for simple textures -- the framework handles endY tracking and tooltip resizing automatically.

### Metatable Swap per Render
We temporarily replace `DoTooltip` on the item's metatable for each render call, then restore it. This is wrapped in pcall so the original is ALWAYS restored. This approach works with any mod that hooks ISToolTipInv.render because they all eventually call DoTooltip.

### Shared doLayoutDispatch Function
Hook.lua extracts the 5-phase dispatch body (phases 1-4 + height cap) into `doLayoutDispatch()`. Both ISToolTipInv and ISToolTipItemSlot hooks call this shared function, eliminating code duplication. Parameters: `tooltipItem, tooltip, activeProviders, detailHeld, surfaceName, extraFields, fallbackDoTooltip`.

### Item Providers Auto-Apply to Crafting Slots
When ISToolTipItemSlot renders an InventoryItem, `target = "item"` providers are merged with `target = "itemSlot"` providers via a sorted merge of two priority-sorted arrays. The merge result is memoized on `_providerVersion` to avoid re-allocating every frame. Providers can check `ctx.surface` to distinguish. This is the correct default because players expect the same item info in crafting as in inventory.

### Separate Hook Files per Surface Family
Each non-item surface gets its own Hook file. This keeps Hook.lua manageable and allows surfaces to be independently disabled if PZ changes break one but not others. Each hook file pcall-requires its PZ dependency.

### Unified Context API Across Surfaces
All three surface families (Layout, Rich Text, Recipe) share the same `add*` method signatures: `addLabel`, `addKeyValue`, `addProgress`, `addInteger`, `addFloat`, `addPercentage`, `addSpacer`, `addHeader`, `addDivider`, `addText`. Providers can use the same code on any surface — the framework handles rendering differences. Each surface type also has native methods for when providers need surface-specific control (Layout: `addTexture`/`addTextureRow`, Rich Text: `appendLine`/`appendRichText`/`setName`, Recipe: direct `ctx.rootTable` access).

### Three Separate Context Metatables
Despite sharing method signatures, ContextMT, RichTextContextMT, and RecipeContextMT are distinct metatables. Layout methods work on ObjectTooltip layouts, rich text methods generate PZ rich text markup, and recipe methods add entries to RecipeContentPanel. The separation means surface-specific methods (`appendLine` on rich text, `addTexture` on layout) fail with clear errors on the wrong surface.

### RecipeContentPanel as Rendering Abstraction
Recipe tooltips use XUI widgets (ISTableLayout), which are complex stateful UI panels. Rather than exposing raw ISTableLayout to every provider, the framework creates a single shared RecipeContentPanel (ISPanel subclass) for all providers. This panel stores content entries as data during callbacks and draws them via `drawText`/`drawRect` in `prerender()`. This gives providers the same `add*` API while keeping full visual control (multi-color text, actual progress bars, aligned key-value pairs). `ctx.rootTable` remains accessible for providers that need direct ISTableLayout widget control.

### World Object Tooltips: No L2 Caching
World objects don't have stable IDs like inventory items. L2 caching is not supported for `target = "object"` providers. L1 caching is also not used (event-driven, not per-frame).

**Two-pass rendering**: World object tooltips use a measure + render pattern. Provider callbacks execute **twice** per frame: once with `setMeasureOnly(true)` to compute dimensions, then once to render. Callbacks must be idempotent (no side effects). Circuit breaker only records results from the render pass.

### pcall-Hardened Filters
Filters are public API -- mod authors call them directly. Each filter wraps its PZ Java method call in pcall with log-once on failure. If PZ removes `IsWeapon()`, the filter returns false instead of crashing.

### Boot + First-Render Probes
- **Boot**: Checks `ISToolTipInv.render` exists before hooking. If PZ removes it, hook silently doesn't install.
- **First-render**: Checks `DoTooltip`/`DoTooltipEmbedded` on the first actual item metatable. If missing, permanently disables hook. This can't be checked at boot because we don't have an item object yet.
- **Shared probe state**: ISToolTipInv and ISToolTipItemSlot share the same probe state -- if one passes, the other skips the probe.

### _logOnce for Framework Errors
Framework-level errors (layout failure, dimension error, render chain error) use `_logOnce` to log once instead of spamming every frame. Provider-level errors still log every occurrence (different providers, different errors).

### resolveColor nil checks
`resolveColor()` uses explicit `~= nil` checks for defaults. In Lua 5.1, `0` is truthy (only `false` and `nil` are falsy), so `color[1] or 1` would actually work for 0 values. The explicit nil check is used for clarity and to correctly handle the default parameter path where callers might pass `nil` defaults.

### maxAge Safety Net
Cacheable providers default to `maxAge = 60` (~1 second). This provides a safety net against stale data when providers forget to invalidate. Providers that manage invalidation manually (via events) can set `maxAge = 0` for infinite cache.

## Gotchas

1. **Forward declaration order in Core.lua**: `parseVersion` and `isVersionAtLeast` must be defined before `registerProvider` uses them. They're placed in a "Version utilities" section above "Public API".

2. **RecordingContextMT must mirror ContextMT**: Every method added to ContextMT needs a matching wrapper in RecordingContextMT and an entry in replayDispatch. Same for RichTextContextMT / RecordingRichTextContextMT / richTextReplayDispatch. Both Helpers.lua and the CLAUDE.md warn about this.

3. **Lua 5.1 varargs**: We use explicit per-method wrappers (not `...` forwarding) in RecordingContextMT to avoid nil-hole issues with `select('#', ...)` in Lua 5.1.

4. **Display list nil holes are safe**: Entries like `{ "addKeyValue", key, val, nil, valColor }` have nil at index 4. We access by numeric index (`e[4]`), never by `#`. This is well-defined in Lua.

5. **Level 1 cache nil is valid**: `cachedActiveProviders = nil` means "no active providers" (vanilla path). The cache check `itemId == cachedItemId` correctly handles this since nil ~= any real ID would force re-evaluation.

6. **VERSION_NUM vs VERSION**: Bump both when releasing. VERSION_NUM is used for the load guard. VERSION is used for semver checks and display. They must stay in sync.

7. **_callbackCache lives on the global**: `TooltipLib._callbackCache` is accessible from anywhere. Providers call `invalidateCache()` to clear it. The Hook reads it in the Phase 2 callback loop.

8. **addKeyValue table-form caching**: RecordingContextMT shallow-copies the table arg to prevent cache corruption if the caller mutates the table between frames.

9. **cacheKey must return scalar types**: Tables are compared by reference (`==`) and will always miss. The framework logs a one-time warning if a cacheKey returns a table.

10. **Colors are frozen**: Both the Colors table and individual color arrays are read-only via metatables. `__newindex` errors on write attempts.

11. **Auto-separator + addHeader**: Never double-spaces. Auto-separator fires via `_needsSeparator` (inter-provider, cleared on first layout call). addHeader spacer fires when `_itemCount > 0` (intra-provider). These are distinct mechanisms.

12. **Detail toggle invalidates both cache levels**: L1 key includes `detailState`, L2 entry stores `detailHeld`. Toggle forces full re-evaluation and cache miss.

13. **Circuit breaker delay**: Disabled providers stay in `activeProviders` until next L1 refresh (max 60 frames). Acceptable tradeoff to avoid Lua 5.1 goto.

14. **ISToolTipItemSlot instanceof guard**: ISToolTipItemSlot.item can be Resource (not InventoryItem). The hook guards with `instanceof(item, "InventoryItem")` and falls back to vanilla for Resources.

15. **frameCounter shared across Layout hooks**: ISToolTipInv and ISToolTipItemSlot both increment the same `frameCounter`. If both fire in the same frame, intervals shorten by 2x. Acceptable — intervals are safety nets, not precision timing.

16. **World object hook uses tooltip.object**: `ObjectTooltip.object` is a public Java field set by PZ before firing `DoSpecialTooltip`. The hook reads it directly to get the exact hovered object, even when multiple objects share a grid square (e.g., microwave on top of a counter). Previous approach iterated the square's objects and picked the first match, which could select the wrong object.

17. **World object hook height**: IsoObject.DoSpecialTooltip sets tooltip height to 0 before firing the Lua event. If height stays 0, PZ hides the tooltip. Our hook MUST call `tooltip:setHeight(endY + padBottom)` for content to be visible.

18. **Rich text <LINE> separator**: ISToolTip uses PZ rich text markup. Lines are joined with ` <LINE> ` (with spaces). Missing spaces cause rendering issues.

19. **Provider overrides require description**: Only providers with a `description` field get tick boxes in Mod Options. Providers without descriptions can still be toggled via `setProviderEnabled()` API but won't appear in the UI.

20. **_isDisabled checks override before circuit breaker**: User override takes precedence. A provider explicitly disabled by the user stays disabled even if `resetProvider` would have re-enabled the circuit breaker. `resetProvider` clears both.

21. **Shared hook helpers in Core.lua**: `_readDetailKey()` and `_evaluateProviders()` are defined in Core.lua (shared/) but call client-side APIs (`GameKeyboard`, `_getDetailKeyCode`). This is safe because the hook files that call them are all client-only. The helpers are in Core.lua so all 5 hook files can share them without circular requires.

22. **RecipeContentPanel height estimation**: `addEntry()` estimates height using font measurement, and `prerender()` corrects the actual height. If height changes during prerender, `setHeight()` is called again. ISTableLayout re-reads child heights during its layout pass, so the correction takes effect.

23. **RecipeContentPanel drawRect alpha-first**: PZ's `drawRect(x, y, w, h, a, r, g, b)` takes alpha as the FIFTH parameter (before r, g, b), while `drawText(text, x, y, r, g, b, a, font)` takes alpha SEVENTH. Easy to mix up.

24. **Recipe providers: no caching**: RecipeContextMT has no RecordingRecipeContextMT. ISPanel objects are stateful and created fresh each time `createDynamicChildren` runs. Display lists can't replay widget creation.

25. **Rich text SETX alignment is per-provider**: `addKeyValue` on rich text surfaces uses `<SETX:n>` to align values. The X position is computed from the key text width at call time. This gives good alignment within a single provider, but values from different providers won't align with each other. Layout surfaces handle cross-provider alignment natively via Java's layout engine.

26. **`addProgress` renders differently per surface family**: Layout surfaces (item, object) and recipe render actual visual progress bars. Rich text surfaces (skill, vehicle) render "Label: 75%" as colored text — PZ's rich text engine has no native bar support. **Consumer beware**: a provider tested on item/object surfaces will produce visual bars, but the same `addProgress` call on a vehicle/skill surface produces flat text. This is inherent to PZ's rendering, not a TooltipLib bug.

27. **Cleanup reuses callback ctx**: All hook files pass the same `contexts[i]` table to both callback and cleanup. This means state set during callback (e.g., `ctx._myFlag = true`) is visible in cleanup. Previous versions of HookSkill/HookVehicle/HookRecipe created new tables for cleanup, which was a bug.

28. **Deferred mode alignment loss**: When another tooltip framework overwrites our DoTooltip swap, providers render in a separate layout pass. Column widths (labels, values, progress bars) align with each other but NOT with the vanilla/foreign content above. The `_logOnce("deferred_mode")` message warns about this.

29. **Deferred mode background**: ISToolTipInv.render draws its background BEFORE DoTooltip, sized from the measure pass. In deferred mode, the measure pass only sees the foreign framework's content — the background never "catches up" because each frame's measure pass resets to the foreign height. Fix: `drawDeferredBackground` pre-draws the background extension using cached dimensions from the previous frame. One-frame lag on first hover per item (imperceptible at 60fps). The deferred path also syncs `self:setHeight`/`self:setWidth` for positioning.

30. **ourWrapperFired fires on both passes**: Vanilla ISToolTipInv.render calls DoTooltip twice (measure pass, render pass). In normal mode, `ourWrapperFired` is set `true` on the first call (measure). The flag is only checked after `original_render` returns, so both passes run through our wrapper. In deferred mode, neither pass hits our wrapper.

31. **Object tooltip callbacks run twice**: HookWorldObject uses a two-pass pattern (measure + render). Provider callbacks execute twice per frame. Callbacks must be idempotent — no side effects, no counters, no state changes. Circuit breaker only records results from the render pass (`recordResults=true`).

32. **registerProvider clears circuit breaker on replace**: When re-registering a provider with the same ID (e.g., hot-reload), both `_callbackCache[id]` and `_errorCounts[id]` are cleared so the new callback starts fresh.

33. **ISToolTipItemSlot merge is memoized**: The sorted merge of item + itemSlot providers is cached as `slot_mergedProviders` keyed on `_providerVersion`. The merge only re-runs when providers are added/removed, not every frame.

34. **Vehicle overlay preserves vanilla description**: `renderCarOverlayTooltip` saves the vanilla description before clearing it. If providers add no content (empty `lines`), the vanilla description is restored.

35. **inRange bypasses during marking phase**: `_markingPhase` flag is set `true` by HookWorldObject during object marking (LoadGridsquare, OnObjectAdded, initial scan). `inRange` returns `true` unconditionally when this flag is set, so only type-check filters participate in marking decisions. Without this, objects far from the player at chunk-load time would never get `specialTooltip = true` and would never show tooltips even when the player walks up to them.

36. **enabled() must return `true` explicitly**: `_evaluateProviders` checks `eResult == true`, not truthiness. If `enabled()` returns nil (e.g., missing return statement), the provider is treated as disabled. This matches the `safeFilter` convention and prevents the common Lua mistake of forgetting a return value from silently enabling a provider for all items.

37. **Combinator filters forward all arguments**: `allOf`, `anyOf`, and `negate` forward varargs (`subject, ...`) to inner filters. This ensures object filters receiving `(object, square)`, skill filters receiving `(perk, level)`, etc., work correctly through combinators.

38. **Auto-priority avoids named constant collisions**: `_nextPriority` starts at 101 (just above `DEFAULT = 100`) and increments by 1. Auto-assigned providers occupy the range 101-199, between DEFAULT and LATE (200). Explicit priority constants (`EARLY`, `DEFAULT`, `LATE`, `LAST`) are never shadowed by auto-assignment.

39. **Shared hook helpers in Helpers.lua**: `_processTextureQueue` and `_installPostRenderWrap` are shared implementations used by multiple hook files to eliminate texture rendering and postRender wrap duplication. Both are defined on `TooltipLib._` and available to all client-side hook files.

## Adding a New ctx: Method (Layout)

1. Add the method to `ContextMT` in Helpers.lua
2. Call `maybeInsertSeparator(self)` at the top (if it adds to layout)
3. Increment `self._itemCount` (if it adds to layout)
4. Add a matching wrapper to `RecordingContextMT` in Helpers.lua
5. Add an entry to `replayDispatch` in Helpers.lua
6. Add to the PUBLIC API SURFACE comment in Core.lua
7. Add EmmyLua annotations
8. Bump minor version (additive change)

## Adding a New ctx: Method (Rich Text)

1. Add the method to `RichTextContextMT` in Helpers.lua
2. Add a matching wrapper to `RecordingRichTextContextMT` in Helpers.lua
3. Add an entry to `richTextReplayDispatch` in Helpers.lua
4. Add to the PUBLIC API SURFACE comment in Core.lua
5. Add EmmyLua annotations
6. Bump minor version (additive change)

## Adding a New ctx: Method (Recipe)

1. Add the method to `RecipeContextMT` in Helpers.lua
2. Call `maybeInsertRecipeSeparator(self)` at the top (if it adds content)
3. Increment `self._itemCount` (if it adds content)
4. Add an entry type to `RecipeContentPanel:prerender()` rendering loop
5. Add to the PUBLIC API SURFACE comment in Core.lua
6. Add EmmyLua annotations
7. Bump minor version (additive change)

Note: RecipeContextMT has NO recording/replay — recipe providers cannot use caching (ISPanel objects are stateful per-frame).

## Adding a New Target Surface

1. Add the target name to `VALID_TARGETS` in Core.lua
2. Create a new `HookXxx.lua` in `media/lua/client/TooltipLib/`
3. Decide which context family (Layout/RichText/Raw) and set the appropriate metatable
4. Add `pcall(require ...)` for the PZ class at the top of the hook file
5. Follow the pattern: event listener or function hook, evaluate providers, build contexts, run phases
6. Update CLAUDE.md file map and architecture sections
7. Update docs/GUIDE.md with per-target context shape and enabled() signature

## Testing

Test in-game only. No unit test framework.

- **Debug mode**: Set `TooltipLib.debug = true` to see cache hits/misses, maxAge expirations, L1 refreshes, and missing-enabled warnings
- **Filters**: Hover different item types, verify providers activate correctly
- **Caching**: Check debug log for L2 cache hit/miss per provider
- **maxAge**: Hover an item, verify callback re-runs after ~1 second (debug log shows "L2 maxAge expired")
- **Textures**: Register a provider with `ctx:addTextureRow()`, verify icons render below layout
- **Probes**: Temporarily break ISToolTipInv or DoTooltip, check log messages
- **minVersion**: Register with `minVersion = "99.0.0"`, verify rejection in log
- **Error recovery**: Force an error in a provider callback, verify other providers still render
- **Circuit breaker**: Force 10+ consecutive errors, verify provider disabled with log message, then `resetProvider()` to re-enable
- **Frozen Colors**: Try `TooltipLib.Colors.GREEN[1] = 0` in console, verify error
- **Auto-separator**: Register 2+ providers, verify spacer between them, verify no spacer when a provider adds nothing
- **Detail mode**: Hold Shift, verify `ctx.detail` is true, verify `detailOnly` providers appear/disappear
- **Height cap**: Register 20+ test providers, verify tooltip caps at screen height with "..." indicator
- **ModOptions**: Options > Mods > TooltipLib, verify detail key binding appears and is rebindable
- **Provider toggles**: Register a provider with `description`, open Mod Options, verify tick box, uncheck it, verify provider stops rendering. Re-check, verify it returns. Restart game, verify override persists.
- **setProviderEnabled API**: Call `TooltipLib.setProviderEnabled("id", false)` from console, verify provider disabled. Call with `true`, verify re-enabled. Call `resetProvider("id")`, verify both circuit breaker and override cleared.
- **Target routing**: Register providers with different targets, verify they only activate on the correct surface
- **ISToolTipItemSlot**: Open crafting panel, hover items, verify `target = "item"` providers show up alongside `target = "itemSlot"` providers
- **ctx.surface**: Log `ctx.surface` in a provider, verify "item" in inventory vs "itemSlot" in crafting
- **World objects**: Place a generator, set specialTooltip, hover, verify `target = "object"` providers render
- **Skill tooltips**: Open character info, hover a skill bar, verify `target = "skill"` providers append text
- **Vehicle tooltips**: Open vehicle mechanics, hover a part, verify `target = "vehicle"` providers append text
- **Recipe tooltips**: Open crafting panel, hover a recipe, verify `target = "recipe"` providers add widgets

## Consumer Mods

Three mods currently use TooltipLib:

- **VorpallySauced** (VPS): Weapon progression tooltips. Uses `Filters.weapon`, `cacheable = true`, `maxAge = 0` (event-driven invalidation).
- **ArmorMakesSense** (AMS): Armor burden/breathing tooltips. Uses `Filters.anyOf(clothing, container)`, `Filters.fluidContainer`, `cacheable = true`, `ctx:addTextureRow()` for container item textures.
- **Show Weapon Stats Plus** (SWSP): Detailed weapon statistics. Uses `Filters.weapon`, `Priorities.LATE`, not cacheable (reads player perks every frame).
