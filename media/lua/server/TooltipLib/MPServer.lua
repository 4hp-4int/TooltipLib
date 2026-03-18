-- ============================================================================
-- TooltipLib MPServer — Server-side object data reader for MP tooltips
-- ============================================================================
-- Generic handler for client tooltip data requests. Receives object
-- coordinates + a data spec (field names, container flag, modData keys),
-- reads the authoritative state on the server, and responds to the
-- requesting client only.
--
-- Security: only calls methods that pass the whitelist check (standard
-- getter prefixes: get, is, has, check, plus explicit allowMPMethod calls).
-- ============================================================================

if not isServer() then return end

local MODULE = "TooltipLib"

-- ============================================================================
-- Method whitelist (mirrors Core.lua's _isMPMethodAllowed)
-- ============================================================================
-- Duplicated here because Core.lua may not load on a dedicated server
-- (it lives in client/). The whitelist table is populated by provider
-- registrations on the client, but the server needs its own check.

-- Default-allowed non-standard getters (methods that don't follow get/is/has/check
-- naming but are safe read-only accessors on PZ objects).
local allowedMethods = {
    Activated = true,  -- IsoStove property accessor
}

--- Check if a method name is safe to call.
--- Allows standard getter prefixes and explicitly whitelisted names.
---@param methodName string
---@return boolean
local function isMethodAllowed(methodName)
    if type(methodName) ~= "string" or methodName == "" then return false end
    if allowedMethods[methodName] then return true end
    local prefix = methodName:sub(1, 3)
    if prefix == "get" or prefix == "has" then return true end
    if methodName:sub(1, 2) == "is" then return true end
    if methodName:sub(1, 5) == "check" then return true end
    return false
end

-- ============================================================================
-- Object lookup
-- ============================================================================

--- Find an object on a grid square by index.
---@param x number Grid X
---@param y number Grid Y
---@param z number Grid Z (floor)
---@param objectIndex number Index within square:getObjects()
---@return IsoObject|nil object
---@return IsoGridSquare|nil square
local function findObject(x, y, z, objectIndex)
    local cell = getCell()
    if not cell then return nil, nil end
    local ok, square = pcall(cell.getGridSquare, cell, x, y, z)
    if not ok or not square then return nil, nil end
    local oOk, objects = pcall(square.getObjects, square)
    if not oOk or not objects then return nil, nil end
    local sOk, size = pcall(objects.size, objects)
    if not sOk or not size then return nil, nil end
    if objectIndex < 0 or objectIndex >= size then return nil, nil end
    local gOk, obj = pcall(objects.get, objects, objectIndex)
    if not gOk or not obj then return nil, nil end
    return obj, square
end

-- ============================================================================
-- Data readers
-- ============================================================================

--- Read simple fields (call named methods, return primitives).
---@param obj IsoObject
---@param fields string[] Array of method names
---@return table<string, any> Results keyed by method name
local function readFields(obj, fields)
    local result = {}
    for i = 1, #fields do
        local method = fields[i]
        if isMethodAllowed(method) then
            local fn = obj[method]
            if fn then
                local ok, val = pcall(fn, obj)
                if ok and val ~= nil then
                    -- Only serialize primitives (numbers, booleans, strings)
                    local t = type(val)
                    if t == "number" or t == "boolean" or t == "string" then
                        result[method] = val
                    end
                end
            end
        end
    end
    return result
end

--- Read container metadata from all containers on an object.
---@param obj IsoObject
---@return table[] Array of container info tables
local function readContainers(obj)
    local result = {}
    local ok, count = pcall(obj.getContainerCount, obj)
    if not ok or not count then return result end
    for i = 0, count - 1 do
        local cOk, c = pcall(obj.getContainerByIndex, obj, i)
        if cOk and c then
            local entry = {}
            local tOk, t = pcall(c.getType, c)
            if tOk then entry.type = t end
            local wOk, w = pcall(c.getContentsWeight, c)
            if wOk then entry.weight = w end
            local capOk, cap = pcall(c.getCapacity, c)
            if capOk then entry.capacity = cap end
            local iOk, items = pcall(c.getItems, c)
            if iOk and items then
                local sOk, s = pcall(items.size, items)
                if sOk then entry.itemCount = s end
            end
            local pOk, p = pcall(c.isPowered, c)
            if pOk then entry.powered = p end
            result[#result + 1] = entry
        end
    end
    return result
end

--- Read modData fields from an object. If squareScan is true and the target
--- object doesn't have the requested fields, scan other objects on the square.
---@param obj IsoObject
---@param square IsoGridSquare
---@param modDataFields string[] Keys to extract
---@param squareScan boolean Scan square for modData if not on target
---@return table|nil Extracted modData subset
local function readModData(obj, square, modDataFields, squareScan)
    -- Try target object first
    local ok, md = pcall(obj.getModData, obj)
    if ok and md then
        -- Check if any requested field exists
        local hasAny = false
        for i = 1, #modDataFields do
            if md[modDataFields[i]] ~= nil then
                hasAny = true
                break
            end
        end
        if hasAny then
            local result = {}
            for i = 1, #modDataFields do
                local key = modDataFields[i]
                result[key] = md[key]
            end
            return result
        end
    end

    -- Square scan fallback: check other objects on the same square
    if squareScan and square then
        local sOk, objects = pcall(square.getObjects, square)
        if sOk and objects then
            local szOk, sz = pcall(objects.size, objects)
            if szOk and sz then
                for i = 0, sz - 1 do
                    local scanObj = objects:get(i)
                    if scanObj and scanObj ~= obj then
                        local mdOk, scanMd = pcall(scanObj.getModData, scanObj)
                        if mdOk and scanMd then
                            local scanHasAny = false
                            for j = 1, #modDataFields do
                                if scanMd[modDataFields[j]] ~= nil then
                                    scanHasAny = true
                                    break
                                end
                            end
                            if scanHasAny then
                                local result = {}
                                for j = 1, #modDataFields do
                                    local key = modDataFields[j]
                                    result[key] = scanMd[key]
                                end
                                return result
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

--- Check if an object is locked (IsoThumpable only).
---@param obj IsoObject
---@return boolean
local function readLocked(obj)
    if not instanceof(obj, "IsoThumpable") then return false end
    local ok, locked = pcall(obj.isLocked, obj)
    return ok and locked == true
end

-- ============================================================================
-- Command handler
-- ============================================================================

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE then return end
    if command ~= "readObject" then return end
    if not args then return end

    -- Validate coordinates
    local x = args.x
    local y = args.y
    local z = args.z
    local objectIndex = args.objectIndex
    if type(x) ~= "number" or type(y) ~= "number"
       or type(z) ~= "number" or type(objectIndex) ~= "number" then
        return
    end

    local obj, square = findObject(x, y, z, objectIndex)
    if not obj then return end

    local result = {
        x = x,
        y = y,
        z = z,
        objectIndex = objectIndex,
    }

    -- Simple fields
    if args.fields and type(args.fields) == "table" then
        result.fields = readFields(obj, args.fields)
    end

    -- Containers
    if args.containers then
        result.containers = readContainers(obj)
    end

    -- ModData
    if args.modDataFields and type(args.modDataFields) == "table" then
        result.modData = readModData(obj, square, args.modDataFields,
                                     args.squareScan == true)
    end

    -- Locked
    if args.checkLocked then
        result.locked = readLocked(obj)
    end

    sendServerCommand(player, MODULE, "objectData", result)
end)

print("[TooltipLib] MPServer loaded — listening for tooltip data requests")
