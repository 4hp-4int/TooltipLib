-- ============================================================================
-- TooltipLib HookWorldObject — World object tooltip hook
-- ============================================================================
-- Hooks IsoObject.DoSpecialTooltip via the DoSpecialTooltip Lua event.
-- World object tooltips use ObjectTooltip + Layout, the same rendering
-- system as item tooltips, so providers use the same ctx: methods.
--
-- Context shape for target = "object" providers:
--   ctx.object   — IsoObject being hovered
--   ctx.square   — IsoGridSquare the object is on
--   ctx.tooltip  — ObjectTooltip
--   ctx.layout   — Layout (during callback phase)
--   ctx.surface  — "object"
--   ctx.detail   — boolean (detail key held)
--   ctx.helpers  — TooltipLib.Helpers
--
-- enabled() signature: function(object, square) -> boolean
-- ============================================================================

if isServer() then return end

require "TooltipLib/Core"
require "TooltipLib/Helpers"

-- ============================================================================
-- Object marking system
-- ============================================================================
-- PZ only fires DoSpecialTooltip for objects with specialTooltip = true.
-- Some objects (rain collectors, farm plants) are marked by vanilla. Others
-- (generators) are not. This system automatically marks objects that match
-- any registered object provider's enabled() filter.
--
-- Three triggers cover all scenarios:
--   1. LoadGridsquare — chunks loading after file load (SP + MP streaming)
--   2. OnObjectAdded  — objects placed during gameplay (MP + SP)
--   3. Initial scan   — objects in chunks loaded before providers registered
-- ============================================================================

--- Check whether an object should be marked with specialTooltip.
--- Returns false for already-marked objects (idempotent).
--- Only providers WITH enabled() participate — providers without enabled()
--- match everything, which would mark every object in the world.
--- Caller must pass the provider list (avoids re-fetching per object).
---@param object IsoObject
---@param providers table[] Pre-fetched provider array
---@return boolean
local function shouldMarkObject(object, providers)
    local ok, already = pcall(object.haveSpecialTooltip, object)
    if not ok or already then return false end

    for i = 1, #providers do
        local p = providers[i]
        if p.enabled then
            local eOk, eResult = pcall(p.enabled, object)
            if not eOk then
                TooltipLib._recordError(p.id)
            elseif eResult == true then
                return true
            end
        end
    end
    return false
end

--- Mark all eligible objects on a grid square.
--- Caller must pass the provider list (avoids re-fetching per square).
---@param square IsoGridSquare
---@param providers table[] Pre-fetched provider array
local function markObjectsOnSquare(square, providers)
    local ok, objects = pcall(square.getObjects, square)
    if not ok or not objects then return end
    local count = objects:size()
    TooltipLib._markingPhase = true
    for i = 0, count - 1 do
        local obj = objects:get(i)
        if obj and shouldMarkObject(obj, providers) then
            pcall(obj.setSpecialTooltip, obj, true)
        end
    end
    TooltipLib._markingPhase = false
end

-- Register at file load time: LoadGridsquare fires during world load,
-- BEFORE OnGameStart. This catches chunks streaming in after this point.
Events.LoadGridsquare.Add(function(square)
    if not square then return end
    local providers = TooltipLib._getProvidersForTarget("object")
    if #providers == 0 then return end
    markObjectsOnSquare(square, providers)
end)

