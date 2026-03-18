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

require "TooltipLib/Core"
require "TooltipLib/Helpers"
require "TooltipLib/MPClient"

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
-- SP only: in MP, specialTooltip flag is unreliable (network sync overwrites it).
if not isClient() then
    Events.LoadGridsquare.Add(function(square)
        if not square then return end
        local providers = TooltipLib._getProvidersForTarget("object")
        if #providers == 0 then return end
        markObjectsOnSquare(square, providers)
    end)
end

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
-- MP direct render: WorldObjectPanel + DirectRenderContextMT
-- ============================================================================
-- In multiplayer, the specialTooltip flag is unreliable (network sync
-- overwrites client-side changes). Instead, OnPreUIDraw checks the hovered
-- object via UIManager.getLastPicked() and renders a custom ISPanel tooltip.
-- Provider callbacks write entries to the panel via the same add* API they
-- use in SP (addLabel, addKeyValue, addProgress, etc.) — the DirectRenderCMT
-- metatable routes these to the panel's entry-based renderer.

local WorldObjectPanel = ISPanel:derive("TooltipLib_WorldObjectPanel")

function WorldObjectPanel:new(x, y, w, h)
    local o = ISPanel.new(self, x, y, w, h)
    o._entries = {}
    o._totalHeight = 0
    o.accentColor = nil
    o.background = false
    return o
end

function WorldObjectPanel:clearEntries()
    self._entries = {}
    self._totalHeight = 0
    self.accentColor = nil
    self._measuredWidth = nil
    self._colX = nil
end

