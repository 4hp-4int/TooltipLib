-- ============================================================================
-- TooltipLib Core — Shared tooltip provider registry
-- ============================================================================
-- Sets up the TooltipLib global and registration API.
-- Lives in shared/ so both client and server contexts can register providers
-- (registration is just data; the actual hook is in client/Hook.lua).
--
-- VERSIONING CONTRACT (Semantic Versioning):
--   MAJOR (2.0.0): May remove or rename public API. Providers may need updates.
--   MINOR (1.1.0): Additive only. New methods, filters, fields, options.
--                   Existing provider code continues to work unchanged.
--   PATCH (1.0.1): Bug fixes only. No API surface changes.
--
-- PUBLIC API SURFACE (guaranteed stable within a major version):
--   Registration: registerProvider, removeProvider, replaceProvider, hasProvider, getProviderCount
--   Recovery:     resetProvider
--   Config:       setProviderEnabled, isProviderEnabled
--   Introspection: getProviders, getHookStatus
--   Cache:        invalidateCache, invalidateActiveProviders
--   Version:      checkVersion, VERSION, VERSION_NUM
--   Debug:        debug (boolean flag)
--   Constants:    Priorities (FIRST, EARLY, DEFAULT, LATE, LAST)
--   Filters:      Filters.* (weapon, melee, firearm, clothing, food,
--                  container, fluidContainer, drainable, literature,
--                  key, stackable, medical, skillBook, recipeBook,
--                  generator, rainCollector, farmPlant)
--   Filter factory: Filters.customType(typeName), Filters.instanceof(className),
--                   Filters.hasTag(tagName), Filters.displayCategory(category),
--                   Filters.objectSprite(spriteName),
--                   Filters.inRange(maxTiles)
--   Combinators:  Filters.allOf, Filters.anyOf, Filters.negate
--   Colors:       Colors.* (WHITE, GRAY, DARK_GRAY, GREEN, RED, BLUE,
--                  YELLOW, GOLD, ORANGE, PURPLE, HEADER, PROGRESS)
--   Context (all surfaces): ctx:addLabel, ctx:addKeyValue, ctx:addProgress,
--                  ctx:addInteger, ctx:addSpacer, ctx:addHeader, ctx:addDivider,
--                  ctx:addText, ctx:addFloat, ctx:addPercentage
--   Context (layout only): ctx:addTexture, ctx:addTextureRow
--   Context (object only): ctx:readObject, ctx:safeCall, ctx:readContainers, ctx:readLocked
--   Context (rich text only): ctx:appendLine, ctx:appendKeyValue,
--                  ctx:appendRichText, ctx:setName
--   Context fields: ctx.item, ctx.tooltip, ctx.layout, ctx.helpers, ctx.detail,
--                   ctx.surface, ctx.object, ctx.square, ctx.perk, ctx.level,
--                   ctx.player, ctx.part, ctx.vehicle, ctx.recipe, ctx.logic,
--                   ctx.rootTable
--   Provider options: id, target, priority, callback, enabled, preTooltip,
--                     postRender, cleanup, cacheable, cacheKey, maxAge,
--                     minVersion, separator, detailOnly, description,
--                     minWidth, replacesVanilla,
--                     mpFields, mpContainers, mpModData, mpLocked, mpSquareScan
--   MP:           allowMPMethod
--
-- INTERNAL API (may change without notice, prefixed with _):
--   _providers, _providersByTarget, _providerVersion,
--   _providerOverrides, _callbackCache, _errorCounts, _hookStatus,
--   _recordError, _recordSuccess, _isDisabled,
--   _getProvidersForTarget, _refreshProviderOptions,
--   _readDetailKey, _evaluateProviders, _resetTable,
--   _ContextMT, _RichTextContextMT, _RecipeContextMT, _RecipeContentPanel,
--   _createRecordingContext, _replayDisplayList,
--   _createRecordingRichTextContext, _replayRichTextDisplayList,
--   _getDetailKeyCode, _log, _logOnce, _debugLog, _warn,
--   _mpAllowedMethods, _isMPMethodAllowed,
--   _mpGetCached, _mpRequest, _mpAggregate (set by MPClient.lua)
-- ============================================================================

