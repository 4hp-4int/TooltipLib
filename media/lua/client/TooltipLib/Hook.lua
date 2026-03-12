-- ============================================================================
-- TooltipLib Hook — Layout-family surface hooks + 5-phase dispatch
-- ============================================================================
-- Hooks tooltip pipelines for Layout-family surfaces (ISToolTipInv,
-- ISToolTipItemSlot). All registered providers are called through managed
-- hooks, eliminating conflicts between mods.
--
-- The hooks use a single-layout approach:
--   1. Create one layout for ALL tooltip content (vanilla + providers)
--   2. Call DoTooltipEmbedded with our layout as override — Java adds vanilla
--      items and draws the item name, but does NOT render the layout
--   3. Provider callbacks add items to the SAME layout
--   4. We render the single combined layout — column widths (labels, values,
--      progress bars) are computed together, so everything aligns perfectly
--
-- Five phases per DoTooltip call:
--   PHASE 1   - preTooltip:  Modify item state before vanilla renders
--   PHASE 2   - callback:    Add content to shared layout
--   PHASE 2.5 - textures:    Draw queued textures below layout (framework-managed)
--   PHASE 3   - postRender:  Direct tooltip drawing after layout render
--   PHASE 4   - cleanup:     Restore item state (guaranteed to run)
-- ============================================================================

if isServer() then return end

require "TooltipLib/Core"
require "TooltipLib/Filters"
require "TooltipLib/Helpers"
require "ISUI/ISToolTipInv"
pcall(function() require "TooltipLib/Options" end)
pcall(function() require "Entity/ISUI/Components/Crafting/ISToolTipItemSlot" end)