--- Scan all loaded chunks to mark eligible objects.
--- Runs once at OnGameStart to catch objects in chunks that loaded before
--- any object providers were registered (timing depends on mod load order).
--- Iterates only actually-loaded chunks via IsoChunkMap — no brute-force radius.
local function scanLoadedChunks()
    local providers = TooltipLib._getProvidersForTarget("object")
    if #providers == 0 then return end

    local cell = getCell()
    if not cell then return end

    local marked = 0
    TooltipLib._markingPhase = true
    local scanOk, scanErr = pcall(function()
        local chunkMap = cell:getChunkMap(0)
        if not chunkMap then return end

        local gridWidth = tonumber(IsoChunkMap.chunkGridWidth)
        if not gridWidth or gridWidth <= 0 then return end

        for cx = 0, gridWidth - 1 do
            for cy = 0, gridWidth - 1 do
                local chunk = chunkMap:getChunk(cx, cy)
                if chunk then
                    for z = 0, 7 do
                        for sx = 0, 7 do
                            for sy = 0, 7 do
                                local sq = chunk:getGridSquare(sx, sy, z)
                                if sq then
                                    local objects = sq:getObjects()
                                    if objects then
                                        for oi = 0, objects:size() - 1 do
                                            local obj = objects:get(oi)
                                            if obj and shouldMarkObject(obj, providers) then
                                                pcall(obj.setSpecialTooltip, obj, true)
                                                marked = marked + 1
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    TooltipLib._markingPhase = false

    if not scanOk then
        TooltipLib._logOnce("initial_scan_error",
            "Initial object scan error: " .. tostring(scanErr))
    end
    if marked > 0 then
        TooltipLib._log("Initial scan: marked " .. marked .. " world objects for tooltips")
    end
end

-- ============================================================================
-- DoSpecialTooltip handler + gameplay event hooks
-- ============================================================================

local function InstallWorldObjectHook()
    -- ================================================================
    -- DoSpecialTooltip event listener
    -- ================================================================
    -- Fired by IsoObject.DoSpecialTooltip() when hovering a world object
    -- that has specialTooltip = true. The Java side sets tooltip height
    -- to 0 before firing; if height stays 0 after the event, PZ hides
    -- the tooltip. We must set height > 0 for content to be visible.

    Events.DoSpecialTooltip.Add(function(tooltip, square)
        local providers = TooltipLib._getProvidersForTarget("object")
        if #providers == 0 then return end

        -- Get the object PZ is rendering the tooltip for.
        -- ObjectTooltip.object is a public Java field set by PZ before
        -- firing the event — gives us the exact hovered object, even when
        -- multiple objects share a grid square (e.g., microwave on counter).
        if not square then return end
        local object = tooltip.object

        if not object then return end

        -- Read detail key state
        local detailHeld = TooltipLib._readDetailKey()

        -- Evaluate enabled() for each provider (object providers receive object, square)
        local activeProviders = TooltipLib._evaluateProviders(providers, detailHeld, object, square)

        if not activeProviders then return end

        -- Check if any active provider wants to replace vanilla content
        local shouldReplace = false
        for i = 1, #activeProviders do
            if activeProviders[i].replacesVanilla then
                shouldReplace = true
                break
            end
        end

        -- Build layout on the ObjectTooltip
        local padLeft = tooltip.padLeft or 5
        local padRight = tooltip.padRight or 5
        local padBottom = tooltip.padBottom or 5
        local padTop = tooltip.padTop or 5

        local endY = 0
        local width = 0
        local hadContent = false
        local contexts = {}

        -- Build per-provider context tables
        for i = 1, #activeProviders do
            contexts[i] = setmetatable({
                object = object,
                square = square,
                tooltip = tooltip,
                detail = detailHeld,
                surface = "object",
                helpers = TooltipLib.Helpers,
            }, TooltipLib._ContextMT)
        end

        -- PHASE 1: preTooltip
        for i = 1, #activeProviders do
            local p = activeProviders[i]
            if p.preTooltip then
                local pOk, pErr = pcall(p.preTooltip, contexts[i])
                if not pOk then
                    TooltipLib._log("Provider '" .. p.id ..
                        "' preTooltip error: " .. tostring(pErr))
                    TooltipLib._recordError(p.id)
                end
            end
        end

        -- Capture height set by prior event handlers (e.g., vanilla farming
        -- tooltip). We need to ensure our background covers their content.
        local priorHeight = tooltip:getHeight()

        -- PHASE 2: Layout (two-pass: measure then render with background)
        -- Mirrors vanilla's DoSpecialTooltip pattern: a shared render function
        -- is called twice — once in measure mode (DrawTextureScaled is no-op
        -- per ObjectTooltip Java override), once in render mode (bg draws,
        -- then layout content renders on top). This ensures correct z-ordering
        -- by keeping background draw and layout in the same function call,
        -- matching CFarmingSystem.DoSpecialTooltip1 exactly.
        --
        -- Circuit breaker recording only fires on the render pass
        -- (recordResults=true) to avoid double-counting.
        local layoutOk, layoutErr = pcall(function()
            local startY = padTop

            -- Shared render function matching vanilla's DoSpecialTooltip1:
            -- draw background, then build/render layout in the same call.
            -- In measure mode, DrawTextureScaled is a no-op (ObjectTooltip
            -- Java override checks measureOnly). In render mode, bg draws
            -- first, then layout content renders on top.
            local function doPass(passWidth, recordResults)
                -- Background (no-op in measure mode per ObjectTooltip override)
                local h = tooltip:getHeight()
                local bgH = math.max(h, priorHeight)
                if bgH <= 0 then bgH = 200 end
                local bgTex = tooltip:getTexture()
                if bgTex then
                    -- When replacesVanilla providers are active and add content,
                    -- draw fully opaque bg to cover vanilla's prior rendering.
                    -- Otherwise use semi-transparent (0.75) to blend with vanilla.
                    local bgAlpha = shouldReplace and 1.0 or 0.75
                    tooltip:DrawTextureScaled(bgTex, 0, 0, passWidth, bgH, bgAlpha)
                end

                -- Border outline (guard with isMeasureOnly — DrawTextureScaledColor
                -- is inherited from UIElement and may not respect measureOnly)
                if not tooltip:isMeasureOnly() and h > 0 then
                    tooltip:DrawTextureScaledColor(nil, 0, 0, 1, h, 0.4, 0.4, 0.4, 1)
                    tooltip:DrawTextureScaledColor(nil, 1, 0, passWidth - 2, 1, 0.4, 0.4, 0.4, 1)
                    tooltip:DrawTextureScaledColor(nil, passWidth - 1, 0, 1, h, 0.4, 0.4, 0.4, 1)
                    tooltip:DrawTextureScaledColor(nil, 1, h - 1, passWidth - 2, 1, 0.4, 0.4, 0.4, 1)
                end

                -- Build layout with provider callbacks
                local layout = tooltip:beginLayout()
                local prevAddedContent = false
                local anyContent = false

                for i = 1, #activeProviders do
                    local p = activeProviders[i]
                    contexts[i].layout = layout
                    contexts[i]._needsSeparator = prevAddedContent and p.separator ~= false
                    contexts[i]._itemCount = 0

                    local cOk, cErr = pcall(p.callback, contexts[i])
                    if recordResults then
                        if not cOk then
                            TooltipLib._log("Provider '" .. p.id ..
                                "' callback error: " .. tostring(cErr))
                            TooltipLib._recordError(p.id)
                        else
                            TooltipLib._recordSuccess(p.id)
                        end
                    end

                    if (contexts[i]._itemCount or 0) > 0 then
                        prevAddedContent = true
                        anyContent = true
                    end
                end

                local passEndY = layout:render(padLeft, startY, tooltip)
                tooltip:setHeight(passEndY + padBottom)
                tooltip:endLayout(layout)

                return passEndY, anyContent
            end

            -- Compute effective minimum width from provider requests
            local effectiveMinWidth = 150
            for i = 1, #activeProviders do
                local mw = activeProviders[i].minWidth
                if mw and mw > effectiveMinWidth then
                    effectiveMinWidth = mw
                end
            end

            -- Pass 1: measure (DrawTextureScaled no-op, layout computes sizes)
            tooltip:setMeasureOnly(true)
            local mEndY, mHadContent = doPass(effectiveMinWidth, false)

            if not mHadContent then
                -- No providers added content; bail without drawing background.
                -- Restore prior height so vanilla's tooltip (if any) remains.
                tooltip:setMeasureOnly(false)
                if priorHeight > 0 then
                    tooltip:setHeight(priorHeight)
                end
                return
            end

            hadContent = true
            width = tooltip:getWidth()
            if width < effectiveMinWidth then width = effectiveMinWidth end
            tooltip:setWidth(width)

            -- Pass 2: render (bg draws, then content on top)
            tooltip:setMeasureOnly(false)
            endY = doPass(width, true)
            width = tooltip:getWidth()
            if width < effectiveMinWidth then width = effectiveMinWidth end
        end)

        if not layoutOk then
            TooltipLib._logOnce("object_layout_error",
                "Object tooltip layout error: " .. tostring(layoutErr))
            -- Don't return — fall through to cleanup phase
        end

        -- Phases 2.5, 3, and dimensions only run when layout succeeded
        -- and at least one provider added content
        if layoutOk and hadContent then
            -- PHASE 2.5: Textures
            endY = TooltipLib._processTextureQueue(
                contexts, activeProviders, tooltip, endY, width, padLeft, padRight)

            -- PHASE 3: postRender
            for i = 1, #activeProviders do
                local p = activeProviders[i]
                if p.postRender then
                    contexts[i].endY = endY
                    contexts[i].width = width
                    contexts[i].padLeft = padLeft
                    contexts[i].padRight = padRight
                    contexts[i].padBottom = padBottom

                    local prOk, prErr = pcall(p.postRender, contexts[i])
                    if not prOk then
                        TooltipLib._log("Provider '" .. p.id ..
                            "' postRender error: " .. tostring(prErr))
                        TooltipLib._recordError(p.id)
                    end
                    -- Read back any size changes the provider made
                    if prOk then
                        if type(contexts[i].endY) == "number" then
                            endY = contexts[i].endY
                        end
                        if type(contexts[i].width) == "number" then
                            width = contexts[i].width
                        end
                    end
                end
            end

            -- Height cap: prevent tooltip from exceeding screen bounds
            local wasCapped = false
            local screenOk, screenH = pcall(function()
                return getCore():getScreenHeight()
            end)
            if screenOk and screenH then
                local maxH = screenH - 20
                if (endY + padBottom) > maxH then
                    endY = maxH - padBottom
                    wasCapped = true
                end
            end

            -- Set tooltip dimensions (height must be > 0 or PZ hides the tooltip)
            local dimOk, dimErr = pcall(function()
                tooltip:setHeight(endY + padBottom)
                tooltip:setWidth(width)
            end)
            if not dimOk then
                TooltipLib._logOnce("object_dimension_error",
                    "Object tooltip dimension error: " .. tostring(dimErr))
            end

            -- Draw overflow indicator at bottom of capped tooltip
            if wasCapped then
                pcall(function()
                    local font = UIFont.Small
                    local ellipsis = "..."
                    local textW = getTextManager():MeasureStringX(font, ellipsis)
                    tooltip:DrawText(font, ellipsis,
                        (width - textW) / 2, endY - 14,
                        0.7, 0.7, 0.7, 0.6)
                end)
            end
        end -- layoutOk

        -- PHASE 4: cleanup (guaranteed even on layout error)
        -- NOTE: cleanup success does NOT reset the circuit breaker error count.
        -- Only callback success resets it. This prevents a provider with a
        -- consistently broken callback from being shielded by working cleanup.
        for i = 1, #activeProviders do
            local p = activeProviders[i]
            if p.cleanup then
                local clOk, clErr = pcall(p.cleanup, contexts[i])
                if not clOk then
                    TooltipLib._log("Provider '" .. p.id ..
                        "' cleanup error: " .. tostring(clErr))
                    TooltipLib._recordError(p.id)
                end
            end
        end
    end)

    -- ================================================================
    -- OnObjectAdded: mark objects placed during gameplay
    -- ================================================================
    -- MP: fires client-side from AddItemToMapPacket (other players placing objects)
    -- SP: fires from ISMoveableSpriteProps (player placing/moving objects)
    Events.OnObjectAdded.Add(function(object)
        if not object then return end
        local providers = TooltipLib._getProvidersForTarget("object")
        if #providers == 0 then return end
        TooltipLib._markingPhase = true
        local mark = shouldMarkObject(object, providers)
        TooltipLib._markingPhase = false
        if mark then
            pcall(object.setSpecialTooltip, object, true)
        end
    end)

    -- ================================================================
    -- Initial area scan: mark objects in already-loaded chunks
    -- ================================================================
    -- Catches objects in chunks that loaded before any object providers
    -- were registered (timing depends on mod load order).
    scanLoadedChunks()

    TooltipLib._log("World object hook installed (" ..
        TooltipLib.getProviderCount("object") .. " object providers)")
end

Events.OnGameStart.Add(InstallWorldObjectHook)

TooltipLib._log("HookWorldObject module loaded")
