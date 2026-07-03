-- ============================================================================
-- TooltipLib Hook — Layout-family surface hooks + 5-phase dispatch
-- ============================================================================
-- Hooks tooltip pipelines for Layout-family surfaces (ISToolTipInv,
-- ISToolTipItemSlot). All registered providers are called through managed
-- hooks, eliminating conflicts between mods.
--
-- The hooks use a split-layout approach:
--   1. Create a vanilla layout and call DoTooltipEmbedded — Java adds vanilla
--      items and draws the item name, but does NOT render the layout
--   2. Create a provider layout, chained via Layout.next
--   3. Provider callbacks add items to the provider layout
--   4. We render the chain — each section computes column widths independently,
--      preventing vanilla progress bars from inflating provider row widths
--
-- Five phases per DoTooltip call:
--   PHASE 1   - preTooltip:  Modify item state before vanilla renders
--   PHASE 2   - callback:    Add content to shared layout
--   PHASE 2.5 - textures:    Draw queued textures below layout (framework-managed)
--   PHASE 3   - postRender:  Direct tooltip drawing after layout render
--   PHASE 4   - cleanup:     Restore item state (guaranteed to run)
-- ============================================================================

require "TooltipLib/Core"
require "TooltipLib/Filters"
require "TooltipLib/Helpers"
require "ISUI/ISToolTipInv"

pcall(function() require "TooltipLib/Options" end)
pcall(function() require "Entity/ISUI/Components/Crafting/ISToolTipItemSlot" end)

-- B42.16 vanilla bug: getText("Item Report") has no prefix so it always fails.
-- Pre-seed the Translator's "missing" set via unattributed loadstring closure.
pcall(function()
    local fn = loadstring('getText("Item Report")')
    if fn then fn() end
end)

-- B42.16 regression: LuaClosure$DebugInfo.generateModName() unconditionally
-- flags mods in PauseBuggedModList whenever their closures appear in any
-- error call stack — including vanilla Translation ERRORs that mods can't
-- control. Snapshot pre-game-start flags and clear only those, so real
-- runtime errors after game start are preserved.
local _preStartFlags = {}