local function InstallHook()
    -- Boot-time probe: ISToolTipInv must exist with a render function
    if not ISToolTipInv or type(ISToolTipInv.render) ~= "function" then
        TooltipLib._log("WARN: ISToolTipInv.render not found — hook not installed. " ..
            "Tooltip providers will not render. " ..
            "TooltipLib requires Project Zomboid Build 42.13.1+")
        return
    end

    -- Shared state across Layout-family surface hooks
    local frameCounter = 0
    local L1_REFRESH_INTERVAL = 60

    -- First-render API probe state (shared — only need to probe once)
    local apiProbed = false
    local apiDisabled = false

    -- ================================================================
    -- Layout dispatch: phases 1-4 for Layout-family surfaces
    -- ================================================================
    -- Shared by ISToolTipInv and ISToolTipItemSlot hooks.
    --
    -- @param tooltipItem       InventoryItem being tooltipped
    -- @param tooltip           ObjectTooltip instance
    -- @param activeProviders   Array of providers that passed enabled()
    -- @param detailHeld        boolean — is detail key held?
    -- @param surfaceName       "item" or "itemSlot"
    -- @param extraFields       table|nil — extra fields for each context
    -- @param fallbackDoTooltip function — original DoTooltip for error fallback
    local function doLayoutDispatch(tooltipItem, tooltip, activeProviders, detailHeld, surfaceName, extraFields, fallbackDoTooltip, deferStartY)

        -- Build per-provider context tables.
        -- Each provider gets its own mutable context so preTooltip can
        -- stash state for cleanup (e.g., saved clip size).
        local contexts = {}
        for i = 1, #activeProviders do
            local ctx = setmetatable({
                item = tooltipItem,
                tooltip = tooltip,
                detail = detailHeld,
                surface = surfaceName,
            }, TooltipLib._ContextMT)
            if extraFields then
                for k, v in pairs(extraFields) do
                    ctx[k] = v
                end
            end
            contexts[i] = ctx
        end

        -- ================================================================
        -- PHASE 1: Pre-tooltip hooks (before vanilla DoTooltip)
        -- ================================================================
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

        -- ================================================================
        -- PHASE 2: Single layout — vanilla + provider items together
        -- ================================================================
        local padLeft = tooltip.padLeft or 5
        local padRight = tooltip.padRight or 5
        local padBottom = tooltip.padBottom or 5
        local padTop = tooltip.padTop or 5

        local endY = 0
        local width = 0
        local layoutOk, layoutErr = pcall(function()
            local startY
            if deferStartY then
                startY = deferStartY
            else
                local lineSpacing = 14
                pcall(function()
                    lineSpacing = tooltip:getLineSpacing() or 14
                end)
                startY = padTop + lineSpacing
            end

            -- In defer mode, capture the foreign framework's width before
            -- beginLayout so we can preserve it if ours is narrower
            local foreignWidth = deferStartY and tooltip:getWidth() or 0

            local layout = tooltip:beginLayout()

            -- Add vanilla tooltip items to our layout (skip in defer mode —
            -- the foreign framework already rendered vanilla content)
            if not deferStartY then
                tooltipItem:DoTooltipEmbedded(tooltip, layout, 0)
            end

            -- Provider callbacks add items to the SAME layout
            local callbackCache = TooltipLib._callbackCache
            local currentItemId = tooltipItem:getID()

            -- Auto-separator: track whether previous provider added content
            local prevAddedContent = false

            for i = 1, #activeProviders do
                local p = activeProviders[i]
                contexts[i].layout = layout
                contexts[i].helpers = TooltipLib.Helpers

                -- Auto-separator: set flag for deferred insertion
                contexts[i]._needsSeparator = prevAddedContent and p.separator ~= false
                contexts[i]._itemCount = 0

                if p.cacheable then
                    -- Level 2 cache: check for display list hit
                    local cached = callbackCache[p.id]
                    local currentCacheKey = nil
                    if p.cacheKey then
                        local ckOk, ckResult = pcall(p.cacheKey, tooltipItem)
                        if ckOk then
                            -- Validate cacheKey return type
                            local ckType = type(ckResult)
                            if ckType == "table" then
                                TooltipLib._logOnce("cachekey_table_" .. p.id,
                                    "Provider '" .. p.id .. "' cacheKey returned a table. " ..
                                    "Tables always miss (compared by reference). " ..
                                    "Return a string, number, boolean, or nil instead.")
                            end
                            currentCacheKey = ckResult
                        end
                    end

                    -- Check maxAge expiration
                    local expired = false
                    if cached and p.maxAge then
                        if (frameCounter - (cached.frameRecorded or 0)) >= p.maxAge then
                            expired = true
                            TooltipLib._debugLog("L2 maxAge expired for '" .. p.id .. "'")
                        end
                    end

                    if cached
                        and not expired
                        and cached.itemId == currentItemId
                        and cached.cacheKey == currentCacheKey
                        and cached.detailHeld == detailHeld then
                        -- Cache hit: replay display list
                        TooltipLib._debugLog("L2 cache hit for '" .. p.id .. "'")
                        local rOk, rErr = pcall(
                            TooltipLib._replayDisplayList,
                            contexts[i], cached.displayList)
                        if not rOk then
                            TooltipLib._log("Provider '" .. p.id ..
                                "' replay error: " .. tostring(rErr))
                            -- Fallback: clear cache, run callback fresh
                            callbackCache[p.id] = nil
                            local cOk, cErr = pcall(p.callback, contexts[i])
                            if not cOk then
                                TooltipLib._log("Provider '" .. p.id ..
                                    "' callback error: " .. tostring(cErr))
                                TooltipLib._recordError(p.id)
                            else
                                TooltipLib._recordSuccess(p.id)
                            end
                        end
                    else
                        -- Cache miss: record + execute
                        TooltipLib._debugLog("L2 cache miss for '" .. p.id .. "'")
                        local proxy, displayList =
                            TooltipLib._createRecordingContext(contexts[i])
                        local cOk, cErr = pcall(p.callback, proxy)
                        if not cOk then
                            TooltipLib._log("Provider '" .. p.id ..
                                "' callback error: " .. tostring(cErr))
                            TooltipLib._recordError(p.id)
                            callbackCache[p.id] = nil
                        else
                            TooltipLib._recordSuccess(p.id)
                            callbackCache[p.id] = {
                                itemId = currentItemId,
                                cacheKey = currentCacheKey,
                                displayList = displayList,
                                frameRecorded = frameCounter,
                                detailHeld = detailHeld,
                            }
                        end
                    end
                else
                    -- Not cacheable: run callback normally
                    local cOk, cErr = pcall(p.callback, contexts[i])
                    if not cOk then
                        TooltipLib._log("Provider '" .. p.id ..
                            "' callback error: " .. tostring(cErr))
                        TooltipLib._recordError(p.id)
                    else
                        TooltipLib._recordSuccess(p.id)
                    end
                end

                -- Auto-separator: track if this provider added content
                if (contexts[i]._itemCount or 0) > 0 then
                    prevAddedContent = true
                end
            end

            -- Render the single combined layout. Column widths (label,
            -- value, progress bar) are computed across ALL items together.
            endY = layout:render(padLeft, startY, tooltip)
            tooltip:endLayout(layout)

            -- Compute effective minimum width from provider requests
            local effectiveMinWidth = 150
            for i = 1, #activeProviders do
                local mw = activeProviders[i].minWidth
                if mw and mw > effectiveMinWidth then
                    effectiveMinWidth = mw
                end
            end

            width = tooltip:getWidth()
            if deferStartY then
                width = math.max(width, foreignWidth)
            end
            if width < effectiveMinWidth then width = effectiveMinWidth end
        end)

        if not layoutOk then
            if fallbackDoTooltip then
                TooltipLib._logOnce("layout_error",
                    "Layout API error — falling back to vanilla tooltip. " ..
                    "Error: " .. tostring(layoutErr))
                -- Fallback: let original DoTooltip render vanilla content
                pcall(fallbackDoTooltip, tooltipItem, tooltip)
            else
                -- Defer mode: no fallback available (foreign framework
                -- already rendered vanilla content)
                TooltipLib._logOnce("deferred_layout_error",
                    "Deferred layout error: " .. tostring(layoutErr))
            end
        end

        -- ================================================================
        -- PHASE 2.5: Framework texture drawing
        -- ================================================================
        -- Process queued textures from ctx:addTexture() and
        -- ctx:addTextureRow() calls. Drawn below the layout, before
        -- provider postRender callbacks see the updated endY.
        -- ================================================================
        if layoutOk then
            endY = TooltipLib._processTextureQueue(
                contexts, activeProviders, tooltip, endY, width, padLeft, padRight)
        end

        -- ================================================================
        -- PHASE 3: Post-render hooks (direct tooltip drawing)
        -- ================================================================
        -- Set tooltip dimensions before postRender so providers reading
        -- tooltip:getHeight()/getWidth() see the current layout extent.
        -- In deferred mode, the foreign framework's height is stale at
        -- this point — without this, postRender draws (e.g. accent bars)
        -- only cover the foreign content area, not provider content below.
        -- Final dimensions are re-applied after Phase 3 (accounting for
        -- any endY/width changes providers make via ctx).
        if layoutOk then
            pcall(function()
                tooltip:setHeight(endY + padBottom)
                tooltip:setWidth(width)
            end)
        end

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

        -- Final tooltip dimensions (after all providers including postRender)
        -- Height cap: prevent tooltip from exceeding screen bounds
        if layoutOk then
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

            local dimOk, dimErr = pcall(function()
                tooltip:setHeight(endY + padBottom)
                tooltip:setWidth(width)
            end)
            if not dimOk then
                TooltipLib._logOnce("dimension_error",
                    "Dimension error: " .. tostring(dimErr))
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
        end

        -- ================================================================
        -- PHASE 4: Cleanup hooks (guaranteed to run)
        -- ================================================================
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
    end

    -- ================================================================
    -- Deferred mode background helper
    -- ================================================================
    -- Draws the background + border extension for provider content
    -- appended below a foreign framework's tooltip. Uses the ISPanel's
    -- backgroundColor/borderColor to match the active theme.
    --
    -- @param panel       ISToolTipInv or ISToolTipItemSlot (ISPanel)
    -- @param foreignH    Height set by the foreign framework
    -- @param totalH      Total height including our provider content
    -- @param totalW      Total width of the tooltip
    local function drawDeferredBackground(panel, foreignH, totalH, totalW)
        if totalH <= foreignH then return end
        local bg = panel.backgroundColor
        local bd = panel.borderColor
        if not bg or not bd then return end
        -- Erase old bottom border (replace with background)
        panel:drawRect(1, foreignH - 1, totalW - 2, 1,
            bg.a, bg.r, bg.g, bg.b)
        -- Background fill for extension area
        panel:drawRect(0, foreignH, totalW, totalH - foreignH,
            bg.a, bg.r, bg.g, bg.b)
        -- Side borders for extension
        panel:drawRect(0, foreignH, 1, totalH - foreignH,
            bd.a, bd.r, bd.g, bd.b)
        panel:drawRect(totalW - 1, foreignH, 1, totalH - foreignH,
            bd.a, bd.r, bd.g, bd.b)
        -- New bottom border
        panel:drawRect(0, totalH - 1, totalW, 1,
            bd.a, bd.r, bd.g, bd.b)
    end

    -- ================================================================
    -- ISToolTipInv hook (inventory item tooltips)
    -- ================================================================
    local original_render = ISToolTipInv.render

    -- Level 1 cache (ISToolTipInv-specific)
    local inv_cachedItemId = nil
    local inv_cachedProviderVersion = nil
    local inv_cachedActiveProviders = nil  -- nil is valid (means "none active")
    local inv_cachedL1Frame = 0
    local inv_cachedDetailState = false
    -- Deferred mode: cached dimensions from previous frame
    local inv_deferCachedH = 0
    local inv_deferCachedW = 0

    ISToolTipInv.render = function(self)
        local item = self.item
        local providers = TooltipLib._getProvidersForTarget("item")

        frameCounter = frameCounter + 1

        -- Fast exit: no item or no providers registered
        if not item or #providers == 0 then
            original_render(self)
            return
        end

        -- Permanently disabled if first-render probe failed
        if apiDisabled then
            original_render(self)
            return
        end

        -- First-render API probe: verify DoTooltip/DoTooltipEmbedded exist
        -- on the item metatable. If PZ overhauled the tooltip system, disable
        -- the hook permanently with a clear log rather than failing every frame.
        if not apiProbed then
            apiProbed = true
            local mt = getmetatable(item)
            local idx = mt and mt.__index
            if not idx
                or type(idx.DoTooltip) ~= "function"
                or type(idx.DoTooltipEmbedded) ~= "function" then
                TooltipLib._log("WARN: Item API probe failed — " ..
                    "DoTooltip/DoTooltipEmbedded not found on item metatable. " ..
                    "Hook disabled. TooltipLib requires PZ Build 42.13.1+")
                apiDisabled = true
                original_render(self)
                return
            end
            TooltipLib._log("API probe passed")
        end

        -- Read detail key state (keyboard modifier for "hold Shift for details")
        local detailHeld = TooltipLib._readDetailKey()

        -- Level 1 cache: skip enabled() re-evaluation if same item + same
        -- providers + same detail state + refresh interval hasn't elapsed
        local itemId = item:getID()
        local providerVersion = TooltipLib._providerVersion
        local activeProviders
        local l1Stale = (frameCounter - inv_cachedL1Frame) >= L1_REFRESH_INTERVAL

        if itemId == inv_cachedItemId
            and providerVersion == inv_cachedProviderVersion
            and detailHeld == inv_cachedDetailState
            and not l1Stale then
            activeProviders = inv_cachedActiveProviders
            TooltipLib._debugLog("L1 cache hit (item " .. itemId .. ")")
        else
            -- Cache miss: evaluate enabled() for all providers
            if l1Stale and itemId == inv_cachedItemId then
                TooltipLib._debugLog("L1 periodic refresh (item " .. itemId .. ")")
            else
                TooltipLib._debugLog("L1 cache miss (item " .. itemId .. ")")
            end
            activeProviders = TooltipLib._evaluateProviders(providers, detailHeld, item)

            inv_cachedItemId = itemId
            inv_cachedProviderVersion = providerVersion
            inv_cachedActiveProviders = activeProviders
            inv_cachedDetailState = detailHeld
            inv_cachedL1Frame = frameCounter
        end

        -- No active providers -> vanilla path
        if not activeProviders then
            original_render(self)
            return
        end

        -- Get the item's metatable to hook DoTooltip
        local mt = getmetatable(item)
        if not mt or not mt.__index then
            original_render(self)
            return
        end

        local itemMetatable = mt.__index
        local original_DoTooltip = itemMetatable.DoTooltip

        if not original_DoTooltip then
            original_render(self)
            return
        end

        -- Temporary DoTooltip wrapper: 5-phase provider dispatch
        local ourWrapperFired = false
        itemMetatable.DoTooltip = function(tooltipItem, tooltip)
            ourWrapperFired = true
            doLayoutDispatch(tooltipItem, tooltip, activeProviders, detailHeld,
                "item", nil, original_DoTooltip)
        end

        -- Call the next render in the chain (vanilla, SWSP, AMS, etc.).
        -- When it calls item:DoTooltip(), our wrapper above fires.
        -- pcall-wrapped so the metatable is ALWAYS restored, even on error.
        local renderOk, renderErr = pcall(original_render, self)

        -- Restore original DoTooltip on the metatable (must always run)
        itemMetatable.DoTooltip = original_DoTooltip

        if not renderOk then
            TooltipLib._logOnce("render_chain_error",
                "Render chain error: " .. tostring(renderErr))
        end

        -- Deferred path: our DoTooltip wrapper was overridden by another
        -- tooltip framework (e.g., StarlitLibrary). The foreign framework
        -- rendered vanilla + its own content; we append provider content
        -- below it in a separate layout pass.
        --
        -- Background fix: ISToolTipInv.render draws its background BEFORE
        -- DoTooltip, sized from the measure pass. In deferred mode, the
        -- measure pass only sees the foreign framework's content. We pre-
        -- draw the background extension using cached dimensions from the
        -- previous frame, then render our content on top. One-frame lag
        -- on first hover per item (imperceptible at 60fps).
        if not ourWrapperFired and renderOk and self.tooltip then
            TooltipLib._logOnce("deferred_mode",
                "DoTooltip wrapper overridden by another mod — " ..
                "using deferred layout. Provider content may not " ..
                "align with vanilla tooltip rows.")
            local tooltip = self.tooltip
            local padBottom = tooltip.padBottom or 5
            local foreignH = tooltip:getHeight()
            local foreignW = tooltip:getWidth()
            local deferStartY = foreignH - padBottom

            -- Pre-draw background extension using previous frame's dimensions
            local bgW = math.max(foreignW, inv_deferCachedW)
            drawDeferredBackground(self, foreignH, inv_deferCachedH, bgW)

            -- Render provider content on top of the background
            doLayoutDispatch(self.item, tooltip, activeProviders, detailHeld,
                "item", nil, nil, deferStartY)

            -- Cache total dimensions for next frame's background pre-draw
            inv_deferCachedH = tooltip:getHeight()
            inv_deferCachedW = math.max(foreignW, tooltip:getWidth())

            -- Sync ISPanel dimensions so positioning calculations work
            self:setHeight(inv_deferCachedH)
            self:setWidth(inv_deferCachedW)
        else
            inv_deferCachedH = 0
            inv_deferCachedW = 0
        end
    end

    TooltipLib._log("ISToolTipInv hook installed (" ..
        TooltipLib.getProviderCount("item") .. " item providers)")

    -- ================================================================
    -- ISToolTipItemSlot hook (crafting slot tooltips)
    -- ================================================================
    -- ISToolTipItemSlot is Build 42's crafting item slot tooltip.
    -- Structurally identical to ISToolTipInv. Item providers auto-apply
    -- here too (merged with itemSlot-specific providers), so existing
    -- providers show up in crafting UI with no code changes.
    -- Providers can check ctx.surface == "itemSlot" to distinguish.

    if ISToolTipItemSlot and type(ISToolTipItemSlot.render) == "function" then
        local original_slot_render = ISToolTipItemSlot.render

        -- Level 1 cache (ISToolTipItemSlot-specific)
        local slot_cachedItemId = nil
        local slot_cachedProviderVersion = nil
        local slot_cachedActiveProviders = nil
        local slot_cachedL1Frame = 0
        local slot_cachedDetailState = false
        -- Memoized merge of item + itemSlot providers (keyed on _providerVersion)
        local slot_mergedProviders = nil
        local slot_mergedVersion = nil
        -- Deferred mode: cached dimensions from previous frame
        local slot_deferCachedH = 0
        local slot_deferCachedW = 0

        ISToolTipItemSlot.render = function(self)
            local item = self.item

            frameCounter = frameCounter + 1

            -- Guard: only hook InventoryItem (not Resource)
            if not item or not instanceof(item, "InventoryItem") then
                original_slot_render(self)
                return
            end

            -- Shared API probe (may already have been done by ISToolTipInv)
            if apiDisabled then
                original_slot_render(self)
                return
            end

            if not apiProbed then
                apiProbed = true
                local mt = getmetatable(item)
                local idx = mt and mt.__index
                if not idx
                    or type(idx.DoTooltip) ~= "function"
                    or type(idx.DoTooltipEmbedded) ~= "function" then
                    TooltipLib._log("WARN: Item API probe failed (itemSlot) — " ..
                        "DoTooltip/DoTooltipEmbedded not found. Hook disabled.")
                    apiDisabled = true
                    original_slot_render(self)
                    return
                end
                TooltipLib._log("API probe passed (itemSlot)")
            end

            -- Merge item + itemSlot providers (memoized on _providerVersion)
            local providerVersion = TooltipLib._providerVersion
            local mergedProviders = slot_mergedProviders
            if slot_mergedVersion ~= providerVersion then
                local itemProviders = TooltipLib._getProvidersForTarget("item")
                local slotProviders = TooltipLib._getProvidersForTarget("itemSlot")

                if #slotProviders == 0 then
                    mergedProviders = itemProviders
                elseif #itemProviders == 0 then
                    mergedProviders = slotProviders
                else
                    -- Sorted merge of two priority-sorted arrays
                    mergedProviders = {}
                    local ii, si = 1, 1
                    while ii <= #itemProviders and si <= #slotProviders do
                        local ip = itemProviders[ii]
                        local sp = slotProviders[si]
                        if ip.priority < sp.priority or
                           (ip.priority == sp.priority and ip.id < sp.id) then
                            mergedProviders[#mergedProviders + 1] = ip
                            ii = ii + 1
                        else
                            mergedProviders[#mergedProviders + 1] = sp
                            si = si + 1
                        end
                    end
                    while ii <= #itemProviders do
                        mergedProviders[#mergedProviders + 1] = itemProviders[ii]
                        ii = ii + 1
                    end
                    while si <= #slotProviders do
                        mergedProviders[#mergedProviders + 1] = slotProviders[si]
                        si = si + 1
                    end
                end
                slot_mergedProviders = mergedProviders
                slot_mergedVersion = providerVersion
            end

            if not mergedProviders or #mergedProviders == 0 then
                original_slot_render(self)
                return
            end

            local detailHeld = TooltipLib._readDetailKey()

            -- Level 1 cache (slot-specific)
            local itemId = item:getID()
            local activeProviders
            local l1Stale = (frameCounter - slot_cachedL1Frame) >= L1_REFRESH_INTERVAL

            if itemId == slot_cachedItemId
                and providerVersion == slot_cachedProviderVersion
                and detailHeld == slot_cachedDetailState
                and not l1Stale then
                activeProviders = slot_cachedActiveProviders
                TooltipLib._debugLog("L1 cache hit (itemSlot " .. itemId .. ")")
            else
                if l1Stale and itemId == slot_cachedItemId then
                    TooltipLib._debugLog("L1 periodic refresh (itemSlot " .. itemId .. ")")
                else
                    TooltipLib._debugLog("L1 cache miss (itemSlot " .. itemId .. ")")
                end
                activeProviders = TooltipLib._evaluateProviders(mergedProviders, detailHeld, item)

                slot_cachedItemId = itemId
                slot_cachedProviderVersion = providerVersion
                slot_cachedActiveProviders = activeProviders
                slot_cachedDetailState = detailHeld
                slot_cachedL1Frame = frameCounter
            end

            if not activeProviders then
                original_slot_render(self)
                return
            end

            local mt = getmetatable(item)
            if not mt or not mt.__index then
                original_slot_render(self)
                return
            end

            local itemMetatable = mt.__index
            local original_DoTooltip = itemMetatable.DoTooltip

            if not original_DoTooltip then
                original_slot_render(self)
                return
            end

            -- Extra context fields for itemSlot surface
            local itemSlotRef = self.itemSlot

            local ourSlotWrapperFired = false
            itemMetatable.DoTooltip = function(tooltipItem, tooltip)
                ourSlotWrapperFired = true
                doLayoutDispatch(tooltipItem, tooltip, activeProviders, detailHeld,
                    "itemSlot", { itemSlot = itemSlotRef }, original_DoTooltip)
            end

            local renderOk, renderErr = pcall(original_slot_render, self)

            -- Restore original DoTooltip (must always run)
            itemMetatable.DoTooltip = original_DoTooltip

            if not renderOk then
                TooltipLib._logOnce("slot_render_chain_error",
                    "ItemSlot render chain error: " .. tostring(renderErr))
            end

            -- Deferred path (same pattern as ISToolTipInv)
            if not ourSlotWrapperFired and renderOk and self.tooltip then
                TooltipLib._logOnce("slot_deferred_mode",
                    "ItemSlot DoTooltip wrapper overridden by another mod — " ..
                    "using deferred layout.")
                local tooltip = self.tooltip
                local padBottom = tooltip.padBottom or 5
                local foreignH = tooltip:getHeight()
                local foreignW = tooltip:getWidth()
                local deferStartY = foreignH - padBottom

                local bgW = math.max(foreignW, slot_deferCachedW)
                drawDeferredBackground(self, foreignH, slot_deferCachedH, bgW)

                doLayoutDispatch(self.item, tooltip, activeProviders, detailHeld,
                    "itemSlot", { itemSlot = itemSlotRef }, nil, deferStartY)

                slot_deferCachedH = tooltip:getHeight()
                slot_deferCachedW = math.max(foreignW, tooltip:getWidth())
                self:setHeight(slot_deferCachedH)
                self:setWidth(slot_deferCachedW)
            else
                slot_deferCachedH = 0
                slot_deferCachedW = 0
            end
        end

        TooltipLib._log("ISToolTipItemSlot hook installed (" ..
            TooltipLib.getProviderCount("itemSlot") .. " slot providers, " ..
            TooltipLib.getProviderCount("item") .. " item providers auto-applied)")
    end
end

Events.OnGameStart.Add(InstallHook)

TooltipLib._log("Hook module loaded")