function WorldObjectPanel:addEntry(entry)
    self._entries[#self._entries + 1] = entry
    local tm = getTextManager()
    local font = entry.font or UIFont.Small
    local fontH = tm:getFontHeight(font) + 2
    local h = entry.height or fontH
    self._totalHeight = self._totalHeight + h
    self:setHeight(self._totalHeight + 10)
    self._measuredWidth = nil  -- invalidate cached width
end

--- Measure the required panel width from all entries.
--- Mirrors SP ObjectTooltip_Layout's two-pass approach: scan all entries to find
--- the widest content, then set the panel width to fit. Called after all callbacks
--- have added their entries, before positioning and rendering.
---@param minWidth number Minimum panel width (from provider minWidth fields)
---@return number width The computed panel width
function WorldObjectPanel:measureWidth(minWidth)
    if self._measuredWidth then return self._measuredWidth end
    local tm = getTextManager()
    local accentW = self.accentColor and 3 or 0
    local padX = 5 + accentW
    local padRight = 5

    -- First pass: compute shared column position (same logic as prerender)
    local colX = 0
    for i = 1, #self._entries do
        local e = self._entries[i]
        if e.type == "keyvalue" or e.type == "progress" then
            local font = e.font or UIFont.Small
            local label = e.type == "keyvalue" and e.key or e.label
            local keyW = tm:MeasureStringX(font, label)
            local x = math.floor(padX + keyW + 10)
            if x > colX then colX = x end
        end
    end
    colX = math.max(colX, 120)

    -- Second pass: measure each entry's required width
    local maxW = minWidth or 200
    for i = 1, #self._entries do
        local e = self._entries[i]
        local font = e.font or UIFont.Small
        local w = 0

        if e.type == "label" then
            w = padX + tm:MeasureStringX(font, e.text) + padRight
        elseif e.type == "keyvalue" then
            local valW = tm:MeasureStringX(font, e.value)
            w = colX + valW + padRight
        elseif e.type == "progress" then
            -- bar(60) + gap(5) + pct text(~30) + pad
            w = colX + 60 + 5 + 30 + padRight
        elseif e.type == "header" then
            local hFont = e.font or UIFont.Medium
            w = padX + tm:MeasureStringX(hFont, e.text) + padRight
        end

        if w > maxW then maxW = w end
    end

    self._measuredWidth = maxW
    self._colX = colX
    return maxW
end

function WorldObjectPanel:prerender()
    local entries = self._entries
    if #entries == 0 then return end

    local tm = getTextManager()
    local panelW = self:getWidth()
    local panelH = self:getHeight()

    -- Background
    self:drawRect(0, 0, panelW, panelH, 0.92, 0.07, 0.07, 0.07)
    -- Border
    self:drawRectBorder(0, 0, panelW, panelH, 0.8, 0.4, 0.4, 0.4)
    -- Accent bar
    if self.accentColor then
        local ac = self.accentColor
        self:drawRect(0, 0, 2, panelH, ac[4] or 1, ac[1], ac[2], ac[3])
    end

    local accentW = self.accentColor and 3 or 0
    local padX = 5 + accentW
    local y = 5

    -- Shared column alignment: reuse cached colX from measureWidth() when
    -- available, otherwise compute (mirrors SP ObjectTooltip_Layout's
    -- widthLabel/widthValue column tracking).
    local colX = self._colX
    if not colX then
        colX = 0
        for i = 1, #entries do
            local e = entries[i]
            if e.type == "keyvalue" or e.type == "progress" then
                local font = e.font or UIFont.Small
                local label = e.type == "keyvalue" and e.key or e.label
                local keyW = tm:MeasureStringX(font, label)
                local x = math.floor(padX + keyW + 10)
                if x > colX then colX = x end
            end
        end
        colX = math.max(colX, 120)
    end

    for i = 1, #entries do
        local e = entries[i]
        local font = e.font or UIFont.Small
        local fontH = tm:getFontHeight(font) + 2

        if e.type == "label" then
            self:drawText(e.text, padX, y, e.r, e.g, e.b, e.a, font)
            y = y + fontH
        elseif e.type == "keyvalue" then
            self:drawText(e.key, padX, y, e.kr, e.kg, e.kb, e.ka, font)
            self:drawText(e.value, colX, y, e.vr, e.vg, e.vb, e.va, font)
            y = y + fontH
        elseif e.type == "progress" then
            self:drawText(e.label, padX, y, e.lr, e.lg, e.lb, e.la, font)
            local barW = math.max(panelW - colX - 40, 30)
            local barH = fontH - 6
            local barY = y + 3
            self:drawRect(colX, barY, barW, barH, 0.3, 0.3, 0.3, 0.3)
            local fillW = barW * math.max(0, math.min(1, e.fraction))
            self:drawRect(colX, barY, fillW, barH, e.ba, e.br, e.bg, e.bb)
            local pctText = tostring(math.floor(e.fraction * 100 + 0.5)) .. "%"
            self:drawText(pctText, colX + barW + 5, y, e.lr, e.lg, e.lb, e.la, font)
            y = y + fontH
        elseif e.type == "spacer" then
            y = y + fontH
        elseif e.type == "header" then
            local hFont = e.font or UIFont.Medium
            local hFontH = tm:getFontHeight(hFont) + 2
            self:drawText(e.text, padX, y, e.r, e.g, e.b, e.a, hFont)
            y = y + hFontH
        elseif e.type == "divider" then
            local divY = y + math.floor(fontH / 2)
            self:drawRect(padX, divY, panelW - padX * 2, 1, e.a, e.r, e.g, e.b)
            y = y + fontH
        elseif e.type == "text" then
            local wrapAt = panelW - padX * 2 - 5
            local lines = {}
            local current = ""
            for word in e.text:gmatch("%S+") do
                local test = current == "" and word or (current .. " " .. word)
                if tm:MeasureStringX(font, test) > wrapAt and current ~= "" then
                    lines[#lines + 1] = current
                    current = word
                else
                    current = test
                end
            end
            if current ~= "" then lines[#lines + 1] = current end
            for li = 1, #lines do
                self:drawText(lines[li], padX, y, e.r, e.g, e.b, e.a, font)
                y = y + fontH
            end
        end
    end
end

--- Context metatable for MP direct rendering.
--- Combines RecipeContextMT's add* methods (entry-based rendering via self._panel)
--- with ContextMT's object data access methods (readObject, safeCall, etc.).
--- Provider callbacks use the same API in both SP and MP — the metatable
--- transparently routes add* calls to the WorldObjectPanel instead of Layout.
local DirectRenderCMT = {}
DirectRenderCMT.__index = DirectRenderCMT

do
    local RecipeCMT = TooltipLib._RecipeContextMT
    local ObjCMT = TooltipLib._ContextMT
    -- Rendering: write entries to self._panel (WorldObjectPanel)
    DirectRenderCMT.addLabel      = RecipeCMT.addLabel
    DirectRenderCMT.addKeyValue   = RecipeCMT.addKeyValue
    DirectRenderCMT.addProgress   = RecipeCMT.addProgress
    DirectRenderCMT.addInteger    = RecipeCMT.addInteger
    DirectRenderCMT.addFloat      = RecipeCMT.addFloat
    DirectRenderCMT.addPercentage = RecipeCMT.addPercentage
    DirectRenderCMT.addSpacer     = RecipeCMT.addSpacer
    DirectRenderCMT.addHeader     = RecipeCMT.addHeader
    DirectRenderCMT.addDivider    = RecipeCMT.addDivider
    DirectRenderCMT.addText       = RecipeCMT.addText
    -- Object data access: read from self.object / self._mpData
    DirectRenderCMT.readObject     = ObjCMT.readObject
    DirectRenderCMT.safeCall       = ObjCMT.safeCall
    DirectRenderCMT.readContainers = ObjCMT.readContainers
    DirectRenderCMT.readLocked     = ObjCMT.readLocked
    -- Unsupported ContextMT methods: stub with warning
    DirectRenderCMT.addTexture = function()
        TooltipLib._logOnce("directrender_addTexture",
            "addTexture is not supported on the MP object surface")
    end
    DirectRenderCMT.addTextureRow = function()
        TooltipLib._logOnce("directrender_addTextureRow",
            "addTextureRow is not supported on the MP object surface")
    end
end

-- ============================================================================
-- DoSpecialTooltip handler (SP) + MP direct render + gameplay event hooks
-- ============================================================================

local function InstallWorldObjectHook()
    -- ================================================================
    -- MP path: direct panel rendering via OnPreUIDraw
    -- ================================================================
    -- specialTooltip flag is unreliable in MP (network sync overwrites
    -- client-side changes, so DoSpecialTooltip never fires). Instead,
    -- check the hovered object each frame and render our own ISPanel.
    -- Works on both listen servers and dedicated server clients.
    if isClient() then
        local tooltipPanel = WorldObjectPanel:new(0, 0, 250, 100)
        tooltipPanel:initialise()
        tooltipPanel:addToUIManager()
        tooltipPanel:setVisible(false)
        tooltipPanel:setAlwaysOnTop(true)

        -- Context table pool: reuse tables across frames to reduce GC pressure
        -- (mirrors SP path's objCtxPool pattern)
        local mpCtxPool = {}
        local mpCtxPoolSize = 0
        local resetTable = TooltipLib._resetTable

        Events.OnPreUIDraw.Add(function()
            local pickOk, picked = pcall(UIManager.getLastPicked)
            if not pickOk or not picked then
                tooltipPanel:setVisible(false)
                return
            end

            local sqOk, square = pcall(picked.getSquare, picked)
            if not sqOk then square = nil end

            local providers = TooltipLib._getProvidersForTarget("object")
            if #providers == 0 then
                tooltipPanel:setVisible(false)
                return
            end

            local detailHeld = TooltipLib._readDetailKey()
            local activeProviders = TooltipLib._evaluateProviders(
                providers, detailHeld, picked, square)

            if not activeProviders then
                tooltipPanel:setVisible(false)
                return
            end

            -- MP data orchestration (dedicated server client only).
            -- On listen server (isServer()=true), host has direct data
            -- access — skip network round-trip, use SP code paths.
            local mpData = nil
            if not isServer() then
                local dataSpec = TooltipLib._mpAggregate(activeProviders)
                if dataSpec then
                    local idxOk, objIdx = pcall(picked.getObjectIndex, picked)
                    if idxOk and objIdx and square then
                        local x = square:getX()
                        local y = square:getY()
                        local z = square:getZ()
                        if TooltipLib._mpIsCacheFresh(x, y, z, objIdx) then
                            mpData = TooltipLib._mpGetCached(x, y, z, objIdx)
                        else
                            mpData = TooltipLib._mpGetCached(x, y, z, objIdx)
                            TooltipLib._mpRequest(dataSpec, x, y, z, objIdx)
                            if not mpData then
                                tooltipPanel:setVisible(false)
                                return
                            end
                        end
                    end
                end
            end

            -- Clear and rebuild tooltip content
            tooltipPanel:clearEntries()

            local effectiveMinWidth = 200
            for i = 1, #activeProviders do
                local mw = activeProviders[i].minWidth
                if mw and mw > effectiveMinWidth then
                    effectiveMinWidth = mw
                end
            end
            tooltipPanel:setWidth(effectiveMinWidth)

            -- Build per-provider context tables from pool
            local providerCount = #activeProviders
            for i = mpCtxPoolSize + 1, providerCount do
                mpCtxPool[i] = {}
                mpCtxPoolSize = i
            end
            local contexts = {}
            for i = 1, providerCount do
                local ctx = resetTable(mpCtxPool[i])
                ctx.object = picked
                ctx.square = square
                ctx.detail = detailHeld
                ctx.surface = "object"
                ctx.helpers = TooltipLib.Helpers
                ctx._mpData = mpData
                ctx._panel = tooltipPanel
                ctx._needsSeparator = false
                ctx._itemCount = 0
                setmetatable(ctx, DirectRenderCMT)
                contexts[i] = ctx
            end
            -- Nil out stale entries beyond current provider count
            for i = providerCount + 1, mpCtxPoolSize do
                mpCtxPool[i] = resetTable(mpCtxPool[i])
            end

            -- Phase 1: preTooltip
            for i = 1, providerCount do
                local p = activeProviders[i]
                if p.preTooltip then
                    pcall(p.preTooltip, contexts[i])
                end
            end

            -- Phase 2: callbacks
            local anyContent = false
            local prevAddedContent = false
            for i = 1, providerCount do
                local p = activeProviders[i]
                contexts[i]._needsSeparator = prevAddedContent and p.separator ~= false
                contexts[i]._itemCount = 0

                local cOk, cErr = pcall(p.callback, contexts[i])
                if not cOk then
                    TooltipLib._recordError(p.id)
                else
                    TooltipLib._recordSuccess(p.id)
                end

                if (contexts[i]._itemCount or 0) > 0 then
                    prevAddedContent = true
                    anyContent = true
                end
            end

            -- Measure width from content (mirrors SP's measure pass)
            if anyContent then
                local measuredW = tooltipPanel:measureWidth(effectiveMinWidth)
                tooltipPanel:setWidth(measuredW)
            end

            -- Phase 3: postRender
            if anyContent then
                for i = 1, providerCount do
                    local p = activeProviders[i]
                    if p.postRender then
                        contexts[i].endY = tooltipPanel._totalHeight + 5
                        contexts[i].width = tooltipPanel:getWidth()
                        contexts[i].padLeft = 5
                        contexts[i].padRight = 5
                        contexts[i].padBottom = 5
                        pcall(p.postRender, contexts[i])
                    end
                end
            end

            -- Phase 4: cleanup
            for i = 1, providerCount do
                local p = activeProviders[i]
                if p.cleanup then
                    pcall(p.cleanup, contexts[i])
                end
            end

            if not anyContent then
                tooltipPanel:setVisible(false)
                return
            end

            -- Position at cursor with screen bounds clamping
            local mx = getMouseX()
            local my = getMouseY()
            local px = mx + 15
            local py = my + 15
            local pw = tooltipPanel:getWidth()
            local ph = tooltipPanel:getHeight()
            pcall(function()
                local sw = getCore():getScreenWidth()
                local sh = getCore():getScreenHeight()
                if px + pw > sw then px = mx - pw - 5 end
                if py + ph > sh then py = my - ph - 5 end
                if px < 0 then px = 0 end
                if py < 0 then py = 0 end
            end)
            tooltipPanel:setX(px)
            tooltipPanel:setY(py)
            tooltipPanel:setVisible(true)
        end)

        TooltipLib._hookStatus.object = true
        TooltipLib._log("World object hook installed — MP direct render (" ..
            TooltipLib.getProviderCount("object") .. " object providers)")
        return
    end

    -- ================================================================
    -- SP path: DoSpecialTooltip + marking system
    -- ================================================================
    -- Context table pool: reuse tables across frames to reduce GC pressure
    local objCtxPool = {}
    local objCtxPoolSize = 0

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

        -- ================================================================
        -- MP data orchestration
        -- ================================================================
        -- In dedicated-server MP (isClient() and not isServer()), object state
        -- is server-authoritative. Aggregate what data active providers need,
        -- check the local cache, and either inject cached data into contexts or
        -- send a request to the server and skip rendering this frame.
        --
        -- On a listen server (isClient() AND isServer()), the host has direct
        -- access to all object data — skip MP orchestration, use SP code paths.
        local mpData = nil
        if isClient() and not isServer() then
            local dataSpec = TooltipLib._mpAggregate(activeProviders)
            if dataSpec then
                local idxOk, objIdx = pcall(object.getObjectIndex, object)
                if idxOk and objIdx then
                    local x = square:getX()
                    local y = square:getY()
                    local z = square:getZ()
                    if TooltipLib._mpIsCacheFresh(x, y, z, objIdx) then
                        mpData = TooltipLib._mpGetCached(x, y, z, objIdx)
                    else
                        -- Cache miss or stale: try to get stale data for rendering
                        mpData = TooltipLib._mpGetCached(x, y, z, objIdx)
                        -- Send request (respects cooldown internally)
                        TooltipLib._mpRequest(dataSpec, x, y, z, objIdx)
                        if not mpData then
                            -- No data at all (first hover): skip rendering this frame
                            return
                        end
                        -- Have stale data: continue with it while refresh is pending
                    end
                end
            end
        end

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
        local resetTable = TooltipLib._resetTable
        local providerCount = #activeProviders

        -- Build per-provider context tables from pool
        for i = objCtxPoolSize + 1, providerCount do
            objCtxPool[i] = {}
            objCtxPoolSize = i
        end
        local contexts = {}
        for i = 1, providerCount do
            local ctx = resetTable(objCtxPool[i])
            ctx.object = object
            ctx.square = square
            ctx.tooltip = tooltip
            ctx.detail = detailHeld
            ctx.surface = "object"
            ctx.helpers = TooltipLib.Helpers
            ctx._mpData = mpData  -- nil in SP, cached server data in MP
            setmetatable(ctx, TooltipLib._ContextMT)
            contexts[i] = ctx
        end
        -- Nil out stale entries beyond current provider count
        for i = providerCount + 1, objCtxPoolSize do
            objCtxPool[i] = resetTable(objCtxPool[i])
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
    -- SP marking: OnObjectAdded + initial scan
    -- ================================================================
    -- SP only: in MP, the direct render path handles everything via
    -- UIManager.getLastPicked() without needing specialTooltip flags.
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

    scanLoadedChunks()

    TooltipLib._hookStatus.object = true
    TooltipLib._log("World object hook installed (" ..
        TooltipLib.getProviderCount("object") .. " object providers)")
end

Events.OnGameStart.Add(InstallWorldObjectHook)

TooltipLib._log("HookWorldObject module loaded")
