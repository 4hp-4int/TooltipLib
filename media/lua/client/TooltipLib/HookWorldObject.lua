-- ============================================================================
-- TooltipLib HookWorldObject — World object tooltip hook
-- ============================================================================
-- Renders world object tooltips using a custom ISPanel (WorldObjectPanel)
-- positioned at the cursor via OnPreUIDraw. Works in all modes: SP, listen
-- server (host), and dedicated server (client).
--
-- Discovery: UIManager.getLastPicked() returns the hovered IsoObject each
-- frame — no object marking or specialTooltip flags needed.
--
-- Rendering: WorldObjectPanel is an entry-based ISPanel. Providers add
-- entries (label, keyvalue, progress, etc.) via DirectRenderCMT, and the
-- panel draws them in prerender. Single pass, no Layout measure+render.
--
-- MP data: On dedicated server clients (isClient() and not isServer()),
-- MPClient handles server data requests and caching. In SP and on listen
-- server hosts, providers access object data directly.
--
-- Context shape for target = "object" providers:
--   ctx.object   — IsoObject being hovered
--   ctx.square   — IsoGridSquare the object is on
--   ctx.tooltip  — nil (no ObjectTooltip in this path)
--   ctx._panel   — WorldObjectPanel (set accent color in callback/postRender)
--   ctx.surface  — "object"
--   ctx.detail   — boolean (detail key held)
--   ctx.helpers  — TooltipLib.Helpers
--   ctx._mpData  — table|nil (cached server data on dedicated clients, nil otherwise)
--
-- enabled() signature: function(object, square) -> boolean
-- ============================================================================

require "TooltipLib/Core"
require "TooltipLib/Helpers"
require "TooltipLib/MPClient"

-- ============================================================================
-- WorldObjectPanel — entry-based tooltip panel
-- ============================================================================
-- ISPanel subclass that renders tooltip entries added by providers.
-- Supports: label, keyvalue, progress, spacer, header, divider, text.
-- Content-driven sizing via measureWidth().

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
--- Scans all entries to find the widest content, then returns the panel width
--- to fit. Called after all callbacks have added their entries, before
--- positioning and rendering.
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
    -- available, otherwise compute.
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

-- ============================================================================
-- DirectRenderCMT — context metatable for WorldObjectPanel rendering
-- ============================================================================
-- Combines RecipeContextMT's add* methods (entry-based rendering via
-- self._panel) with ContextMT's object data access methods (readObject,
-- safeCall, etc.). Provider callbacks use the same API in all modes — the
-- metatable transparently routes add* calls to the WorldObjectPanel.

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
            "addTexture is not supported on the object surface")
    end
    DirectRenderCMT.addTextureRow = function()
        TooltipLib._logOnce("directrender_addTextureRow",
            "addTextureRow is not supported on the object surface")
    end
end

-- ============================================================================
-- Suppress vanilla farm tooltip
-- ============================================================================
-- CFarmingSystem.DoSpecialTooltip1 is the ONLY vanilla DoSpecialTooltip
-- handler. When our providers handle farm plants (replacesVanilla = true),
-- suppress vanilla's rendering to prevent double tooltips.

local function suppressVanillaFarmTooltip()
    if not CFarmingSystem or not CFarmingSystem.DoSpecialTooltip1 then
        TooltipLib._logOnce("no_farm_system",
            "CFarmingSystem.DoSpecialTooltip1 not found — vanilla farm tooltip suppression skipped")
        return
    end
    local original = CFarmingSystem.DoSpecialTooltip1
    CFarmingSystem.DoSpecialTooltip1 = function(tooltip, square, ...)
        local providers = TooltipLib._getProvidersForTarget("object")
        if not providers or #providers == 0 then
            return original(tooltip, square, ...)
        end
        for i = 1, #providers do
            local p = providers[i]
            if p.replacesVanilla then
                -- Check circuit breaker
                local err = TooltipLib._errorCounts[p.id]
                if not (err and err.disabled) then
                    -- Check enabled() for this specific object/square
                    if p.enabled then
                        local ok, result = pcall(p.enabled, tooltip.object, square)
                        if ok and result then
                            return  -- our WorldObjectPanel handles it
                        end
                    else
                        return  -- no filter = matches everything
                    end
                end
            end
        end
        return original(tooltip, square, ...)
    end
    TooltipLib._log("Vanilla farm tooltip suppression installed")
end

-- ============================================================================
-- Install hook — single rendering path via OnPreUIDraw
-- ============================================================================

local function InstallWorldObjectHook()
    local tooltipPanel = WorldObjectPanel:new(0, 0, 250, 100)
    tooltipPanel:initialise()
    tooltipPanel:addToUIManager()
    tooltipPanel:setVisible(false)
    tooltipPanel:setAlwaysOnTop(true)

    -- Context table pool: reuse tables across frames to reduce GC pressure
    local ctxPool = {}
    local ctxPoolSize = 0
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
        -- In SP (isClient()=false) and on listen server host (isServer()=true),
        -- providers access object data directly — no network round-trip needed.
        local mpData = nil
        if isClient() and not isServer() then
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
        for i = ctxPoolSize + 1, providerCount do
            ctxPool[i] = {}
            ctxPoolSize = i
        end
        local contexts = {}
        for i = 1, providerCount do
            local ctx = resetTable(ctxPool[i])
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
        for i = providerCount + 1, ctxPoolSize do
            ctxPool[i] = resetTable(ctxPool[i])
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

        -- Measure width from content
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

    -- Suppress vanilla farm plant tooltip when our providers handle it
    suppressVanillaFarmTooltip()

    TooltipLib._hookStatus.object = true
    TooltipLib._log("World object hook installed (" ..
        TooltipLib.getProviderCount("object") .. " object providers)")
end

Events.OnGameStart.Add(InstallWorldObjectHook)

TooltipLib._log("HookWorldObject module loaded")