local function snapshotAndClearBuggedFlags()
    if not PauseBuggedModList then return end

    -- Snapshot which of our mods were flagged during loading
    local names = { "TooltipLib - Shared Tooltip Library" }
    for _, name in ipairs(TooltipLib._buggedFlagsToClear or {}) do
        names[#names + 1] = name
    end
    for _, name in ipairs(names) do
        if PauseBuggedModList[name] then
            _preStartFlags[name] = true
            PauseBuggedModList[name] = nil
        end
    end
end

--- Consumer mods can register their display name to be cleared from
--- PauseBuggedModList on game start (workaround for B42.16 false flags).
--- Only clears flags set during loading; real runtime errors are preserved.
---@param modDisplayName string The mod's display name as shown in mod.info
function TooltipLib.clearBuggedFlag(modDisplayName)
    TooltipLib._buggedFlagsToClear = TooltipLib._buggedFlagsToClear or {}
    table.insert(TooltipLib._buggedFlagsToClear, modDisplayName)
end
Events.OnGameStart.Add(snapshotAndClearBuggedFlags)

local function InstallHook()
    -- Boot-time probe: ISToolTipInv must exist with a render function
    if not ISToolTipInv or type(ISToolTipInv.render) ~= "function" then
        TooltipLib._warn("ISToolTipInv.render not found — hook not installed. " ..
            "Tooltip providers will not render. " ..
            "TooltipLib requires Project Zomboid Build 42.13.1+")
        TooltipLib._hookStatus.item = "ISToolTipInv.render not found"
        return
    end

    -- Shared state across Layout-family surface hooks
    local frameCounter = 0
    local L1_REFRESH_INTERVAL = 60

    -- First-render API probe state (shared — only need to probe once)
    local apiProbed = false
    local apiDisabled = false

    -- Context table pool: reuse tables across frames to reduce GC pressure.
    -- Each entry is a raw table; reset and refill per dispatch call.
    local ctxPool = {}
    local ctxPoolSize = 0

    -- ================================================================
    -- InventoryContainer icon-preview restorer
    -- ================================================================
    -- Vanilla ISToolTipInv.render → item:DoTooltip(tooltip) (1-arg) draws
    -- an icon strip of contained items at the bottom of backpack/handbag
    -- tooltips (InventoryContainer.java:155). Our hook routes through
    -- DoTooltipEmbedded → DoTooltip(tooltip, layout) (2-arg), which for
    -- InventoryContainer only adds Capacity/Weight Reduction/Max Item Size
    -- and never draws the preview. Reproduce the icon row so consumer mods
    -- don't silently strip the preview from container tooltips.
    local function drawContainerPreview(tooltipItem, tooltip, endY, width)
        if not instanceof(tooltipItem, "InventoryContainer") then return endY, width end
        local cont = tooltipItem:getItemContainer()
        if not cont then return endY, width end
        local items = cont:getItems()
        if not items or items:isEmpty() then return endY, width end

        if width < 160 then width = 160 end
        local padLeft = tooltip.padLeft or 5
        local padRight = tooltip.padRight or 5
        local font = tooltip:getFont()
        local iconSize = math.max(16, getTextManager():getFontHeight(font))
        local x = padLeft
        local y = endY + 4
        local maxX = width - padRight
        local seen = {}

        for i = items:size() - 1, 0, -1 do
            local item = items:get(i)
            local name = item:getName()
            if not name or not seen[name] then
                if name then seen[name] = true end
                tooltip:DrawTextureScaledAspect(item:getTex(), x, y,
                    iconSize, iconSize, 1.0, 1.0, 1.0, 1.0)
                x = x + iconSize + 1
                if x + iconSize > maxX then break end
            end
        end
        return y + iconSize, width
    end

    -- ================================================================
    -- Layout row geometry (for the panel dress's ornaments hook)
    -- ================================================================
    -- RECONSTRUCTED, never read back: the Java Layout's fields are NOT
    -- Lua-exposed (layout.items indexes as nil in-game — only the inner
    -- class's METHODS work; the 2026-07-03 error-spam lesson). Geometry
    -- comes from what the ctx methods NOTED at declare time
    -- (sectionState.meta: kind, measured widths, bar fraction/colour) plus
    -- the rendered layout's end Y:
    --   * provider rows are the layout's LAST #meta rows, each exactly one
    --     lineSpacing tall (every ctx-added row is single-line — addText
    --     pre-splits, and LayoutItem heights are lines*lineSpacing)
    --   * the value column's RIGHT edge is width - padRight BY
    --     CONSTRUCTION: the pre-render alignment pass (setMinValueWidth)
    --     right-aligns values to the tooltip's edge
    --   * midX comes from the same layoutStats that alignment pass measures
    -- Vanilla's own rows (DoTooltipEmbedded) are not described — ornaments
    -- cover the provider region only.
    local function buildLayoutGeometry(sectionState, left, topY, endYLayout,
                                       lineSpacing, width, padRight, layoutStats)
        local meta = sectionState.meta
        local n = #meta
        if n == 0 then return nil end
        local padX = math.max(
            layoutStats.tm:MeasureStringX(layoutStats.font, "W"), 8)
        local startProv = endYLayout - n * lineSpacing
        local rows = {}
        for i = 1, n do
            local m = meta[i]
            rows[i] = {
                y = startProv + (i - 1) * lineSpacing,
                h = lineSpacing, kind = m.kind,
                labelW = m.labelW or 0, valueW = m.valueW or 0,
                fraction = m.fraction, barColor = m.barColor,
                provider = true,
            }
        end
        local sections = {}
        for si = 1, #sectionState.list do
            local s = sectionState.list[si]
            local r = rows[s.index]
            if r then
                sections[#sections + 1] = {
                    y = r.y, h = r.h, label = s.label,
                    labelW = r.labelW, rowIndex = s.index,
                }
            end
        end
        return {
            left = left, startY = startProv, endY = endYLayout,
            -- top of the WHOLE layout (vanilla's rows included): their
            -- contents can't be read back, but a skin's row RULING only
            -- needs the line grid, which starts here
            top = topY,
            lineSpacing = lineSpacing,
            midX = left + layoutStats.maxLabelWithValue + padX,
            valueRightX = width - padRight,
            -- vanilla's progress-bar height by tooltip font (LayoutItem.render)
            barH = (layoutStats.fontSize == "Large" and 7)
                or (layoutStats.fontSize == "Medium" and 6) or 5,
            rows = rows, sections = sections,
        }
    end

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
    -- @param dressSpec         table|nil — active panel dress; its presence
    --                          (with an ornaments hook) switches beginSection
    --                          to dressed mode and enables the geometry walk
    local function doLayoutDispatch(tooltipItem, tooltip, activeProviders, detailHeld, surfaceName, extraFields, fallbackDoTooltip, deferStartY, hasHiddenDetail, dressSpec)

        -- Measure pass detection: ISToolTipInv/ISToolTipItemSlot.render call
        -- DoTooltip TWICE per render — first with setMeasureOnly(true) to size
        -- the tooltip, then (after repositioning) with measureOnly off to draw.
        -- PZ's Layout.render honors measureOnly and skips its own draws, but our
        -- direct-draw phases (textures, container preview, postRender accent bars,
        -- detail hint, overflow indicator) do NOT — so without this guard they
        -- paint during the measure pass too. The measure-pass position differs
        -- from the final position (context menus and world-object menus reposition
        -- via adjustPositionToAvoidOverlap between the two calls), producing a
        -- second, mislocated tooltip box / accent bar. Run measurement + state
        -- phases in both passes, but defer all pixel drawing to the real pass.
        local measureOnly = false
        pcall(function() measureOnly = tooltip:isMeasureOnly() end)

        -- Build per-provider context tables from pool.
        -- Each provider gets its own mutable context so preTooltip can
        -- stash state for cleanup (e.g., saved clip size).
        local resetTable = TooltipLib._resetTable
        local providerCount = #activeProviders
        -- Grow pool if needed
        for i = ctxPoolSize + 1, providerCount do
            ctxPool[i] = {}
            ctxPoolSize = i
        end
        -- Accent channel: providers declare the theme-line colour via
        -- ctx:setAccentColor (callback or postRender; last write wins). The
        -- caller draws the classic bar / feeds the panel dress from the
        -- returned colour.
        local accentState = { color = nil }
        -- Section channel: beginSection records each declared section here
        -- (rows = exact count of layout items the provider region added).
        -- `dressed` switches beginSection to omit its plain divider row —
        -- the dress's ornaments hook draws the rule from the geometry
        -- instead. `labelColor` lets the dress style section labels at
        -- declare time.
        local sectionState = {
            meta = {},
            list = {},
            dressed = (dressSpec and type(dressSpec.ornaments) == "function")
                and true or false,
            labelColor = dressSpec and dressSpec.sectionLabelColor or nil,
        }
        local contexts = {}
        for i = 1, providerCount do
            local ctx = resetTable(ctxPool[i])
            ctx.item = tooltipItem
            ctx.tooltip = tooltip
            ctx.detail = detailHeld
            ctx.surface = surfaceName
            ctx._accentState = accentState
            ctx._sectionState = sectionState
            setmetatable(ctx, TooltipLib._ContextMT)
            if extraFields then
                for k, v in pairs(extraFields) do
                    ctx[k] = v
                end
            end
            contexts[i] = ctx
        end
        -- Nil out stale entries beyond current provider count
        for i = providerCount + 1, ctxPoolSize do
            ctxPool[i] = resetTable(ctxPool[i])
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
        -- PHASE 2: Split layout — vanilla + provider in chained sections
        -- ================================================================
        local padLeft = tooltip.padLeft or 5
        local padRight = tooltip.padRight or 5
        local padBottom = tooltip.padBottom or 5
        local padTop = tooltip.padTop or 5

        -- Vanilla-row replacement: an active provider CLAIMS the embedded
        -- vanilla rows for this item (it re-emits what it owns through ctx).
        -- DoTooltipEmbedded is skipped; the name line — which vanilla draws
        -- inside the embed — is drawn by the framework instead, so a
        -- replacing provider never has to fake the header.
        local replacing = false
        for i = 1, providerCount do
            if activeProviders[i].replacesVanilla then replacing = true; break end
        end

        local endY = 0
        local width = 0
        local geom = nil
        local replaceNameW = 0
        local layoutOk, layoutErr = pcall(function()
            local lineSpacing = 14
            pcall(function()
                lineSpacing = tooltip:getLineSpacing() or 14
            end)

            local startY
            if deferStartY then
                startY = deferStartY
            else
                startY = padTop + lineSpacing
            end

            -- In defer mode, capture the foreign framework's width before
            -- beginLayout so we can preserve it if ours is narrower
            local foreignWidth = deferStartY and tooltip:getWidth() or 0

            -- Unified layout: vanilla and provider items share one Layout
            -- so column widths (mid, widthValueRight) are computed across
            -- all rows. This ensures progress bars from providers align
            -- with vanilla's bars in both position and size.
            local vanillaLayout, providerLayout
            if deferStartY then
                providerLayout = tooltip:beginLayout()
            else
                vanillaLayout = tooltip:beginLayout()
                if replacing then
                    -- claimed: no vanilla rows. Draw the name line where the
                    -- embed would have (same spot, vanilla's warm-white ink;
                    -- real pass only — the measure pass just sizes it).
                    pcall(function()
                        local nm = tooltipItem:getName()
                        if nm and nm ~= "" then
                            local font = tooltip:getFont()
                            if not measureOnly then
                                tooltip:DrawText(font, nm, padLeft, padTop,
                                    1.0, 1.0, 0.8, 1.0)
                            end
                            replaceNameW = padLeft +
                                getTextManager():MeasureStringX(font, nm) + padRight
                        end
                    end)
                else
                    tooltipItem:DoTooltipEmbedded(tooltip, vanillaLayout, 0)
                end
                -- Provider items go into the SAME layout as vanilla
                providerLayout = vanillaLayout
            end

            local callbackCache = TooltipLib._callbackCache
            local currentItemId = tooltipItem:getID()

            -- Auto-separator: track whether previous provider added content
            local prevAddedContent = false

            -- Layout stats accumulator: each ctx:add* helper records its
            -- label/value text widths here, so we can compute the right
            -- setMinValueWidth before render to align all values to the
            -- tooltip's right edge regardless of label-only-row width.
            -- Match ObjectTooltip's actual font (configurable via Core option).
            local ttFont = UIFont.Small
            local ttFontSize = "Small"
            pcall(function()
                local opt = Core.getInstance():getOptionTooltipFont()
                if opt == "Large" then ttFont = UIFont.Large; ttFontSize = "Large"
                elseif opt == "Medium" then ttFont = UIFont.Medium; ttFontSize = "Medium"
                end
            end)
            local layoutStats = {
                tm = getTextManager(),
                font = ttFont,
                fontSize = ttFontSize,
                maxLabelWithValue = 0,
                maxValueCol = 0,
                maxLabelOnly = 0,
            }

            for i = 1, #activeProviders do
                local p = activeProviders[i]
                contexts[i].layout = providerLayout
                contexts[i].helpers = TooltipLib.Helpers
                contexts[i]._layoutStats = layoutStats

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

            -- Pre-render alignment pass: PZ's Layout.render computes
            -- widthTotal from label-only rows separately from widthValueRight,
            -- so a wide description row (addText) at the bottom widens the
            -- tooltip but doesn't push key/value rows' values to the new
            -- right edge. Use the recorded layoutStats to compute the right
            -- setMinValueWidth so values right-align with the full width.
            local renderLayout = vanillaLayout or providerLayout
            pcall(function()
                local padX = math.max(
                    layoutStats.tm:MeasureStringX(layoutStats.font, "W"), 8)
                local valueRowsTotal = layoutStats.maxLabelWithValue + padX +
                    layoutStats.maxValueCol
                TooltipLib._debugLog(string.format(
                    "preAlign: midLabel=%d valCol=%d labelOnly=%d valTotal=%d",
                    layoutStats.maxLabelWithValue, layoutStats.maxValueCol,
                    layoutStats.maxLabelOnly, valueRowsTotal))
                if layoutStats.maxLabelOnly > valueRowsTotal then
                    local newMinVal = layoutStats.maxLabelOnly -
                        layoutStats.maxLabelWithValue - padX
                    TooltipLib._debugLog("preAlign: setMinValueWidth(" .. newMinVal .. ")")
                    renderLayout:setMinValueWidth(newMinVal)
                end
            end)
            endY = renderLayout:render(padLeft, startY, tooltip)
            local endYLayout = endY   -- before the detail hint advances it
            tooltip:endLayout(renderLayout)

            -- Compute effective minimum width from provider requests (and
            -- the framework-drawn name line when vanilla rows are claimed —
            -- the embed's adjustWidth would normally account for it)
            local effectiveMinWidth = 150
            if replaceNameW > effectiveMinWidth then
                effectiveMinWidth = replaceNameW
            end
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

            -- Detail hint: "[<key>] Details" right-aligned when extra
            -- content is available but the detail key isn't held. Key name
            -- reflects the configured detail modifier (not hardcoded Shift).
            if hasHiddenDetail and not detailHeld then
                if not measureOnly then
                    local detailKeyName = "Shift"
                    pcall(function()
                        detailKeyName = getKeyName(TooltipLib._getDetailKeyCode()) or "Shift"
                    end)
                    tooltip:DrawTextRight(UIFont.Small, "[" .. detailKeyName .. "] Details",
                        width - padRight, endY - 2,
                        0.55, 0.55, 0.55, 0.5)
                end
                -- Advance endY in both passes so the measured height reserves
                -- room for the hint line even though it's only drawn for real.
                endY = endY + lineSpacing
            end

            -- Row geometry for the ornaments hook — reconstructed from the
            -- declare-time notes (see buildLayoutGeometry above; width is
            -- final here). Inner pcall: a geometry failure must not take
            -- down the layout — ornaments just don't draw.
            if sectionState.dressed then
                pcall(function()
                    geom = buildLayoutGeometry(sectionState, padLeft, startY,
                        endYLayout, lineSpacing, width, padRight, layoutStats)
                end)
            end
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
        if layoutOk and not measureOnly then
            endY = TooltipLib._processTextureQueue(
                contexts, activeProviders, tooltip, endY, width, padLeft, padRight)
        end

        -- ================================================================
        -- PHASE 2.6: InventoryContainer icon preview
        -- ================================================================
        -- Skipped in deferred mode: the foreign tooltip framework already
        -- rendered (or chose not to render) the vanilla container preview.
        if layoutOk and not deferStartY and not measureOnly then
            local pOk, pY, pW = pcall(drawContainerPreview, tooltipItem, tooltip, endY, width)
            if pOk then
                if type(pY) == "number" then endY = pY end
                if type(pW) == "number" then width = pW end
            end
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

        -- postRender draws directly to the tooltip (accent bars, etc.), so it
        -- must only run on the real draw pass — never the measure pass, or the
        -- drawing is duplicated at the pre-reposition location.
        if not measureOnly then
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
            if wasCapped and not measureOnly then
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

        if geom then geom.width = width end
        return accentState.color, geom
    end

    -- ================================================================
    -- Accent line: framework-drawn from the accent channel
    -- ================================================================
    -- One bar, drawn once by the framework (real pass only) — providers
    -- declare the colour instead of each painting over the other's bar.
    -- Skipped while a panel dress is active: the dress integrates the
    -- accent itself (a straight bar would cut across its corners).
    local function drawAccentLine(tooltip, color)
        if not color then return end
        pcall(function()
            if tooltip:isMeasureOnly() then return end
            local h = tooltip:getHeight()
            if h and h > 2 then
                tooltip:DrawTextureScaledColor(nil, 1, 1, 2, h - 2,
                    color[1], color[2], color[3], color[4] or 1)
            end
        end)
    end

    -- ================================================================
    -- Deferred mode background helper
    -- ================================================================
    -- Draws the background + border extension for provider content
    -- appended below a foreign framework's tooltip. Uses the ISPanel's
    -- backgroundColor/borderColor to match the active theme.
    --
    -- Seam handling: the foreign framework above may paint its own bg
    -- overlay at a different alpha than panel.backgroundColor. Drawing
    -- our extension at full alpha right at foreignH creates a visible
    -- horizontal seam. We feather the top FEATHER_PX rows of our bg
    -- from alpha 0 → bg.a so the transition is gradual instead of hard.
    --
    -- @param panel       ISToolTipInv or ISToolTipItemSlot (ISPanel)
    -- @param foreignH    Height set by the foreign framework
    -- @param totalH      Total height including our provider content
    -- @param totalW      Total width of the tooltip
    local FEATHER_PX = 5
    local function drawDeferredBackground(panel, foreignH, totalH, totalW)
        if totalH <= foreignH then return end
        local bg = panel.backgroundColor
        local bd = panel.borderColor
        if not bg or not bd then return end
        -- Erase old bottom border (replace with background)
        panel:drawRect(1, foreignH - 1, totalW - 2, 1,
            bg.a, bg.r, bg.g, bg.b)
        -- Feathered top edge: gradient from transparent to bg.a over
        -- FEATHER_PX rows, hiding alpha mismatch with foreign bg above.
        local featherEnd = math.min(foreignH + FEATHER_PX, totalH)
        for y = foreignH, featherEnd - 1 do
            local t = (y - foreignH + 1) / FEATHER_PX
            panel:drawRect(0, y, totalW, 1, bg.a * t, bg.r, bg.g, bg.b)
        end
        -- Solid background fill below the feathered region
        if featherEnd < totalH then
            panel:drawRect(0, featherEnd, totalW, totalH - featherEnd,
                bg.a, bg.r, bg.g, bg.b)
        end
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
    local inv_cachedHasHiddenDetail = false
    -- Deferred mode: cached dimensions from previous frame
    local inv_deferCachedH = 0
    local inv_deferCachedW = 0
    -- Foreign owner: a framework replaced DoTooltip (deferred or stand-down)
    -- last frame — its panel builds on the vanilla box, so the dress must not
    -- suppress it. Self-corrects the frame our wrapper fires again.
    local inv_foreignOwner = false
    -- Accent channel cache: the dress paints before providers run, so it
    -- reads the accent THEY declared last frame (keyed by item id).
    local inv_accentId = nil
    local inv_accentColor = nil

    ISToolTipInv.render = function(self)
        local item = self.item
        local providers = TooltipLib._getProvidersForTarget("item")

        frameCounter = frameCounter + 1

        -- Panel dress: resolved before the fast exits — a dress must engage
        -- on EVERY tooltip, including items no provider is active for.
        local dressSpec = item and TooltipLib._resolvePanelDress("item") or nil

        -- Fast exit: no item, nothing to add, or item lacks standard API
        if not item or (#providers == 0 and not dressSpec) then
            original_render(self)
            return
        end
        if not pcall(item.getID, item) then
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
        local hasHiddenDetail = false
        local l1Stale = (frameCounter - inv_cachedL1Frame) >= L1_REFRESH_INTERVAL

        if itemId == inv_cachedItemId
            and providerVersion == inv_cachedProviderVersion
            and detailHeld == inv_cachedDetailState
            and not l1Stale then
            activeProviders = inv_cachedActiveProviders
            hasHiddenDetail = inv_cachedHasHiddenDetail or false
            TooltipLib._debugLog("L1 cache hit (item " .. itemId .. ")")
        else
            -- Cache miss: evaluate enabled() for all providers
            if l1Stale and itemId == inv_cachedItemId then
                TooltipLib._debugLog("L1 periodic refresh (item " .. itemId .. ")")
            else
                TooltipLib._debugLog("L1 cache miss (item " .. itemId .. ")")
            end
            activeProviders, hasHiddenDetail = TooltipLib._evaluateProviders(providers, detailHeld, item)

            inv_cachedItemId = itemId
            inv_cachedProviderVersion = providerVersion
            inv_cachedActiveProviders = activeProviders
            inv_cachedDetailState = detailHeld
            inv_cachedHasHiddenDetail = hasHiddenDetail
            inv_cachedL1Frame = frameCounter
        end

        -- No active providers -> vanilla path, unless a dress is on: the
        -- dress still needs the DoTooltip wrapper to paint under vanilla's
        -- own layout draw.
        if not activeProviders and not dressSpec then
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
            -- Dress first, real pass only (helper skips the measure pass):
            -- lands over the suppressed flat box at the post-reposition
            -- location, under everything the layout render draws. The accent
            -- is the one providers declared LAST frame (the dress paints
            -- before they run; tooltips fade in over ~15 frames, so the one-
            -- frame catch-up is invisible).
            if dressSpec then
                local dressAccent = (inv_accentId == itemId) and inv_accentColor or nil
                TooltipLib._drawPanelDress(dressSpec, self, tooltip, nil, nil, "item", dressAccent)
            end
            if activeProviders then
                local accent, geom = doLayoutDispatch(tooltipItem, tooltip, activeProviders, detailHeld,
                    "item", nil, original_DoTooltip, nil, hasHiddenDetail, dressSpec)
                -- Accent cache discipline per pass: the real pass always
                -- writes (truth). The measure pass writes only NON-NIL — a
                -- callback-declared accent (recommended: it's a pure type/
                -- tier read) lands in the cache BEFORE this same render's
                -- real pass, so the dress paints the right rail with no
                -- first-frame flash; but a nil (postRender declarers set
                -- nothing during measure) must not blank the cache right
                -- before the real-pass dress reads it.
                local measuring = false
                pcall(function() measuring = tooltip:isMeasureOnly() end)
                if not measuring then
                    inv_accentId, inv_accentColor = itemId, accent
                    -- classic bar only when undressed — a dressed card
                    -- integrates the accent (rail tint) instead
                    if not dressSpec then
                        drawAccentLine(tooltip, accent)
                    elseif geom then
                        -- row-anchored flourishes (section rules, leader
                        -- dots): same-frame geometry, drawn over the card,
                        -- under nothing — rules and dots live in the gaps
                        TooltipLib._drawPanelOrnaments(dressSpec, self,
                            tooltip, geom, "item", accent)
                    end
                elseif accent ~= nil then
                    inv_accentId, inv_accentColor = itemId, accent
                end
            else
                -- Dress-only frame: no provider content, vanilla renders
                original_DoTooltip(tooltipItem, tooltip)
                -- The skin can still RULE the card body: a rows-less
                -- geometry (line grid only — top/lineSpacing/extent) is
                -- enough for feint ledger ruling on pure-vanilla tooltips.
                if dressSpec and type(dressSpec.ornaments) == "function" then
                    local measuring = false
                    pcall(function() measuring = tooltip:isMeasureOnly() end)
                    if not measuring then
                        pcall(function()
                            local ls = tooltip:getLineSpacing() or 14
                            local w = tooltip:getWidth()
                            local h = tooltip:getHeight()
                            local pT = tooltip.padTop or 5
                            local pB = tooltip.padBottom or 5
                            local pL = tooltip.padLeft or 5
                            local pR = tooltip.padRight or 5
                            local bottom = h - pB
                            TooltipLib._drawPanelOrnaments(dressSpec, self, tooltip, {
                                left = pL, top = pT + ls,
                                startY = bottom, endY = bottom,
                                lineSpacing = ls, width = w,
                                midX = 0, valueRightX = w - pR,
                                rows = {}, sections = {},
                            }, "item", (inv_accentId == itemId) and inv_accentColor or nil)
                        end)
                    end
                end
            end
        end

        -- Snapshot the ObjectTooltip's identity + height before the render
        -- chain. The deferred branch below uses this to tell whether the
        -- foreign renderer actually rendered THROUGH self.tooltip this frame.
        -- Mods that REPLACE ISToolTipInv.render and draw their own panel
        -- directly (e.g. Extensive Health Rework) never touch self.tooltip;
        -- deferring onto its stale height stacks our content on our own prior
        -- output every frame = unbounded vertical growth.
        local preTooltip = self.tooltip
        local preTooltipH = -1
        if preTooltip then pcall(function() preTooltipH = preTooltip:getHeight() end) end

        -- While the dress is on, silence vanilla's flat box for this render:
        -- the bg fill and square border would peek out behind the dress's
        -- rounded corners (same reason the window dress zeroes borderColor).
        -- Alphas are restored right after the chain — the fields are shared
        -- vanilla state. Skipped while a foreign framework owns the panel:
        -- its box IS the vanilla one we'd be blanking.
        local supBgA, supBdA
        if dressSpec and not inv_foreignOwner then
            pcall(function()
                if self.backgroundColor then
                    supBgA = self.backgroundColor.a
                    self.backgroundColor.a = 0
                end
                if self.borderColor then
                    supBdA = self.borderColor.a
                    self.borderColor.a = 0
                end
            end)
        end

        -- Call the next render in the chain (vanilla, SWSP, AMS, etc.).
        -- When it calls item:DoTooltip(), our wrapper above fires.
        -- pcall-wrapped so the metatable is ALWAYS restored, even on error.
        local renderOk, renderErr = pcall(original_render, self)

        -- Restore original DoTooltip on the metatable (must always run)
        itemMetatable.DoTooltip = original_DoTooltip

        -- Restore the vanilla box alphas (must always run; deferred-mode
        -- drawing below reads these fields)
        if supBgA ~= nil or supBdA ~= nil then
            pcall(function()
                if supBgA ~= nil then self.backgroundColor.a = supBgA end
                if supBdA ~= nil then self.borderColor.a = supBdA end
            end)
        end

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
            -- A foreign framework owns this tooltip's panel: never dress it,
            -- and stop suppressing the vanilla box it builds on (next frame).
            inv_foreignOwner = true

            -- Stand-down guard (anti-runaway): if the ObjectTooltip was NOT
            -- touched during the render chain (same reference AND same height),
            -- the foreign renderer bypassed it entirely and drew its own panel.
            -- There is no foreign ObjectTooltip content to append below, and
            -- deferring would read back the height we set last frame → grow
            -- without bound. Leave the foreign render intact and add nothing.
            -- Legit deferred hosts (Starlit, AMS) re-render self.tooltip every
            -- frame, so its height changes from our prior write → not detected.
            if self.tooltip == preTooltip then
                local postTooltipH = -1
                pcall(function() postTooltipH = self.tooltip:getHeight() end)
                if postTooltipH == preTooltipH then
                    TooltipLib._logOnce("deferred_standdown",
                        "Foreign renderer replaced ISToolTipInv.render and drew " ..
                        "its own panel (bypassed the ObjectTooltip). Standing " ..
                        "down to prevent unbounded tooltip growth; provider " ..
                        "content is suppressed for items it fully owns.")
                    inv_deferCachedH = 0
                    inv_deferCachedW = 0
                    return
                end
            end

            -- Dress-only frames have no provider content to append below the
            -- foreign framework's output — nothing to defer.
            if not activeProviders then
                inv_deferCachedH = 0
                inv_deferCachedW = 0
                return
            end

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
            local accent = doLayoutDispatch(self.item, tooltip, activeProviders, detailHeld,
                "item", nil, nil, deferStartY, hasHiddenDetail)
            drawAccentLine(tooltip, accent)

            -- Cache total dimensions for next frame's background pre-draw
            inv_deferCachedH = tooltip:getHeight()
            inv_deferCachedW = math.max(foreignW, tooltip:getWidth())

            -- Sync ISPanel dimensions so positioning calculations work
            self:setHeight(inv_deferCachedH)
            self:setWidth(inv_deferCachedW)
        else
            -- Our wrapper fired: the panel is ours again (re-arm the dress's
            -- vanilla-box suppression). Render-chain errors leave the flag.
            if ourWrapperFired then inv_foreignOwner = false end
            inv_deferCachedH = 0
            inv_deferCachedW = 0
        end
    end

    TooltipLib._hookStatus.item = true
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
        -- Foreign owner (see ISToolTipInv hook): don't dress / don't suppress
        -- the vanilla box while a foreign framework owns the panel.
        local slot_foreignOwner = false
        -- Accent channel cache (see ISToolTipInv hook)
        local slot_accentId = nil
        local slot_accentColor = nil

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

            -- Panel dress (see ISToolTipInv hook: engages with or without
            -- active providers)
            local dressSpec = TooltipLib._resolvePanelDress("itemSlot")

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

            if (not mergedProviders or #mergedProviders == 0) and not dressSpec then
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

            if not activeProviders and not dressSpec then
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
                -- Dress first, real pass only (see ISToolTipInv hook)
                if dressSpec then
                    local dressAccent = (slot_accentId == itemId) and slot_accentColor or nil
                    TooltipLib._drawPanelDress(dressSpec, self, tooltip, nil, nil, "itemSlot", dressAccent)
                end
                if activeProviders then
                    local accent, geom = doLayoutDispatch(tooltipItem, tooltip, activeProviders, detailHeld,
                        "itemSlot", { itemSlot = itemSlotRef }, original_DoTooltip, nil, nil, dressSpec)
                    -- real pass writes truth; measure pass warms non-nil
                    -- (see ISToolTipInv hook)
                    local measuring = false
                    pcall(function() measuring = tooltip:isMeasureOnly() end)
                    if not measuring then
                        slot_accentId, slot_accentColor = itemId, accent
                        if not dressSpec then
                            drawAccentLine(tooltip, accent)
                        elseif geom then
                            TooltipLib._drawPanelOrnaments(dressSpec, self,
                                tooltip, geom, "itemSlot", accent)
                        end
                    elseif accent ~= nil then
                        slot_accentId, slot_accentColor = itemId, accent
                    end
                else
                    original_DoTooltip(tooltipItem, tooltip)
                    -- rows-less geometry for the skin's ruling (see the
                    -- ISToolTipInv dress-only branch)
                    if dressSpec and type(dressSpec.ornaments) == "function" then
                        local measuring = false
                        pcall(function() measuring = tooltip:isMeasureOnly() end)
                        if not measuring then
                            pcall(function()
                                local ls = tooltip:getLineSpacing() or 14
                                local w = tooltip:getWidth()
                                local h = tooltip:getHeight()
                                local bottom = h - (tooltip.padBottom or 5)
                                TooltipLib._drawPanelOrnaments(dressSpec, self, tooltip, {
                                    left = tooltip.padLeft or 5,
                                    top = (tooltip.padTop or 5) + ls,
                                    startY = bottom, endY = bottom,
                                    lineSpacing = ls, width = w,
                                    midX = 0, valueRightX = w - (tooltip.padRight or 5),
                                    rows = {}, sections = {},
                                }, "itemSlot", (slot_accentId == itemId) and slot_accentColor or nil)
                            end)
                        end
                    end
                end
            end

            -- Snapshot ObjectTooltip identity + height (see ISToolTipInv hook):
            -- detect foreign renderers that bypass self.tooltip and would cause
            -- unbounded growth in the deferred branch below.
            local preTooltip = self.tooltip
            local preTooltipH = -1
            if preTooltip then pcall(function() preTooltipH = preTooltip:getHeight() end) end

            -- Silence vanilla's flat box while the dress is on (see the
            -- ISToolTipInv hook for the reasoning + foreign-owner exception)
            local supBgA, supBdA
            if dressSpec and not slot_foreignOwner then
                pcall(function()
                    if self.backgroundColor then
                        supBgA = self.backgroundColor.a
                        self.backgroundColor.a = 0
                    end
                    if self.borderColor then
                        supBdA = self.borderColor.a
                        self.borderColor.a = 0
                    end
                end)
            end

            local renderOk, renderErr = pcall(original_slot_render, self)

            -- Restore original DoTooltip (must always run)
            itemMetatable.DoTooltip = original_DoTooltip

            -- Restore the vanilla box alphas (must always run)
            if supBgA ~= nil or supBdA ~= nil then
                pcall(function()
                    if supBgA ~= nil then self.backgroundColor.a = supBgA end
                    if supBdA ~= nil then self.borderColor.a = supBdA end
                end)
            end

            if not renderOk then
                TooltipLib._logOnce("slot_render_chain_error",
                    "ItemSlot render chain error: " .. tostring(renderErr))
            end

            -- Deferred path (same pattern as ISToolTipInv)
            if not ourSlotWrapperFired and renderOk and self.tooltip then
                slot_foreignOwner = true

                -- Stand-down guard (anti-runaway) — see ISToolTipInv hook.
                if self.tooltip == preTooltip then
                    local postTooltipH = -1
                    pcall(function() postTooltipH = self.tooltip:getHeight() end)
                    if postTooltipH == preTooltipH then
                        TooltipLib._logOnce("slot_deferred_standdown",
                            "Foreign renderer bypassed the ObjectTooltip; " ..
                            "standing down to prevent unbounded tooltip growth.")
                        slot_deferCachedH = 0
                        slot_deferCachedW = 0
                        return
                    end
                end

                -- Dress-only frames: nothing to defer below foreign content
                if not activeProviders then
                    slot_deferCachedH = 0
                    slot_deferCachedW = 0
                    return
                end

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

                local accent = doLayoutDispatch(self.item, tooltip, activeProviders, detailHeld,
                    "itemSlot", { itemSlot = itemSlotRef }, nil, deferStartY)
                drawAccentLine(tooltip, accent)

                slot_deferCachedH = tooltip:getHeight()
                slot_deferCachedW = math.max(foreignW, tooltip:getWidth())
                self:setHeight(slot_deferCachedH)
                self:setWidth(slot_deferCachedW)
            else
                if ourSlotWrapperFired then slot_foreignOwner = false end
                slot_deferCachedH = 0
                slot_deferCachedW = 0
            end
        end

        TooltipLib._hookStatus.itemSlot = true
        TooltipLib._log("ISToolTipItemSlot hook installed (" ..
            TooltipLib.getProviderCount("itemSlot") .. " slot providers, " ..
            TooltipLib.getProviderCount("item") .. " item providers auto-applied)")
    end
end

Events.OnGameStart.Add(InstallHook)

TooltipLib._log("Hook module loaded")
