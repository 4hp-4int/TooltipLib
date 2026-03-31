# Changelog

All notable changes to TooltipLib are documented here.

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
