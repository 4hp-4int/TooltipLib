# TooltipLib Developer Guide

If you've modded PZ tooltips before, you know the drill: hook `ISToolTipInv.render`, do your drawing, and pray no other mod hooks the same function. When two mods both want to add lines to item tooltips, somebody's content gets stomped. TooltipLib fixes that. You register a provider, it handles the rest — hooking, ordering, column alignment, error isolation, the works.

One `registerProvider()` call, and your content shows up in the tooltip alongside vanilla stats and every other mod's content, with aligned columns and no conflicts.

## Quick Start

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
    end,
})
```

That's a complete provider. `enabled` says "only run for weapons," `cacheable` says "don't re-run my callback every frame," and `description` gives it a human-readable name that players see as a toggle in Mod Options. The callback gets a context object (`ctx`) with bound methods for adding content to the tooltip.

Under the hood, TooltipLib hooks the vanilla render chain and funnels all providers into a single shared layout — so your "Damage: +15%" line sits right below vanilla stats, columns aligned, no drawing code needed.

## The Six Surfaces

Tooltips aren't just for items. PZ has separate tooltip systems for inventory items, world objects you hover over, skill progress bars, vehicle parts in the mechanics overlay, and crafting recipes. TooltipLib hooks all of them.

| Surface | `target =` | What you're adding to | `enabled()` gets |
|---------|-----------|----------------------|-----------------|
| Item | `"item"` | Inventory item tooltips | `(item)` |
| Item Slot | `"itemSlot"` | Item tooltips (slot variant) | `(item)` |
| World Object | `"object"` | Hover tooltips on placed objects | `(object, square)` |
| Skill | `"skill"` | Skill progress bar tooltips | `(perk, level)` |
| Vehicle | `"vehicle"` | Vehicle part tooltips | `(part, vehicle)` |
| Recipe | `"recipe"` | Crafting recipe tooltips | `(recipe)` |

These fall into three rendering families, but **all six surfaces share the same `add*` methods**: `ctx:addLabel()`, `ctx:addKeyValue()`, `ctx:addProgress()`, `ctx:addInteger()`, `ctx:addFloat()`, `ctx:addPercentage()`, `ctx:addSpacer()`, `ctx:addHeader()`, `ctx:addDivider()`, `ctx:addText()`. Your callback code works identically on any surface — the framework handles the rendering differences behind the scenes.

**Layout surfaces** (item, itemSlot, object) use PZ's `ObjectTooltip` layout system. Everything goes into one shared layout with aligned columns. These also support `ctx:addTexture()` and `ctx:addTextureRow()` for drawing icons below the layout.

**Rich text surfaces** (skill, vehicle) append to an `ISToolTip` via PZ's rich text markup. The unified `add*` methods generate properly formatted markup with `<SETX:n>` alignment for key-value pairs. Surface-specific methods (`ctx:appendLine()`, `ctx:appendRichText()`, `ctx:setName()`) are also available for raw rich text control.

**Recipe surface** uses a `RecipeContentPanel` (ISPanel subclass) that draws provider content via `drawText`/`drawRect`. The unified `add*` methods work here too — including actual visual progress bars. Direct access to `ctx.rootTable` (ISTableLayout) is still available for providers that need native XUI widget control.

## Registration

Every surface uses the same `registerProvider()` call. Here's the full set of options:

```lua
TooltipLib.registerProvider({
    -- REQUIRED
    id       = "MyMod_Feature",       -- unique string, namespaced to your mod
    callback = function(ctx) end,     -- where you add tooltip content

    -- OPTIONAL
    target      = "item",             -- which surface (default "item")
    enabled     = function(...),      -- should this provider run? (args vary by surface)
    priority    = 100,                -- lower = earlier in tooltip (default: auto)
    description = "Short text",       -- shows up in Mod Options as a toggle
    preTooltip  = function(ctx),      -- runs before vanilla tooltip renders
    postRender  = function(ctx),      -- runs after layout, for direct drawing (Layout surfaces only)
    cleanup     = function(ctx),      -- always runs, even on error — undo preTooltip here
    cacheable   = true,               -- replay callback from cache instead of re-running
    cacheKey    = function(item),     -- extra signal for cache invalidation
    maxAge      = 60,                 -- frames before cache auto-refreshes (default 60)
    minVersion  = "1.0.0",           -- reject registration if TooltipLib is too old
    separator   = true,               -- auto-spacer between this and previous provider
    detailOnly  = false,              -- only show when Shift (detail key) is held
})
```

A few things worth noting:

**`description` does double duty.** It's not just documentation — if you set it, TooltipLib automatically creates a checkbox in Mod Options (requires PZAPI.ModOptions / Umbrella) so players can toggle your provider on/off. Always set it.

**`enabled` is how you avoid doing unnecessary work.** Without it, your callback runs for every single item/object/skill/etc. The built-in `Filters` (covered below) handle common cases. You can also write your own function — just keep it cheap, since it runs on every hover.

**`priority` usually doesn't matter.** If you omit it, providers render in registration order, which is fine for most mods. The constants (`Priorities.FIRST` through `Priorities.LAST`) are there if you need to guarantee ordering relative to other providers.

### Lifecycle Phases

Layout surfaces (item, itemSlot, object) run through five phases per render:

1. **preTooltip** — Runs before vanilla draws anything. Use this if you need to temporarily mutate the item (e.g., change a display name) so vanilla renders it differently. Rare.
2. **callback** — The main phase. Add your content here.
3. **textures** — Framework-managed. Any textures you queued with `ctx:addTexture()` get drawn here.
4. **postRender** — The escape hatch. If you need to draw something the layout API can't express (custom shapes, sprites at specific coordinates), do it here. You get `ctx.endY` and `ctx.width` to know where the layout ended.
5. **cleanup** — Always runs, even if your callback threw an error. Undo whatever `preTooltip` did.

Rich text and recipe surfaces run preTooltip + callback + cleanup (no textures or postRender phase).

Most providers only need `callback`. The other phases exist for edge cases that come up in complex mods.

---

## Item Surface

This is where you'll spend most of your time. Item tooltips are the bread and butter of PZ modding, and the layout API is designed to make them easy.

Your callback gets a context with:

```lua
ctx.item     -- the InventoryItem being hovered
ctx.tooltip  -- the ObjectTooltip Java object
ctx.layout   -- the shared layout (only available during callback)
ctx.helpers  -- TooltipLib.Helpers table
ctx.detail   -- true if player is holding the detail key (default: LShift)
ctx.surface  -- "item"
```

You don't touch `ctx.layout` directly — the bound methods do that for you.

**Item providers auto-apply to crafting slots.** When hovering items in `ISToolTipItemSlot` (the crafting panel), both `target = "item"` and `target = "itemSlot"` providers are evaluated and merged by priority. Your item provider will appear in crafting tooltips automatically. Check `ctx.surface == "itemSlot"` if you need to distinguish or hide content in crafting slots specifically.

### What You Can Add

The layout methods are the core of the API. Every one of these adds a line to the tooltip, aligned with vanilla stats:

```lua
local C = TooltipLib.Colors