local CURRENT_VERSION = "1.1.0"
local CURRENT_VERSION_NUM = 2

-- Version guard: if a newer version is already loaded, do not replace it
if TooltipLib and TooltipLib.VERSION_NUM
   and TooltipLib.VERSION_NUM >= CURRENT_VERSION_NUM then
    return
end

---@class TooltipLib
---@field VERSION string Semver version string (e.g., "1.0.0")
---@field VERSION_NUM number Integer version for load guard comparison
---@field Priorities TooltipLibPriorities Priority constants for provider ordering
---@field Colors TooltipLibColors Color palette (frozen — read-only)
---@field Filters TooltipLibFilters Pre-built item type filters
---@field Helpers TooltipLibHelpers Static layout helper functions
---@field debug boolean Enable verbose debug logging (default false)
TooltipLib = TooltipLib or {}
TooltipLib.VERSION = CURRENT_VERSION
TooltipLib.VERSION_NUM = CURRENT_VERSION_NUM

-- ============================================================================
-- Debug mode
-- ============================================================================

--- Set to true to enable verbose logging (cache hits/misses, L1 refreshes, maxAge expirations).
--- Zero overhead when false (early return in _debugLog).
TooltipLib.debug = false

-- ============================================================================
-- Priority constants
-- ============================================================================

---@class TooltipLibPriorities
---@field FIRST number 10 — earliest
---@field EARLY number 25
---@field DEFAULT number 100 — auto-assigned default
---@field LATE number 200
---@field LAST number 500 — latest
TooltipLib.Priorities = {
    FIRST   = 10,
    EARLY   = 25,
    DEFAULT = 100,
    LATE    = 200,
    LAST    = 500,
}

-- ============================================================================
-- Valid targets
-- ============================================================================

local VALID_TARGETS = {
    item = true,
    itemSlot = true,
    object = true,
    skill = true,
    vehicle = true,
    recipe = true,
}

-- ============================================================================
-- Internal state
-- ============================================================================

TooltipLib._providers = TooltipLib._providers or {}           -- id -> provider table
TooltipLib._providersByTarget = TooltipLib._providersByTarget or {}   -- target -> sorted provider array, rebuilt on registration change
TooltipLib._nextPriority = TooltipLib._nextPriority or 101      -- auto-increment counter: starts above DEFAULT (100), increments by 1
TooltipLib._providerVersion = TooltipLib._providerVersion or 0     -- incremented on register/remove, used by Hook.lua cache
TooltipLib._providerOverrides = TooltipLib._providerOverrides or {}  -- id -> boolean (false = user-disabled via setProviderEnabled)
TooltipLib._callbackCache = TooltipLib._callbackCache or {}      -- providerId -> { itemId, cacheKey, displayList, frameRecorded }
TooltipLib._errorCounts = TooltipLib._errorCounts or {}        -- providerId -> { consecutive, disabled }
TooltipLib._hookStatus = TooltipLib._hookStatus or {}            -- surface -> true (success) | string (failure reason)

-- ============================================================================
-- MP method whitelist (shared between Core registration and MPServer)
-- ============================================================================
-- Methods the server is allowed to call when a client requests object data.
-- Populated automatically from provider mpFields at registration time.
-- Third-party mods can add their own via allowMPMethod().

TooltipLib._mpAllowedMethods = TooltipLib._mpAllowedMethods or {}

--- Whitelist a Java method name for MP object data reads.
--- The server will only call methods that pass the whitelist check.
--- Methods starting with "get", "is", "has", "check" are allowed by default.
--- Use this for non-standard getter names (e.g., "Activated").
---@param methodName string The Java method name to whitelist
function TooltipLib.allowMPMethod(methodName)
    if type(methodName) == "string" and methodName ~= "" then
        TooltipLib._mpAllowedMethods[methodName] = true
    end
end

