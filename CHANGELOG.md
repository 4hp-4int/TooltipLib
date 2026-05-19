# Changelog

All notable changes to TooltipLib are documented here.

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