-- Simple colored label
ctx:addLabel("Legendary Weapon", C.GOLD)

-- Key on the left, value on the right, aligned columns
ctx:addKeyValue("Damage:", "+15%", C.WHITE, C.GREEN)

-- Progress bar (0.0 to 1.0)
ctx:addProgress("Durability:", 0.75, nil, C.BLUE)

-- Integer with automatic green/red based on sign
ctx:addInteger("Critical:", 15, true)  -- true = positive is green

-- Blank line
ctx:addSpacer()

-- Section header — gets an automatic spacer above it (unless it's the first thing)
ctx:addHeader("-- Bonuses --", C.GOLD)

-- Thin horizontal rule
ctx:addDivider()
```

**`addFloat` and `addPercentage`** handle the common pattern of "+X" in green / "-X" in red:

```lua
-- addFloat(label, value, decimals, highGood)
ctx:addFloat("Speed:", 0.35, 1, true)    -- "+0.4" in green
ctx:addFloat("Weight:", -0.5, 1, false)  -- "-0.5" in green (for weight, lower IS better)

-- addPercentage(label, fraction, decimals, highGood)
ctx:addPercentage("Crit:", 0.15, 0, true)   -- "+15%" in green
```

The `highGood` parameter (defaults to `true`) controls which direction is green vs red. Set it to `false` for stats where lower is better — weight, recoil, that kind of thing.

**`addText`** does word-wrapping. Pass it a long string and it'll split across multiple lines to fit the tooltip width. Good for flavor text or descriptions:

```lua
ctx:addText("This ancient blade has been passed down through generations, "
    .. "growing stronger with each foe it fells.", C.GRAY)
```

**Textures** can be queued and the framework draws them below the layout for you:

```lua
-- Single texture
ctx:addTexture(item:getTexture(), 32, 32)

-- Row of textures that auto-wraps (good for showing container contents)
ctx:addTextureRow(textureArray, 16, 2)  -- 16x16 icons, 2px spacing
```

### postRender — The Escape Hatch

If the layout API isn't enough (custom shapes, drawing at specific coordinates), use `postRender`. The context gains some extra fields:

```lua
postRender = function(ctx)
    -- ctx.endY:     where the layout ended (draw below this)
    -- ctx.width:    current tooltip width
    -- ctx.padLeft, ctx.padRight, ctx.padBottom: padding values

    -- Draw your thing, then update endY so the tooltip resizes:
    ctx.tooltip:DrawTextureScaledAspect(myTexture, ctx.padLeft, ctx.endY, 64, 64, 1,1,1,1)
    ctx.endY = ctx.endY + 68
end,
```

### Full Example — Food Provider

This is a real provider from SauceTooltips. It shows freshness, calories, macros, and danger warnings for food items. Notice how it uses `ctx.detail` to gate extra information behind the Shift key:

```lua
require "TooltipLib/Core"

local C = TooltipLib.Colors
local Filters = TooltipLib.Filters

TooltipLib.registerProvider({
    id = "SauceTooltips_Food",
    target = "item",
    enabled = Filters.food,
    cacheable = true,
    description = "Food: freshness, calories, and nutrition",
    callback = function(ctx)
        local item = ctx.item
        local food = item:getFood()
        if not food then return end

        -- Freshness bar — color-coded green/yellow/red
        local offAge = item:getOffAge()
        if offAge and offAge > 0 then
            local fraction = 1.0 - math.min(item:getAge() / offAge, 1.0)
            local barColor = C.GREEN
            if fraction < 0.25 then barColor = C.RED
            elseif fraction < 0.5 then barColor = C.YELLOW end

            -- Frozen items get a different label and blue bar
            if food:isFrozen() then
                ctx:addProgress("Frozen:", fraction, nil, {0.5, 0.7, 1.0, 1.0})
            else
                ctx:addProgress("Freshness:", fraction, nil, barColor)
            end
        end

        local calories = food:getCalories()
        if calories and calories ~= 0 then
            ctx:addKeyValue("Calories:", string.format("%.0f", calories), nil, C.WHITE)
        end

        -- Danger warnings — always visible, no detail gating
        if food:isPoison() then
            ctx:addLabel("POISONED!", {1.0, 0.2, 0.2, 1.0})
        end

        -- Shift to see food type, packaged status, etc.
        if ctx.detail then
            local foodType = food:getFoodType()
            if foodType and foodType ~= "" then
                ctx:addKeyValue("Food Type:", tostring(foodType), C.GRAY, C.WHITE)
            end
        end
    end,
})
```

---

## World Object Surface

If you've read the item section, you already know how this works — same layout API, same `ctx:addLabel()` / `ctx:addKeyValue()` / `ctx:addProgress()` methods. The only differences are what's on the context and how `enabled()` works.

World object tooltips fire through PZ's `DoSpecialTooltip` event when you hover objects that have `specialTooltip = true` in their script definition (generators, rain collectors, etc.).

Context looks like:

```lua
ctx.object   -- the IsoObject you're hovering
ctx.square   -- its IsoGridSquare
ctx.tooltip  -- ObjectTooltip
ctx.layout   -- shared layout (during callback)
ctx.detail   -- boolean
ctx.surface  -- "object"
```

And `enabled()` receives `(object, square)` instead of `(item)`:

```lua
TooltipLib.registerProvider({
    id = "MyMod_Generator",
    target = "object",
    enabled = TooltipLib.Filters.generator,  -- IsoGenerator check
    description = "Generators: fuel and condition",
    callback = function(ctx)
        local gen = ctx.object
        if gen:isActivated() then
            ctx:addLabel("Running", TooltipLib.Colors.GREEN)
        else
            ctx:addLabel("Off", TooltipLib.Colors.RED)
        end
        ctx:addProgress("Fuel:", gen:getFuel() / 100)
    end,
})
```

One thing to know: **there's no L2 caching for objects.** World objects don't have stable IDs the way inventory items do, so the `cacheable` option is ignored for `target = "object"`. Your callback runs every frame while hovering. Keep it light.

---

## Skill Surface

Skill tooltips are the ones you see when hovering a skill in the character panel. They use PZ's rich text system under the hood, but you don't need to think about that — the same `ctx:addLabel()`, `ctx:addKeyValue()`, `ctx:addFloat()` etc. that work on item tooltips work here too.

Context:

```lua
ctx.perk     -- PerkFactory.Perk being hovered
ctx.level    -- current level (number)
ctx.player   -- IsoGameCharacter
ctx.tooltip  -- ISToolTip
ctx.detail   -- boolean
ctx.surface  -- "skill"
```

`enabled()` receives `(perk, level)`, so you can filter by specific perks or level ranges:

```lua
TooltipLib.registerProvider({
    id = "MyMod_SkillXP",
    target = "skill",
    description = "Skills: XP multiplier",
    enabled = function(perk, level)
        return level < 10  -- no point showing XP info for maxed skills
    end,
    callback = function(ctx)
        local player = ctx.player
        if not player then return end

        local ok, multiplier = pcall(function()
            return player:getXp():getMultiplier(ctx.perk)
        end)
        if ok and multiplier then
            ctx:addFloat("XP Multiplier:", multiplier, 2, true)
        end
    end,
})
```

All the unified `add*` methods work: `addLabel`, `addKeyValue`, `addProgress`, `addInteger`, `addFloat`, `addPercentage`, `addSpacer`, `addHeader`, `addDivider`, `addText`. Key-value pairs get `<SETX:n>` alignment within each provider.

For raw rich text control, surface-specific methods are also available:

```lua
ctx:appendLine("text", color)                     -- colored line of text
ctx:appendKeyValue("Key:", "Value", keyColor, valueColor)  -- formatted pair (no SETX)
ctx:appendRichText("<INDENT:20> <RGB:1,0,0> raw")  -- raw PZ markup if you need it
ctx:setName("New Title")                           -- change the tooltip title
```

**Limitations vs layout surfaces**: Progress bars render as colored percentage text ("75%") rather than visual bars. Column alignment works within a single provider via `<SETX:n>` but values from different providers won't align with each other. No `addTexture`/`addTextureRow`.

---

## Vehicle Surface

Same API as skills — shows up when you hover vehicle parts in the mechanics overlay. Same unified `add*` methods, same rich text surface-specific methods.

Context has `ctx.part` (VehiclePart) and `ctx.vehicle` (BaseVehicle) instead of perk/level. `enabled()` receives `(part, vehicle)`:

```lua
TooltipLib.registerProvider({
    id = "MyMod_VehicleCondition",
    target = "vehicle",
    description = "Vehicle parts: condition",
    callback = function(ctx)
        local part = ctx.part
        if not part then return end

        local ok, condition = pcall(function() return part:getCondition() end)
        if ok and condition then
            ctx:addPercentage("Condition:", condition / 100, 0, true)
        end
    end,
})
```

Same limitations as skill surface (text-only progress bars, no cross-provider alignment, no caching).

---

## Recipe Surface

Recipe tooltips in Build 42 use `ISCraftRecipeTooltip` with an `ISTableLayout` widget tree. Despite the different rendering engine, the same `add*` methods work here — the framework creates a `RecipeContentPanel` (ISPanel subclass) that draws your content via `drawText`/`drawRect`, including actual visual progress bars.

```lua
ctx.recipe    -- CraftRecipe object
ctx.logic     -- crafting logic reference
ctx.player    -- IsoGameCharacter
ctx.tooltip   -- ISCraftRecipePanel (the side panel instance)
ctx.rootTable -- ISTableLayout (for direct widget access)
ctx.detail    -- boolean
ctx.surface   -- "recipe"
```

`enabled()` receives `(recipe)`. Caching is not supported (widgets are stateful objects, not declarable lists).

**Note:** `ctx.logic` may be `nil` when rendering via the `ISCraftRecipeTooltip` floating tooltip fallback (used by the build menu). Always nil-check before accessing it.

Here's a recipe provider using the unified API — same code you'd write for an item provider:

```lua
TooltipLib.registerProvider({
    id = "MyMod_RecipeTime",
    target = "recipe",
    description = "Recipes: craft time",
    callback = function(ctx)
        local recipe = ctx.recipe
        if not recipe then return end

        local ok, timeVal = pcall(function() return recipe:getTimeToMake() end)
        if not ok or not timeVal or timeVal <= 0 then return end

        ctx:addKeyValue("Craft Time:", string.format("%.0fs", timeVal))
        ctx:addProgress("Skill Match:", 0.75, nil, TooltipLib.Colors.GREEN)
    end,
})
```

### Direct Widget Access (Escape Hatch)

If the `add*` methods don't cover your use case, `ctx.rootTable` gives you the raw `ISTableLayout` for building ISPanel widgets directly:

```lua
callback = function(ctx)
    local rootTable = ctx.rootTable
    if not rootTable then return end

    local panel = ISRichTextPanel:new(0, 0, rootTable:getWidth(), 0)
    panel:initialise()
    panel.autosetheight = true
    panel.background = false
    panel:setText("<RGB:0.7,0.7,0.7> Custom: <RGB:1,1,1> content")
    panel:paginate()

    local row = rootTable:addRow()
    rootTable:setElement(0, row:index(), panel)
end,
```

Using `ctx.rootTable` directly alongside `add*` methods in the same callback works fine — the framework adds its RecipeContentPanel as an additional row after your callback finishes.

---

## Filters

PZ's item type checking API is... inconsistent. `IsLiterature()` matches ID cards. `IsWeapon()` doesn't exist on every item class. Methods get renamed or removed between builds. If your `enabled()` function calls a PZ method that doesn't exist, your provider crashes on every hover.

TooltipLib's filters handle all of this. Every filter wraps its PZ API call in `pcall` and logs a one-time warning if it fails, so a PZ update that renames `IsWeapon()` won't take down your mod — the filter just returns `false` and you get a log message telling you what happened.

### Pre-built Item Filters

```lua
local F = TooltipLib.Filters

F.weapon         -- any HandWeapon (melee or ranged)
F.melee          -- melee only (weapon + not ranged)
F.firearm        -- ranged only (firearms, bows)
F.clothing       -- clothing and armor
F.food           -- food items
F.container      -- bags, backpacks, anything with inventory
F.fluidContainer -- water bottles, gas cans, bleach
F.drainable      -- batteries, lighters, anything with a use bar
F.literature     -- books and magazines (Java Literature class)
F.skillBook      -- just skill XP books (not magazines, not ID cards, not novels)
F.recipeBook     -- books that teach crafting recipes
F.key            -- keys (house, car, padlock)
F.stackable      -- items that stack (ammo, nails)
F.medical        -- medical items (bandages, pills, first aid)
```

A note on `literature` vs `skillBook` vs `recipeBook`: PZ's `IsLiterature()` Java method is frustratingly broad — it matches ID cards and other non-Literature items. The `literature` filter uses `instanceof` instead, which correctly targets only actual `Literature` Java class instances. `skillBook` narrows further to books that train a skill (checking `getLvlSkillTrained() ~= -1`), and `recipeBook` targets books with `getLearnedRecipes()`.

### World Object Filters

```lua
F.generator      -- IsoGenerator
F.rainCollector  -- IsoRainCollectorBarrel
F.farmPlant      -- IsoPlant
```

### Filter Factories

When the pre-built filters don't cover your case:

```lua
-- Match a specific script item type
F.customType("Base.Axe")

-- Match by Java class — works for both items and world objects
F.instanceof("Literature")
F.instanceof("IsoGenerator")

-- Match by item script tag (the ItemTag enum fields)
F.hasTag("COOKABLE")
F.hasTag("IS_FIRE_FUEL")

-- Match by DisplayCategory from script definitions
-- Common values: "SkillBook", "Weapon", "FirstAid", "Cooking", "Tool", "Gardening"
F.displayCategory("SkillBook")

-- Match world objects by sprite name
F.objectSprite("appliances_cooking_01_0")
```

### Range Filter

`inRange` restricts a provider to items or objects near the player. Useful for preventing tooltip info from appearing on items in distant containers where it would give an unfair advantage (e.g., seeing container contents across the room).

```lua
-- Only show when within 3 tiles of the container/object
F.inRange(3)

-- Combine with a type filter — container info only when nearby
enabled = F.allOf(F.container, F.inRange(3))
```

How it works:
- **Items in the player's inventory** always pass (distance 0).
- **Items in world containers** (furniture, corpses) measure Chebyshev distance from the player to the container's parent object. Different floors always fail.
- **World objects** measure distance directly to the object.
- If position can't be determined, the filter passes through (doesn't block).

Designed for `item`, `itemSlot`, and `object` targets. Using it on skill/vehicle/recipe targets is harmless (pcall-safe) but pointless — those UIs already require proximity to open.

### Combining Filters

The combinators let you build complex filters without writing custom functions:

```lua
-- Both conditions must be true (tactical vests are clothing AND containers)
enabled = F.allOf(F.clothing, F.container)

-- Either condition
enabled = F.anyOf(F.weapon, F.clothing)

-- Negation
enabled = F.negate(F.food)
```

If you need custom logic on top of a filter, compose them yourself. Just do the fast filter check first so your expensive logic only runs on relevant items:

```lua
local isClothingOrContainer = F.anyOf(F.clothing, F.container)

enabled = function(item)
    if not isClothingOrContainer(item) then return false end
    return myExpensiveCheck(item)  -- only runs for clothing/containers
end,
```

Pre-compose outside the function. Don't create a new `anyOf()` inside `enabled()` — that allocates a new closure on every hover.

---

## Detail Mode

Tooltips can get noisy when multiple providers are active. Detail mode gives players a way to opt into extra information: hold the detail key (default: Left Shift) and hidden content appears.

There are two ways to use it. You can gate specific content behind `ctx.detail`:

```lua
callback = function(ctx)
    ctx:addKeyValue("Damage:", "15")  -- always visible
    if ctx.detail then
        ctx:addKeyValue("Base Damage:", "10")
        ctx:addKeyValue("Bonus Damage:", "+5")
    end
end,
```

Or register the entire provider as detail-only:

```lua
detailOnly = true,  -- provider is invisible until Shift is held
```

The detail key is configurable in **Options > Mods > TooltipLib** (requires PZAPI.ModOptions / Umbrella). Falls back to Left Shift if ModOptions isn't installed.

---

## Caching

Tooltip callbacks run every frame while hovering. For simple providers that's fine, but if your callback does anything expensive (Java method calls, string formatting, loops over containers), you'll want caching.

```lua
cacheable = true,
```

With this set, the framework records your `ctx:` method calls on the first render, then replays them from a display list on subsequent frames. Your callback code literally doesn't run — the framework just replays "addKeyValue with these args, addProgress with these args" directly to the layout.

The cache auto-invalidates when the player hovers a different item. While hovering the same item, it refreshes every 60 frames (~1 second) by default. You can tune this:

```lua
cacheable = true, maxAge = 30,  -- refresh every ~0.5s
cacheable = true, maxAge = 0,   -- never auto-refresh (manual invalidation only)
```

**Which surfaces support caching:**

| Surface | Cached? | Why |
|---------|---------|-----|
| item, itemSlot | Yes | Items have stable IDs for cache keying |
| object | No | World objects lack stable IDs |
| skill, vehicle | No | Rich text surfaces — not currently cached |
| recipe | No | XUI widgets are stateful, can't be replayed |

### When Caching Gets Tricky

The cache assumes your output depends only on the item, the detail key state, and optionally your `cacheKey`. If your callback reads other state (player perks, game time, external data), the cache won't know to invalidate. You have three options:

1. **`cacheKey`** — return a value that captures the external state. Cache invalidates when this changes:
   ```lua
   cacheKey = function(item)
       return tostring(item:getModData().myVersion or 0)
   end,
   ```
   Must return string, number, boolean, or nil. Tables are compared by reference and will always miss.

2. **`invalidateCache("MyMod")`** — call this when your external state changes (event-driven).

3. **`maxAge`** — let it refresh periodically as a safety net.

One gotcha: setting fields on `ctx` inside a cacheable callback (like `ctx.myFlag = true`) won't be replayed from cache. If other phases need shared state, set it in `preTooltip` instead.

---

## Auto-Separator

When multiple providers add content to the same tooltip, TooltipLib automatically inserts a blank line between them so each provider's content is visually distinct. The separator is deferred — it only fires when your callback actually adds something. If you early-return without adding content, no orphaned spacer appears.

To opt out for a specific provider: `separator = false`.

**Don't add manual leading spacers.** If your callback starts with `ctx:addSpacer()`, you'll get a double-space when the auto-separator fires. Let the framework handle inter-provider spacing — only use `addSpacer()` for spacing *within* your own content.

---

## Colors

```lua
local C = TooltipLib.Colors

C.WHITE       -- {1.0, 1.0, 1.0, 1.0}
C.GRAY        -- {0.7, 0.7, 0.7, 1.0}
C.DARK_GRAY   -- {0.5, 0.5, 0.5, 1.0}
C.GREEN       -- {0.4, 1.0, 0.4, 1.0}
C.RED         -- {1.0, 0.4, 0.4, 1.0}
C.BLUE        -- {0.4, 0.6, 1.0, 1.0}
C.YELLOW      -- {1.0, 1.0, 0.4, 1.0}
C.GOLD        -- {1.0, 0.84, 0.0, 1.0}
C.ORANGE      -- {1.0, 0.7, 0.3, 1.0}
C.PURPLE      -- {0.8, 0.4, 1.0, 1.0}
C.HEADER      -- {0.9, 0.9, 0.9, 1.0}
C.PROGRESS    -- {0.4, 0.6, 1.0, 1.0}
```

These are `{r, g, b, a}` tables. Pass `nil` anywhere a color is expected to get the default.

The color tables are frozen (read-only). If you try to modify one you'll get an error. Need a mutable copy? Copy by index — `{C.GREEN[1], C.GREEN[2], C.GREEN[3], C.GREEN[4]}`. Don't use `unpack()` — it doesn't work on frozen tables in Lua 5.1/Kahlua. Or just define your own — any `{r, g, b, a}` table works fine:

```lua
local MY_PURPLE = {0.6, 0.2, 0.9, 1.0}
ctx:addLabel("Epic", MY_PURPLE)
```

---

## Priority

Lower numbers render first (closer to the top of the tooltip):

```lua
TooltipLib.Priorities.FIRST    -- 10
TooltipLib.Priorities.EARLY    -- 25
TooltipLib.Priorities.DEFAULT  -- 100
TooltipLib.Priorities.LATE     -- 200
TooltipLib.Priorities.LAST     -- 500
```

If you don't set `priority`, providers render in the order they were registered. This is usually fine — priority is there for cases where you need to guarantee your content appears before or after another specific mod's content.

---

## Error Handling

TooltipLib wraps every provider call in `pcall`. If your callback throws, other providers keep running and an error gets logged. But if you have a persistent bug that errors every frame, the logs get noisy fast.

The **circuit breaker** handles this: after 10 consecutive errors, your provider gets auto-disabled for the session. The log tells you what happened and how to fix it:

```
[TooltipLib] Provider 'MyMod' disabled after 10 consecutive errors.
Call TooltipLib.resetProvider('MyMod') to re-enable.
```

A single successful render resets the counter, so intermittent errors won't trip the breaker. Only persistent, every-frame errors.

There's also a **height cap** — if the combined content from all providers would make the tooltip taller than the screen, it gets clamped to `screenHeight - 20` with a "..." indicator at the bottom.

---

## Version Checking

If TooltipLib is an optional dependency for your mod, check before registering:

```lua
if TooltipLib and TooltipLib.checkVersion("1.0.0") then
    TooltipLib.registerProvider({ ... })
end
```

If it's a hard dependency, use `minVersion` in the registration itself — the provider gets rejected with a clear log message if the installed version is too old:

```lua
minVersion = "1.0.0",
```

TooltipLib follows semver: minor versions are additive (your code won't break), major versions may change the API.

---

## Compatibility With Other Tooltip Mods

TooltipLib is designed to coexist with mods that modify tooltips independently — even mods that don't use TooltipLib.

**Mods that hook `ISToolTipInv.render` and call the original** (the standard pattern): these chain naturally. TooltipLib stores and calls the original render function, so your mod's hook and TooltipLib's hook both fire regardless of load order.

**Mods that replace the inventory pane** (Inventory Tetris, Equipment UI): these change which item is passed to the tooltip, but use vanilla `ISToolTipInv` for the actual rendering. TooltipLib's providers appear normally.

**Mods that swap `DoTooltip` on the item metatable** (StarlitLibrary): these compete for the same hook point. TooltipLib detects this at render time — if its DoTooltip wrapper was overwritten by another framework, it falls back to a **deferred layout pass**. Provider content renders below the other framework's output in a separate layout. Alignment with vanilla rows is lost (providers still align with each other), but content is always visible.

You'll see a one-time log message if deferred mode activates:
```
[TooltipLib] DoTooltip wrapper overridden by another mod — using deferred layout.
```

As a provider author, you don't need to do anything — the framework handles it transparently. Your `callback` code runs identically in both normal and deferred mode.

---

## Multiplayer

Nothing to worry about. TooltipLib is purely client-side — no server code, no network traffic, no persistent state. It's safe to add or remove mid-session without affecting the server or other players.

---

## Debugging

```lua
TooltipLib.debug = true
```

This logs cache hits/misses, L1 refreshes, maxAge expirations, filter warnings, and texture processing to the PZ debug log. Zero overhead when `false` (the log function early-returns before even concatenating the message string).

For checking what's registered at runtime:

```lua
-- All providers, sorted by priority
local providers = TooltipLib.getProviders()
for _, p in ipairs(providers) do
    print(p.id, p.target, p.priority, p.disabled and "DISABLED" or "ok")
end

-- Just one surface
local skillProviders = TooltipLib.getProviders("skill")

-- Quick checks
TooltipLib.hasProvider("MyMod")       -- boolean
TooltipLib.getProviderCount()         -- total across all surfaces
TooltipLib.getProviderCount("item")   -- just item providers
```

`getProviders()` returns tables with: `id`, `target`, `priority`, `description`, `cacheable`, `detailOnly`, `separator`, `hasPreTooltip`, `hasPostRender`, `hasCleanup`, `errorCount`, `disabled`, `userDisabled`.

---

## Other API

```lua
TooltipLib.removeProvider("MyMod")              -- unregister entirely
TooltipLib.resetProvider("MyMod")               -- re-enable after circuit breaker
TooltipLib.setProviderEnabled("MyMod", false)   -- disable by user preference
TooltipLib.isProviderEnabled("MyMod")           -- check user override state
TooltipLib.invalidateCache("MyMod")             -- clear one provider's cache
TooltipLib.invalidateCache()                    -- clear all caches
TooltipLib.invalidateActiveProviders()          -- force re-eval of all enabled() filters
TooltipLib.VERSION                              -- version string (e.g., "1.0.0")
```