--- Check if a method name is allowed for MP reads.
--- Allows: any method in the explicit whitelist, or methods starting with
--- "get", "is", "has", "check" (standard Java getter prefixes).
---@param methodName string
---@return boolean
function TooltipLib._isMPMethodAllowed(methodName)
    if TooltipLib._mpAllowedMethods[methodName] then return true end
    local prefix = methodName:sub(1, 3)
    if prefix == "get" or prefix == "has" then return true end
    local prefix2 = methodName:sub(1, 2)
    if prefix2 == "is" then return true end
    local prefix5 = methodName:sub(1, 5)
    if prefix5 == "check" then return true end
    return false
end

-- ============================================================================
-- Error circuit breaker
-- ============================================================================
-- Tracks consecutive errors per provider. After ERROR_THRESHOLD consecutive
-- errors, the provider is auto-disabled for the session. Call resetProvider()
-- to re-enable.

local ERROR_THRESHOLD = 10

--- Record an error for a provider. Auto-disables after ERROR_THRESHOLD consecutive errors.
---@param providerId string
function TooltipLib._recordError(providerId)
    local ec = TooltipLib._errorCounts[providerId]
    if not ec then
        ec = { consecutive = 0, disabled = false }
        TooltipLib._errorCounts[providerId] = ec
    end
    if ec.disabled then return end
    ec.consecutive = ec.consecutive + 1
    if ec.consecutive >= ERROR_THRESHOLD then
        ec.disabled = true
        TooltipLib._log("Provider '" .. providerId .. "' disabled after " ..
            ERROR_THRESHOLD .. " consecutive errors. " ..
            "Call TooltipLib.resetProvider('" .. providerId .. "') to re-enable.")
    end
end

--- Record a success for a provider, resetting its consecutive error count.
---@param providerId string
function TooltipLib._recordSuccess(providerId)
    local ec = TooltipLib._errorCounts[providerId]
    if ec and ec.consecutive > 0 then
        ec.consecutive = 0
    end
end

--- Check if a provider is disabled (by user override or circuit breaker).
---@param providerId string
---@return boolean
function TooltipLib._isDisabled(providerId)
    -- User override (setProviderEnabled) takes precedence
    if TooltipLib._providerOverrides[providerId] == false then
        return true
    end
    -- Circuit breaker (auto-disable after consecutive errors)
    local ec = TooltipLib._errorCounts[providerId]
    return ec ~= nil and ec.disabled
end

--- Priority comparator for sorting providers.
local function prioritySort(a, b)
    if a.priority == b.priority then
        return a.id < b.id -- stable sort by ID for same priority
    end
    return a.priority < b.priority
end

