-- ============================================================================
-- TooltipLib Filters — Pre-built enabled() functions for common item types
-- ============================================================================
-- Pass these directly as the 'enabled' field when registering a provider:
--
--   TooltipLib.registerProvider({
--       id = "MyMod",
--       enabled = TooltipLib.Filters.melee,
--       callback = function(ctx) ... end,
--   })
--
-- Combinators let you compose filters:
--
--   enabled = TooltipLib.Filters.allOf(
--       TooltipLib.Filters.clothing,
--       TooltipLib.Filters.container
--   )
-- ============================================================================

require "TooltipLib/Core"

-- ============================================================================
-- Item type filters
-- ============================================================================
-- Each filter is a function(item) -> boolean. All filters are pcall-hardened
-- via safeFilter() — if PZ removes or renames an API method, the filter
-- returns false and logs a one-time warning instead of crashing.
-- ============================================================================

---@class TooltipLibFilters
---@field weapon fun(item: InventoryItem): boolean Any HandWeapon (melee or ranged)
---@field melee fun(item: InventoryItem): boolean Melee weapons only
---@field firearm fun(item: InventoryItem): boolean Ranged weapons only (firearms, bows)
---@field clothing fun(item: InventoryItem): boolean Clothing and armor
---@field food fun(item: InventoryItem): boolean Food items
---@field container fun(item: InventoryItem): boolean Bags, backpacks, containers
---@field fluidContainer fun(item: InventoryItem): boolean Water bottles, gas cans
---@field drainable fun(item: InventoryItem): boolean Batteries, lighters, fuel cans
---@field literature fun(item: InventoryItem): boolean Books, magazines
---@field key fun(item: InventoryItem): boolean Keys (house, car, padlock)
---@field stackable fun(item: InventoryItem): boolean Items that can stack (ammo, nails)
---@field medical fun(item: InventoryItem): boolean Medical items (bandages, pills)
---@field customType fun(typeName: string): fun(item: InventoryItem): boolean Factory: filter by script type
---@field generator fun(object: IsoObject): boolean World object: generators
---@field rainCollector fun(object: IsoObject): boolean World object: rain collectors
---@field farmPlant fun(object: IsoObject): boolean World object: farm plants
---@field objectSprite fun(spriteName: string): fun(object: IsoObject): boolean Factory: filter by sprite name
---@field inRange fun(maxTiles: number): fun(subject: InventoryItem|IsoObject): boolean Factory: within maxTiles of player (Chebyshev distance, same floor)

TooltipLib.Filters = {}

-- Factory: wraps a filter function in pcall + log-once protection.
-- Safe to call anywhere (inside Hook.lua, or directly by mod code).
local filterWarned = {}

---@param name string Filter name for warning messages
---@param fn fun(subject: any, ...): boolean Raw filter function
---@return fun(subject: any, ...): boolean Hardened filter function
local function safeFilter(name, fn)
    return function(item, ...)
        if not item then return false end
        local ok, result = pcall(fn, item, ...)
        if not ok then
            if not filterWarned[name] then
                filterWarned[name] = true
                TooltipLib._log("WARN: Filter '" .. name ..
                    "' failed — PZ API may have changed. Filter will return false.")
            end
            return false
        end
        return result == true
    end
end

--- Any HandWeapon (melee or ranged).
TooltipLib.Filters.weapon = safeFilter("weapon", function(item)
    return item:IsWeapon()
end)

--- Melee weapons only (HandWeapon, not ranged).
TooltipLib.Filters.melee = safeFilter("melee", function(item)
    return item:IsWeapon() and not item:isRanged()
end)

--- Ranged weapons only (firearms, bows).
TooltipLib.Filters.firearm = safeFilter("firearm", function(item)
    return item:IsWeapon() and item:isRanged()
end)

--- Clothing and armor.
TooltipLib.Filters.clothing = safeFilter("clothing", function(item)
    return item:IsClothing()
end)

--- Food items (actual Food Java class instances).
--- NOTE: IsFood() is too broad — can match non-Food items.
--- This filter uses instanceof to ensure Food-specific methods are available.
TooltipLib.Filters.food = safeFilter("food", function(item)
    return instanceof(item, "Food")
end)

--- Bags, backpacks, containers with inventory.
TooltipLib.Filters.container = safeFilter("container", function(item)
    return item:IsInventoryContainer()
end)

--- Fluid containers (water bottles, gas cans, bleach).
TooltipLib.Filters.fluidContainer = safeFilter("fluidContainer", function(item)
    return instanceof(item, "FluidContainer")
end)

--- Drainable items (batteries, lighters, fuel cans).
TooltipLib.Filters.drainable = safeFilter("drainable", function(item)
    return item:IsDrainable()
end)

