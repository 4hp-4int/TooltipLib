# TooltipLib

Shared tooltip framework for Project Zomboid Build 42. Multiple mods add content to item, crafting, world object, skill, vehicle, and recipe tooltips — zero conflicts, automatic alignment, error isolation.

## For Players

Install this if a mod lists it as a dependency. No configuration needed.

## For Mod Authors

Replace your 80-line metatable dance with one `registerProvider()` call:

```lua
require "TooltipLib/Core"

TooltipLib.registerProvider({
    id       = "MyMod_WeaponStats",
    target   = "item",
    enabled  = TooltipLib.Filters.weapon,
    cacheable = true,
    description = "Weapon damage stats",
    callback = function(ctx)
        ctx:addKeyValue("Damage:", "+15%", nil, TooltipLib.Colors.GREEN)
        ctx:addProgress("Mastery:", 0.75, nil, TooltipLib.Colors.GOLD)
    end,
})
```

No metatable juggling. No manual pcall nesting. No layout lifecycle management. No fighting other mods for the hook.

### Six Tooltip Surfaces

| Surface | `target =` | `enabled()` receives |
|---------|-----------|---------------------|
| Inventory item | `"item"` | `(item)` |
| Crafting slot | `"itemSlot"` | `(item)` |
| World object | `"object"` | `(object, square)` |
| Skill bar | `"skill"` | `(perk, level)` |
| Vehicle part | `"vehicle"` | `(part, vehicle)` |
| Recipe | `"recipe"` | `(recipe)` |

All six surfaces share the same `add*` methods: `addLabel`, `addKeyValue`, `addProgress`, `addInteger`, `addFloat`, `addPercentage`, `addSpacer`, `addHeader`, `addDivider`, `addText`. Your callback code works on any surface — the framework handles rendering differences.

### What You Get

- **Single shared layout** — vanilla stats, your content, and every other mod's content render together with aligned columns
- **Pre-built filters** — `Filters.weapon`, `Filters.food`, `Filters.clothing`, `Filters.container`, etc. All pcall-hardened against PZ API changes
- **Filter combinators** — `Filters.allOf(...)`, `Filters.anyOf(...)`, `Filters.negate(...)`
- **Automatic caching** — set `cacheable = true` and callbacks record once, replay for free
- **5-phase lifecycle** — `preTooltip` > `callback` > `textures` > `postRender` > `cleanup` (guaranteed even on error)
- **Circuit breaker** — 10 consecutive errors auto-disables a provider for the session
- **Detail mode** — `ctx.detail` is `true` when the player holds a configurable key (default: LShift)
- **Mod Options integration** — providers with `description` get a player-facing toggle automatically
- **Texture support** — `ctx:addTexture()` and `ctx:addTextureRow()` without writing postRender code
- **Color palette** — `Colors.GREEN`, `Colors.RED`, `Colors.GOLD`, etc. Frozen (read-only)
- **EmmyLua annotations** — full type annotations for IDE autocomplete

Full API documentation: [docs/GUIDE.md](docs/GUIDE.md)

## Compatibility

- **Build 42.13.1+** required
- Works alongside mods that hook `ISToolTipInv.render` directly
- Works with Inventory Tetris, Equipment UI, and other UI-replacing mods
- Detects competing DoTooltip hooks and falls back to deferred layout automatically
- Client-only — no server install needed, no network traffic, safe to add/remove mid-session

## Mods Using TooltipLib

- **VorpallySauced** — Weapon progression tooltips