--- Rebuild per-target sorted provider lists. Called after register/remove.
local function rebuildSorted()
    local byTarget = {}
    for _, provider in pairs(TooltipLib._providers) do
        local t = provider.target
        if not byTarget[t] then byTarget[t] = {} end
        byTarget[t][#byTarget[t] + 1] = provider
    end
    for _, list in pairs(byTarget) do
        table.sort(list, prioritySort)
    end
    TooltipLib._providersByTarget = byTarget
    TooltipLib._providerVersion = (TooltipLib._providerVersion or 0) + 1
end

-- ============================================================================
-- Version utilities (must be defined before registerProvider uses them)
-- ============================================================================

---@param str string Semver string like "1.2.3"
---@return number? major, number? minor, number? patch
local function parseVersion(str)
    if type(str) ~= "string" then return nil end
    local major, minor, patch = str:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then return nil end
    return tonumber(major), tonumber(minor), tonumber(patch)
end

---@param current string Installed version
---@param required string Required minimum version
---@return boolean
local function isVersionAtLeast(current, required)
    local cMaj, cMin, cPat = parseVersion(current)
    local rMaj, rMin, rPat = parseVersion(required)
    if not cMaj or not rMaj then return false end
    if cMaj ~= rMaj then return cMaj > rMaj end
    if cMin ~= rMin then return cMin > rMin end
    return cPat >= rPat
end

--- Check if installed TooltipLib meets a minimum version requirement.
---@param required string Semver string like "1.0.0"
---@return boolean satisfied
---@return string installedVersion
function TooltipLib.checkVersion(required)
    return isVersionAtLeast(TooltipLib.VERSION, required), TooltipLib.VERSION
end

-- ============================================================================
-- Public API
-- ============================================================================

---@class TooltipLibProviderOptions
---@field id string Unique provider identifier (namespace to your mod)
---@field callback fun(ctx: TooltipLibContext|TooltipLibRichTextContext|TooltipLibRecipeContext) Main content callback
---@field target? string Surface target: "item"|"itemSlot"|"object"|"skill"|"vehicle"|"recipe" (default "item")
---@field enabled? fun(...): boolean Filter function — args vary by target surface
---@field priority? number Lower = earlier in tooltip (default: auto-assigned)
---@field description? string Human-readable name, shown as toggle in Mod Options
---@field preTooltip? fun(ctx: table) Runs before vanilla tooltip renders
---@field postRender? fun(ctx: table) Direct drawing after layout (Layout surfaces only)
---@field cleanup? fun(ctx: table) Always runs, even on error — undo preTooltip here
---@field cacheable? boolean Replay callback from display list cache (item/itemSlot only)
---@field cacheKey? fun(item: InventoryItem): string|number|boolean|nil Extra cache invalidation signal
---@field maxAge? number Frames before cache auto-refreshes (default 60, 0 = infinite)
---@field minVersion? string Reject registration if TooltipLib version is too old
---@field separator? boolean Auto-spacer between this and previous provider (default true)
---@field detailOnly? boolean Only show when detail key is held (default false)
---@field minWidth? number Minimum tooltip width in pixels (default 150)
---@field replacesVanilla? boolean Draw opaque bg to cover vanilla content (object surface only, default false)
---@field mpFields? string[] Java method names to call on server for MP data (object surface)
---@field mpContainers? boolean Request container metadata from server (object surface)
---@field mpModData? string[] ModData field names to read from server (object surface)
---@field mpLocked? boolean Request isLocked check from server (object surface)
---@field mpSquareScan? boolean Scan all objects on square for modData if not found on target (object surface)

--- Register a tooltip content provider.
---@param options TooltipLibProviderOptions
---@return boolean success
function TooltipLib.registerProvider(options)
    if type(options) ~= "table" then
        TooltipLib._log("registerProvider: options must be a table")
        return false
    end
    if type(options.id) ~= "string" or options.id == "" then
        TooltipLib._log("registerProvider: id must be a non-empty string")
        return false
    end
    if options.minVersion ~= nil then
        if type(options.minVersion) ~= "string" then
            TooltipLib._log("registerProvider: '" .. tostring(options.id) ..
                "' minVersion must be a semver string")
            return false
        end
        if not isVersionAtLeast(TooltipLib.VERSION, options.minVersion) then
            TooltipLib._log("Provider '" .. options.id .. "' requires TooltipLib >= " ..
                options.minVersion .. " (installed: " .. TooltipLib.VERSION ..
                "). Provider not registered.")
            return false
        end
    end
    if type(options.callback) ~= "function" then
        TooltipLib._log("registerProvider: callback must be a function")
        return false
    end
    if options.enabled and type(options.enabled) ~= "function" then
        TooltipLib._log("registerProvider: enabled must be a function or nil")
        return false
    end
    if options.preTooltip and type(options.preTooltip) ~= "function" then
        TooltipLib._log("registerProvider: preTooltip must be a function or nil")
        return false
    end
    if options.postRender and type(options.postRender) ~= "function" then
        TooltipLib._log("registerProvider: postRender must be a function or nil")
        return false
    end
    if options.cleanup and type(options.cleanup) ~= "function" then
        TooltipLib._log("registerProvider: cleanup must be a function or nil")
        return false
    end
    if options.cacheable ~= nil and type(options.cacheable) ~= "boolean" then
        TooltipLib._log("registerProvider: cacheable must be a boolean or nil")
        return false
    end
    if options.cacheKey and type(options.cacheKey) ~= "function" then
        TooltipLib._log("registerProvider: cacheKey must be a function or nil")
        return false
    end
    if options.cacheKey and not options.cacheable then
        TooltipLib._log("registerProvider: cacheKey requires cacheable=true")
        return false
    end
    if options.maxAge ~= nil then
        if not options.cacheable then
            TooltipLib._log("registerProvider: maxAge requires cacheable=true")
            return false
        end
        if type(options.maxAge) ~= "number" or options.maxAge < 0 then
            TooltipLib._log("registerProvider: maxAge must be a non-negative number")
            return false
        end
    end
    if options.cacheable and options.target == "recipe" then
        TooltipLib._log("registerProvider: cacheable=true is not supported for " ..
            "target='recipe' (ISPanel objects are stateful per-frame)")
        return false
    end
    if options.separator ~= nil and type(options.separator) ~= "boolean" then
        TooltipLib._log("registerProvider: separator must be a boolean or nil")
        return false
    end
    if options.detailOnly ~= nil and type(options.detailOnly) ~= "boolean" then
        TooltipLib._log("registerProvider: detailOnly must be a boolean or nil")
        return false
    end
    if options.description ~= nil and type(options.description) ~= "string" then
        TooltipLib._log("registerProvider: description must be a string or nil")
        return false
    end
    if options.minWidth ~= nil then
        if type(options.minWidth) ~= "number" or options.minWidth < 0 then
            TooltipLib._log("registerProvider: minWidth must be a non-negative number")
            return false
        end
    end
    if options.replacesVanilla ~= nil then
        if type(options.replacesVanilla) ~= "boolean" then
            TooltipLib._log("registerProvider: replacesVanilla must be a boolean or nil")
            return false
        end
        if options.target ~= nil and options.target ~= "object" then
            TooltipLib._log("registerProvider: replacesVanilla is only valid for target='object'")
            return false
        end
    end
    if options.target ~= nil and not VALID_TARGETS[options.target] then
        TooltipLib._log("registerProvider: invalid target '" .. tostring(options.target) ..
            "'. Valid targets: item, itemSlot, object, skill, vehicle, recipe")
        return false
    end
    -- MP field validation (object surface only)
    if options.mpFields ~= nil and type(options.mpFields) ~= "table" then
        TooltipLib._log("registerProvider: mpFields must be a table (array of method name strings)")
        return false
    end
    if options.mpContainers ~= nil and type(options.mpContainers) ~= "boolean" then
        TooltipLib._log("registerProvider: mpContainers must be a boolean")
        return false
    end
    if options.mpModData ~= nil and type(options.mpModData) ~= "table" then
        TooltipLib._log("registerProvider: mpModData must be a table (array of modData key strings)")
        return false
    end
    if options.mpLocked ~= nil and type(options.mpLocked) ~= "boolean" then
        TooltipLib._log("registerProvider: mpLocked must be a boolean")
        return false
    end
    if options.mpSquareScan ~= nil and type(options.mpSquareScan) ~= "boolean" then
        TooltipLib._log("registerProvider: mpSquareScan must be a boolean")
        return false
    end

    -- Debug warning: provider without enabled() filter runs for ALL items
    if TooltipLib.debug and not options.enabled then
        TooltipLib._debugLog("Provider '" .. options.id ..
            "' has no enabled() filter — runs for ALL items")
    end

    if TooltipLib._providers[options.id] then
        TooltipLib._log("registerProvider: replacing existing provider '" .. options.id .. "'")
        -- Clear stale L2 cache and circuit breaker state from the old callback
        TooltipLib._callbackCache[options.id] = nil
        TooltipLib._errorCounts[options.id] = nil
    end

    -- Auto-assign priority if not specified: each omission gets a unique
    -- incrementing value so registration order determines render order.
    local priority
    if type(options.priority) == "number" then
        priority = options.priority
    else
        priority = TooltipLib._nextPriority
        TooltipLib._nextPriority = TooltipLib._nextPriority + 1
    end

    -- maxAge: default 60 frames (~1s at 60fps) when cacheable, 0 = infinite
    local maxAge = nil
    if options.cacheable then
        if options.maxAge ~= nil then
            maxAge = options.maxAge
        else
            maxAge = 60 -- default safety net
        end
        if maxAge == 0 then maxAge = nil end -- 0 means infinite (no auto-refresh)
    end

    -- Auto-whitelist mpFields method names for server-side calls
    if options.mpFields then
        for i = 1, #options.mpFields do
            TooltipLib._mpAllowedMethods[options.mpFields[i]] = true
        end
    end

    TooltipLib._providers[options.id] = {
        id          = options.id,
        target      = options.target or "item",
        priority    = priority,
        callback    = options.callback,
        enabled     = options.enabled,
        preTooltip  = options.preTooltip,
        postRender  = options.postRender,
        cleanup     = options.cleanup,
        cacheable   = options.cacheable or false,
        cacheKey    = options.cacheKey,
        maxAge      = maxAge,
        separator   = (options.separator == nil) and true or options.separator,
        detailOnly  = options.detailOnly or false,
        description     = options.description,
        minWidth        = options.minWidth,
        replacesVanilla = options.replacesVanilla or false,
        -- MP sync fields (object surface)
        mpFields      = options.mpFields,
        mpContainers  = options.mpContainers or false,
        mpModData     = options.mpModData,
        mpLocked      = options.mpLocked or false,
        mpSquareScan  = options.mpSquareScan or false,
    }

    local provider = TooltipLib._providers[options.id]
    rebuildSorted()
    TooltipLib._log("Provider '" .. options.id .. "' registered (target=" .. provider.target ..
        ", priority=" .. tostring(provider.priority) ..
        ", " .. TooltipLib.getProviderCount() .. " total)")

    -- Notify Options.lua hook (if loaded) so it can create a tick box immediately
    if TooltipLib._onProviderRegistered then
        pcall(TooltipLib._onProviderRegistered, provider)
    end

    return true
end

--- Remove a registered provider.
---@param id string The provider ID
---@return boolean removed
function TooltipLib.removeProvider(id)
    if not TooltipLib._providers[id] then
        return false
    end
    TooltipLib._providers[id] = nil
    TooltipLib._callbackCache[id] = nil
    TooltipLib._errorCounts[id] = nil
    TooltipLib._providerOverrides[id] = nil
    rebuildSorted()
    TooltipLib._log("Provider '" .. id .. "' removed (" ..
        TooltipLib.getProviderCount() .. " remaining)")
    return true
end

--- Atomically replace an existing provider with new options.
--- Shorthand for removeProvider + registerProvider. Useful for mod overrides
--- where another mod wants to replace a provider's behavior entirely.
--- The new options must include the same id as the provider being replaced.
---@param id string The provider ID to replace
---@param newOptions TooltipLibProviderOptions New provider options (must have same id)
---@return boolean success
function TooltipLib.replaceProvider(id, newOptions)
    if type(id) ~= "string" or id == "" then
        TooltipLib._log("replaceProvider: id must be a non-empty string")
        return false
    end
    if type(newOptions) ~= "table" then
        TooltipLib._log("replaceProvider: newOptions must be a table")
        return false
    end
    if newOptions.id ~= id then
        TooltipLib._log("replaceProvider: newOptions.id must match id '" .. id .. "'")
        return false
    end
    if not TooltipLib._providers[id] then
        TooltipLib._log("replaceProvider: no existing provider '" .. id .. "' to replace")
        return false
    end
    TooltipLib.removeProvider(id)
    return TooltipLib.registerProvider(newOptions)
end

--- Re-enable a provider disabled by the error circuit breaker or user override.
--- Resets error count, clears user override, clears caches, and forces
--- L1 re-evaluation.
---@param id string The provider ID
---@return boolean success
function TooltipLib.resetProvider(id)
    if not TooltipLib._providers[id] then
        TooltipLib._log("resetProvider: no provider '" .. tostring(id) .. "'")
        return false
    end
    local ec = TooltipLib._errorCounts[id]
    if ec then
        ec.consecutive = 0
        ec.disabled = false
    end
    TooltipLib._providerOverrides[id] = nil
    TooltipLib._callbackCache[id] = nil
    TooltipLib._providerVersion = (TooltipLib._providerVersion or 0) + 1
    TooltipLib._log("Provider '" .. id .. "' reset and re-enabled")
    return true
end

--- Check if a provider is registered.
---@param id string
---@return boolean
function TooltipLib.hasProvider(id)
    return TooltipLib._providers[id] ~= nil
end

--- Disable or re-enable a provider by user preference.
--- Unlike the circuit breaker (auto-disable on errors), this is an explicit
--- user choice that persists via Mod Options.
--- Pass true to enable (clears override), false to disable.
---@param id string Provider ID
---@param enabled boolean true = enabled (default), false = disabled
---@return boolean success
function TooltipLib.setProviderEnabled(id, enabled)
    if type(id) ~= "string" or id == "" then
        TooltipLib._log("setProviderEnabled: id must be a non-empty string")
        return false
    end
    if enabled == false then
        TooltipLib._providerOverrides[id] = false
    else
        TooltipLib._providerOverrides[id] = nil -- nil = default (no override)
    end
    TooltipLib._providerVersion = (TooltipLib._providerVersion or 0) + 1
    TooltipLib._debugLog("Provider '" .. id .. "' " ..
        (enabled == false and "disabled" or "enabled") .. " by user")
    return true
end

--- Query user override state for a provider.
---@param id string Provider ID
---@return boolean|nil nil = no override (default), false = disabled by user
function TooltipLib.isProviderEnabled(id)
    return TooltipLib._providerOverrides[id]
end

--- Get count of registered providers.
--- When target is specified, returns count for that target only.
---@param target string|nil Optional target filter
---@return number
function TooltipLib.getProviderCount(target)
    if target then
        local list = TooltipLib._providersByTarget[target]
        return list and #list or 0
    end
    -- Total across all targets
    local count = 0
    for _, list in pairs(TooltipLib._providersByTarget) do
        count = count + #list
    end
    return count
end

--- Get a list of registered providers with metadata, in execution order.
--- When target is specified, returns only providers for that target.
--- When omitted, returns all providers sorted by priority.
---@param target string|nil Optional target filter (e.g., "item", "object", "skill")
---@return table[] Array of provider info tables
function TooltipLib.getProviders(target)
    local source
    if target then
        source = TooltipLib._providersByTarget[target] or {}
    else
        -- All providers across all targets, sorted by priority
        source = {}
        for _, list in pairs(TooltipLib._providersByTarget) do
            for i = 1, #list do
                source[#source + 1] = list[i]
            end
        end
        table.sort(source, prioritySort)
    end

    local result = {}
    for i = 1, #source do
        local p = source[i]
        local ec = TooltipLib._errorCounts[p.id]
        result[i] = {
            id = p.id,
            target = p.target,
            priority = p.priority,
            description = p.description,
            cacheable = p.cacheable,
            detailOnly = p.detailOnly,
            separator = p.separator,
            hasPreTooltip = p.preTooltip ~= nil,
            hasPostRender = p.postRender ~= nil,
            hasCleanup = p.cleanup ~= nil,
            errorCount = ec and ec.consecutive or 0,
            disabled = ec and ec.disabled or false,
            userDisabled = TooltipLib._providerOverrides[p.id] == false,
        }
    end
    return result
end

--- Get hook installation status for each surface.
--- Consumer mods can call this after OnGameStart to verify their surface hooks
--- are live. Returns a table where keys are surface names and values are true
--- (success) or a string describing the failure reason.
---@return table<string, boolean|string> status per surface
function TooltipLib.getHookStatus()
    local result = {}
    for k, v in pairs(TooltipLib._hookStatus) do
        result[k] = v
    end
    return result
end

--- Get the sorted provider list for a specific target. Internal use by hooks.
---@param target string Target name (e.g., "item", "object", "skill")
---@return table[] Sorted array of provider tables
function TooltipLib._getProvidersForTarget(target)
    return TooltipLib._providersByTarget[target] or {}
end

-- ============================================================================
-- Cache invalidation
-- ============================================================================

--- Invalidate cached callback display lists.
---@param providerId string|nil If given, clear only that provider's cache. If nil, clear all.
function TooltipLib.invalidateCache(providerId)
    if not TooltipLib._callbackCache then return end
    if providerId then
        TooltipLib._callbackCache[providerId] = nil
    else
        TooltipLib._callbackCache = {}
    end
end

--- Force re-evaluation of all enabled() filters on the next frame.
--- Use when external state changes that affect which providers should be active.
function TooltipLib.invalidateActiveProviders()
    TooltipLib._providerVersion = (TooltipLib._providerVersion or 0) + 1
end

-- ============================================================================
-- Logging
-- ============================================================================

function TooltipLib._log(msg)
    print("[TooltipLib] " .. tostring(msg))
end

--- Log a warning. Always prints, even when debug is false.
--- Use for non-fatal issues that operators should notice (e.g., hook install
--- failures, missing PZ APIs). Unlike _debugLog, this is never silent.
---@param msg string Warning message
function TooltipLib._warn(msg)
    print("[TooltipLib] [WARN] " .. tostring(msg))
end

local loggedMessages = {}

--- Log a message only once per key. Use for framework-level warnings
--- that would otherwise spam every frame (e.g., layout API errors).
---@param key string Unique key for deduplication
---@param msg string Message to log
function TooltipLib._logOnce(key, msg)
    if not loggedMessages[key] then
        loggedMessages[key] = true
        TooltipLib._log(msg)
    end
end

--- Log a debug message. Only outputs when TooltipLib.debug is true.
--- Zero overhead when disabled (early return before string concat).
---@param msg string Message to log
function TooltipLib._debugLog(msg)
    if not TooltipLib.debug then return end
    TooltipLib._log("[DEBUG] " .. tostring(msg))
end

-- ============================================================================
-- Shared hook helpers (used by all hook files to eliminate duplication)
-- ============================================================================

--- Clear all keys from a table (for pool reuse). Returns the same table.
---@param t table
---@return table
function TooltipLib._resetTable(t)
    for k in pairs(t) do
        t[k] = nil
    end
    return t
end

--- Inner function for _readDetailKey — hoisted to avoid closure allocation per frame.
local function _readDetailKeyInner()
    local keyCode = TooltipLib._getDetailKeyCode()
    if keyCode then
        return GameKeyboard.isKeyDown(keyCode)
    end
    return false
end

--- Read the current detail key state. Returns true if the detail modifier
--- key (default LShift) is currently held down.
--- Safe to call from any context — returns false if GameKeyboard unavailable.
---@return boolean
function TooltipLib._readDetailKey()
    if not TooltipLib._getDetailKeyCode then return false end
    local ok, result = pcall(_readDetailKeyInner)
    return ok and result == true
end

--- Evaluate which providers are active for a given context.
--- Checks _isDisabled, calls enabled() with the provided args, and filters
--- by detailOnly. Returns nil if no providers are active.
---@param providers table[] Sorted array of provider tables
---@param detailHeld boolean Whether the detail key is held
---@param arg1 any First argument to pass to enabled() (item, object, perk, part, recipe)
---@param arg2 any? Second argument to pass to enabled() (square, level, vehicle, nil)
---@return table[]|nil activeProviders or nil if none active
function TooltipLib._evaluateProviders(providers, detailHeld, arg1, arg2)
    local activeProviders = nil
    for i = 1, #providers do
        local p = providers[i]
        local active = true

        if TooltipLib._isDisabled(p.id) then
            active = false
        elseif p.enabled then
            local eOk, eResult = pcall(p.enabled, arg1, arg2)
            if not eOk then
                TooltipLib._log("Provider '" .. p.id ..
                    "' enabled() error: " .. tostring(eResult))
                TooltipLib._recordError(p.id)
                active = false
            else
                active = eResult == true
            end
        end

        if active and p.detailOnly and not detailHeld then
            active = false
        end

        if active then
            if not activeProviders then activeProviders = {} end
            activeProviders[#activeProviders + 1] = p
        end
    end
    return activeProviders
end

TooltipLib._log("Core loaded (v" .. TooltipLib.VERSION .. ")")