--- Books, magazines, and other literature (actual Literature Java class instances).
--- NOTE: IsLiterature() is too broad — matches ID cards and other non-Literature items.
--- This filter uses instanceof to ensure Literature-specific methods are available.
TooltipLib.Filters.literature = safeFilter("literature", function(item)
    return instanceof(item, "Literature")
end)

--- Skill books only — XP multiplier books that train a perk (not magazines, novels, ID cards).
--- Checks Literature class + LvlSkillTrained sentinel (vanilla uses -1 for non-skill lit).
TooltipLib.Filters.skillBook = safeFilter("skillBook", function(item)
    return instanceof(item, "Literature") and item:getLvlSkillTrained() ~= -1
end)

--- Recipe books — literature that teaches crafting/building recipes.
--- Checks Literature class + getLearnedRecipes() is non-empty.
TooltipLib.Filters.recipeBook = safeFilter("recipeBook", function(item)
    if not instanceof(item, "Literature") then return false end
    local recipes = item:getLearnedRecipes()
    return recipes ~= nil and recipes:size() > 0
end)

--- Key items (house keys, car keys, padlock keys).
TooltipLib.Filters.key = safeFilter("key", function(item)
    return instanceof(item, "Key")
end)

--- Stackable items (ammunition, nails, etc.).
TooltipLib.Filters.stackable = safeFilter("stackable", function(item)
    return item.canStack == true
end)

--- Medical items (bandages, first aid kits, pills).
--- Uses DisplayCategory from item scripts: "FirstAid" or "FirstAidWeapon" (splints).
TooltipLib.Filters.medical = safeFilter("medical", function(item)
    local cat = item:getDisplayCategory()
    return cat == "FirstAid" or cat == "FirstAidWeapon"
end)

--- Create a filter for a specific script item type.
--- Usage: enabled = TooltipLib.Filters.customType("Base.Axe")
---@param typeName string Full type (e.g., "Base.Axe") or short type (e.g., "Axe")
---@return fun(item: InventoryItem): boolean
function TooltipLib.Filters.customType(typeName)
    return safeFilter("customType:" .. typeName, function(item)
        return item:getFullType() == typeName or item:getType() == typeName
    end)
end

-- ============================================================================
-- Generic filter factories
-- ============================================================================
-- Flexible factories for filtering by Java class, item tag, or display category.
-- ============================================================================

--- Create a filter that checks Java class via instanceof.
--- Works for both item and object targets (any Java object PZ exposes to Lua).
--- Usage: enabled = TooltipLib.Filters.instanceof("Literature")
---@param className string Java class name (e.g., "Literature", "DrainableComboItem", "IsoGenerator")
---@return fun(item): boolean
function TooltipLib.Filters.instanceof(className)
    return safeFilter("instanceof:" .. className, function(item)
        return instanceof(item, className)
    end)
end

--- Create a filter that checks item script tags via ItemTag.
--- Tag names match the ItemTag static fields (e.g., "COOKABLE", "SAW", "CRUDE").
--- Usage: enabled = TooltipLib.Filters.hasTag("COOKABLE")
---@param tagName string ItemTag field name (e.g., "COOKABLE", "IS_FIRE_FUEL", "HEAVY_ITEM")
---@return fun(item: InventoryItem): boolean
function TooltipLib.Filters.hasTag(tagName)
    return safeFilter("hasTag:" .. tagName, function(item)
        local tag = ItemTag[tagName]
        return tag ~= nil and item:hasTag(tag)
    end)
end

--- Create a filter that checks item DisplayCategory from script definitions.
--- Category strings: "SkillBook", "Weapon", "FirstAid", "Cooking", "Tool",
--- "Gardening", "Material", "Fishing", "Camping", "Memento", etc.
--- Usage: enabled = TooltipLib.Filters.displayCategory("SkillBook")
---@param category string DisplayCategory value from item script
---@return fun(item: InventoryItem): boolean
function TooltipLib.Filters.displayCategory(category)
    return safeFilter("displayCategory:" .. category, function(item)
        return item:getDisplayCategory() == category
    end)
end

-- ============================================================================
-- World object filters (target = "object")
-- ============================================================================
-- These filters receive an IsoObject (not InventoryItem). Use with
-- target = "object" providers. The safeFilter wrapper works the same way.
-- ============================================================================

--- World object: generators (IsoGenerator).
---@param object IsoObject
---@return boolean
TooltipLib.Filters.generator = safeFilter("generator", function(object)
    return instanceof(object, "IsoGenerator")
end)

--- World object: rain collectors (IsoThumpable with CustomName in B42).
---@param object IsoObject
---@return boolean
TooltipLib.Filters.rainCollector = safeFilter("rainCollector", function(object)
    if not instanceof(object, "IsoThumpable") then return false end
    local props = object:getProperties()
    return props and props:get("CustomName") == "Rain Collector Barrel"
end)

