-- ============================================================================
-- TooltipLib MPClient — Client-side MP networking and cache for object tooltips
-- ============================================================================
-- Manages the client side of the MP tooltip data flow:
--   1. Aggregates mpFields/mpContainers/mpModData from active providers
--   2. Sends data requests to the server via sendClientCommand
--   3. Receives responses via OnServerCommand and caches them
--   4. Provides cached data to HookWorldObject for injection into ctx._mpData
--
-- Only active when isClient() is true (MP client or listen server host).
-- In SP (isClient()=false), none of this code runs.
-- ============================================================================

if isServer() and not isClient() then return end

require "TooltipLib/Core"

local MODULE = "TooltipLib"

-- ============================================================================
-- Cache
-- ============================================================================
-- Keyed by "x:y:z:objectIndex". Values are { data = {...}, timestamp = ms }.

local CACHE_TTL_MS = 2000        -- Cache entries valid for 2 seconds
local REQUEST_COOLDOWN_MS = 1500 -- Minimum interval between requests for same key

-- Hover-dwell gate. OnPreUIDraw polls getLastPicked() EVERY FRAME, and the
-- cursor sweeps across dozens of distinct world objects a second while the
-- player walks. Every one is a fresh cache key, so REQUEST_COOLDOWN_MS (keyed
-- per object) never applies to them and each fires an immediate round trip.
--
-- Measured on the live dedicated server (2026-08-03, 4 players, ~100 min,
-- 41,714 readObject commands): 63% of requests arrived within 250ms of the
-- previous one -- objects the cursor merely passed over and never settled on.
-- Only 13% were genuine TTL refreshes. Requiring the object to stay picked
-- briefly before spending a round trip drops that 63% without changing what a
-- resting tooltip shows.
--
-- Cold keys only: an object we already hold a cache entry for refreshes with no
-- dwell, so re-hovering something you just looked at stays instant (entries
-- live 30s, see EVICT_TTL_MS). Only genuinely-new objects pay the delay.
local HOVER_DWELL_MS = 200

local cache = {}        -- key -> { data = table, timestamp = number }
local pendingKeys = {}  -- key -> timestamp of last request sent
local dwellKey = nil    -- object key the cursor is currently settling on
local dwellSince = 0    -- getTimestampMs() when dwellKey became the picked object

-- Aggregate spec cache (avoids per-frame table allocation in _mpAggregate)
local aggCache = nil        -- cached dataSpec result
local aggVersion = nil      -- _providerVersion at cache time
local aggFingerprint = nil  -- concatenated active provider IDs

--- Build cache key from object coordinates.
---@param x number
---@param y number
---@param z number
---@param objectIndex number
---@return string
local function cacheKey(x, y, z, objectIndex)
    return x .. ":" .. y .. ":" .. z .. ":" .. objectIndex
end

--- Get cached data if it exists and hasn't expired.
---@param x number
---@param y number
---@param z number
---@param objectIndex number
---@return table|nil The cached mpData table, or nil if expired/missing
function TooltipLib._mpGetCached(x, y, z, objectIndex)
    local key = cacheKey(x, y, z, objectIndex)
    local entry = cache[key]
    if not entry then return nil end
    local now = getTimestampMs()
    if (now - entry.timestamp) > CACHE_TTL_MS then
        -- Expired — return stale data but allow re-request
        -- Caller should trigger a refresh but can still render with this data
        return entry.data
    end
    return entry.data
end

--- Check if cached data is fresh (within TTL).
---@param x number
---@param y number
---@param z number
---@param objectIndex number
---@return boolean
function TooltipLib._mpIsCacheFresh(x, y, z, objectIndex)
    local key = cacheKey(x, y, z, objectIndex)
    local entry = cache[key]
    if not entry then return false end
    return (getTimestampMs() - entry.timestamp) <= CACHE_TTL_MS
end

-- ============================================================================
-- Request management
-- ============================================================================

--- Send a data request to the server if not on cooldown for this object.
---@param dataSpec table Aggregated data spec from _mpAggregate
---@param x number
---@param y number
---@param z number
---@param objectIndex number
function TooltipLib._mpRequest(dataSpec, x, y, z, objectIndex)
    -- Respect the EnableMPSync sandbox toggle on the CLIENT too. The server
    -- (MPServer OnClientCommand) already refuses to respond when this is off,
    -- but without this gate the client still fires a readObject command on
    -- every world-object hover — flooding dedicated-server command logs even
    -- though the admin disabled sync. Mirror the server's check exactly.
    if SandboxVars.TooltipLib and SandboxVars.TooltipLib.EnableMPSync == false then
        return
    end

    local key = cacheKey(x, y, z, objectIndex)
    local now = getTimestampMs()

    -- Dwell check: a brand-new object must stay picked for HOVER_DWELL_MS
    -- before it earns a round trip. Objects we already have cached skip this,
    -- so refreshes and re-hovers are never delayed.
    if not cache[key] then
        if dwellKey ~= key then
            dwellKey = key
            dwellSince = now
            return
        end
        if (now - dwellSince) < HOVER_DWELL_MS then
            return
        end
    end

    -- Cooldown check: don't spam requests for the same object
    local lastRequest = pendingKeys[key]
    if lastRequest and (now - lastRequest) < REQUEST_COOLDOWN_MS then
        return
    end
    pendingKeys[key] = now

    local player = getSpecificPlayer(0)
    if not player then return end

    local args = {
        x = x,
        y = y,
        z = z,
        objectIndex = objectIndex,
    }

    -- Simple fields (array of method names)
    if dataSpec.fields and #dataSpec.fields > 0 then
        args.fields = dataSpec.fields
    end

    -- Containers flag
    if dataSpec.containers then
        args.containers = true
    end

    -- ModData fields (array of key names)
    if dataSpec.modDataFields and #dataSpec.modDataFields > 0 then
        args.modDataFields = dataSpec.modDataFields
    end

    -- Square scan flag (for modData fallback)
    if dataSpec.squareScan then
        args.squareScan = true
    end

    -- Locked flag
    if dataSpec.checkLocked then
        args.checkLocked = true
    end

    sendClientCommand(player, MODULE, "readObject", args)
end

-- ============================================================================
-- Response handler
-- ============================================================================

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE then return end
    if command ~= "objectData" then return end
    if not args then return end

    local x = args.x
    local y = args.y
    local z = args.z
    local objectIndex = args.objectIndex
    if type(x) ~= "number" or type(y) ~= "number"
       or type(z) ~= "number" or type(objectIndex) ~= "number" then
        return
    end

    local key = cacheKey(x, y, z, objectIndex)

    -- Store in cache
    cache[key] = {
        data = {
            fields = args.fields,
            containers = args.containers,
            modData = args.modData,
            locked = args.locked,
        },
        timestamp = getTimestampMs(),
    }

    -- Clear pending state
    pendingKeys[key] = nil
end)

-- ============================================================================
-- Periodic cache eviction
-- ============================================================================

local EVICT_TTL_MS = 30000  -- Evict entries older than 30 seconds

local function evictStaleCache()
    local now = getTimestampMs()
    for key, entry in pairs(cache) do
        if (now - entry.timestamp) > EVICT_TTL_MS then
            cache[key] = nil
        end
    end
    for key, ts in pairs(pendingKeys) do
        if (now - ts) > EVICT_TTL_MS then
            pendingKeys[key] = nil
        end
    end
end

Events.EveryOneMinute.Add(evictStaleCache)

-- ============================================================================
-- Provider spec aggregation
-- ============================================================================

--- Build a fingerprint string from the active provider IDs.
--- Provider order is stable (from _evaluateProviders iteration order).
---@param activeProviders table[]
---@return string
local function buildFingerprint(activeProviders)
    local parts = {}
    for i = 1, #activeProviders do
        parts[i] = activeProviders[i].id
    end
    return table.concat(parts, ",")
end

--- Merge mpFields/mpContainers/mpModData/mpLocked/mpSquareScan from all active
--- providers into a single request spec. Deduplicates field names.
--- Result is cached by provider version + active provider ID fingerprint.
---@param activeProviders table[] Array of active provider tables
---@return table|nil dataSpec or nil if no MP data needed
function TooltipLib._mpAggregate(activeProviders)
    -- Check cache: same provider version + same active set = same result
    local ver = TooltipLib._providerVersion
    local fp = buildFingerprint(activeProviders)
    if aggVersion == ver and aggFingerprint == fp and aggCache ~= nil then
        return aggCache
    end

    local fieldSet = {}     -- method name -> true (dedup)
    local fieldList = nil   -- array built from fieldSet
    local containers = false
    local modDataSet = {}   -- modData key -> true (dedup)
    local modDataList = nil
    local checkLocked = false
    local squareScan = false
    local hasAny = false

    for i = 1, #activeProviders do
        local p = activeProviders[i]

        if p.mpFields then
            for j = 1, #p.mpFields do
                local method = p.mpFields[j]
                if not fieldSet[method] then
                    fieldSet[method] = true
                    if not fieldList then fieldList = {} end
                    fieldList[#fieldList + 1] = method
                    hasAny = true
                end
            end
        end

        if p.mpContainers then
            containers = true
            hasAny = true
        end

        if p.mpModData then
            for j = 1, #p.mpModData do
                local key = p.mpModData[j]
                if not modDataSet[key] then
                    modDataSet[key] = true
                    if not modDataList then modDataList = {} end
                    modDataList[#modDataList + 1] = key
                    hasAny = true
                end
            end
        end

        if p.mpLocked then
            checkLocked = true
            hasAny = true
        end

        if p.mpSquareScan then
            squareScan = true
        end
    end

    local result = nil
    if hasAny then
        result = {
            fields = fieldList,
            containers = containers,
            modDataFields = modDataList,
            checkLocked = checkLocked,
            squareScan = squareScan,
        }
    end

    -- Cache for next frame
    aggCache = result
    aggVersion = ver
    aggFingerprint = fp
    return result
end

TooltipLib._log("MPClient loaded — MP tooltip sync enabled")