--- World object: farm plants (B42 GlobalObjectSystem, no Java IsoPlant class).
--- Detected via farming-specific modData fields set by SFarmingSystem.
--- Also checks the square (arg2) because vanilla's farming tooltip is
--- square-based — it fires for ANY specialTooltip object on the tile.
--- Without the square check, replacesVanilla providers can't suppress vanilla
--- when the player hovers a non-plant object on the same square.
---@param object IsoObject
---@param square IsoGridSquare|nil Optional square (passed by object surface enabled())
---@return boolean
TooltipLib.Filters.farmPlant = safeFilter("farmPlant", function(object, square)
    local modData = object:getModData()
    if modData and modData.typeOfSeed ~= nil and modData.nbOfGrow ~= nil then
        return true
    end
    if not square then return false end
    local objects = square:getObjects()
    if not objects then return false end
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj and obj ~= object then
            local md = obj:getModData()
            if md and md.typeOfSeed ~= nil and md.nbOfGrow ~= nil then
                return true
            end
        end
    end
    return false
end)

--- Create a filter for a specific world object sprite name.
--- Usage: enabled = TooltipLib.Filters.objectSprite("appliances_cooking_01_0")
---@param spriteName string Sprite name to match
---@return fun(object: IsoObject): boolean
function TooltipLib.Filters.objectSprite(spriteName)
    return safeFilter("objectSprite:" .. spriteName, function(object)
        local sprite = object:getSprite()
        return sprite ~= nil and sprite:getName() == spriteName
    end)
end

-- ============================================================================
-- Range filters
-- ============================================================================
-- Distance-based filters for controlling tooltip visibility by proximity.
-- Works for both item and object targets. Uses Chebyshev (max) distance in
-- tiles, same-floor only. Items in the player's own inventory always pass.
-- ============================================================================

--- Create a range filter that checks if the subject is within maxTiles of the player.
--- Works for both item and object targets:
---   - Items: checks distance to the container's parent object (always passes for player inventory)
---   - Objects: checks distance directly to the object
--- Uses Chebyshev distance (max of |dx|, |dy|) — same metric PZ uses for interaction range.
--- Different floors always return false. Returns true if position cannot be determined.
---
--- Usage:
---   enabled = TooltipLib.Filters.inRange(3)
---   enabled = TooltipLib.Filters.allOf(TooltipLib.Filters.container, TooltipLib.Filters.inRange(3))
---@param maxTiles number Maximum tile distance (Chebyshev)
---@return fun(subject: InventoryItem|IsoObject): boolean
function TooltipLib.Filters.inRange(maxTiles)
    return safeFilter("inRange:" .. tostring(maxTiles), function(subject)
        local player = getPlayer()
        if not player then return false end

        -- Determine world position to measure from
        local wx, wy, wz
        if instanceof(subject, "InventoryItem") then
            local container = subject:getContainer()
            if not container then return true end
            local parent = container:getParent()
            if not parent then return true end
            if parent == player then return true end -- player's own inventory
            wx, wy, wz = parent:getX(), parent:getY(), parent:getZ()
        else
            wx, wy, wz = subject:getX(), subject:getY(), subject:getZ()
        end

        if not wx or not wy or not wz then return true end

        local px, py, pz = player:getX(), player:getY(), player:getZ()
        if math.floor(pz) ~= math.floor(wz) then return false end
        local dx = math.abs(px - wx)
        local dy = math.abs(py - wy)
        return math.max(dx, dy) <= maxTiles
    end)
end

-- ============================================================================
-- Combinators
-- ============================================================================

--- Combine filters with AND logic. All must return true.
--- Extra arguments (e.g., square for object filters) are forwarded.
---@param ... fun(subject: any, ...): boolean One or more filter functions
---@return fun(subject: any, ...): boolean
function TooltipLib.Filters.allOf(...)
    local filters = { ... }
    local n = #filters
    return function(subject, ...)
        for i = 1, n do
            if not filters[i](subject, ...) then return false end
        end
        return true
    end
end

--- Combine filters with OR logic. Any returning true is sufficient.
--- Extra arguments (e.g., square for object filters) are forwarded.
---@param ... fun(subject: any, ...): boolean One or more filter functions
---@return fun(subject: any, ...): boolean
function TooltipLib.Filters.anyOf(...)
    local filters = { ... }
    local n = #filters
    return function(subject, ...)
        for i = 1, n do
            if filters[i](subject, ...) then return true end
        end
        return false
    end
end

--- Negate a filter.
--- Extra arguments (e.g., square for object filters) are forwarded.
---@param filter fun(subject: any, ...): boolean
---@return fun(subject: any, ...): boolean
function TooltipLib.Filters.negate(filter)
    return function(subject, ...)
        return not filter(subject, ...)
    end
end

TooltipLib._log("Filters loaded")
