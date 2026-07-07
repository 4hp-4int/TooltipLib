-- ============================================================================
-- TooltipLib StarlitAdapter — native integration with StarlitLibrary
-- ============================================================================
-- StarlitLibrary owns the item tooltip the same way TooltipLib does: it wraps
-- ISToolTipInv.render, rebuilds the card through the vanilla Layout, and — the
-- part that matters — fires InventoryUI.onFillItemTooltip(tooltip, layout, item)
-- so other mods can add rows to ITS layout, rendered in one pass with an
-- authoritative height (Starlit InventoryUI.lua).
--
-- That event is exactly the content-append protocol the deferred path has to
-- INFER (extent memos, thrash clamp, EHR stand-down). So when Starlit is
-- present we stop inferring: this adapter registers ONE listener on
-- onFillItemTooltip that runs TooltipLib's active item providers with their
-- context bound to Starlit's own layout (ctx methods delegate to ctx.layout),
-- so provider content lands NATIVELY in Starlit's card — correct alignment,
-- one render pass, no stapling, no guesswork.
--
-- Doctrine: they own the card, we're a well-behaved data provider in their
-- layout. No kraft dress over Starlit's box (that's the fragile part we don't
-- attempt); Starlit-owned cards wear Starlit's skin with our data inside them,
-- plus our accent line (drawn by the Hook's render early-path at final height).
--
-- Scope (Tier 1): callback-phase content + accent. preTooltip/postRender
-- provider phases don't run here (Starlit adds the vanilla rows before the
-- event, and renders after it — there's no correct point for them without
-- patching Starlit's internals). replacesVanilla providers stand down:
-- Starlit already emitted the vanilla rows, re-emitting would duplicate them.

require "TooltipLib/Core"
require "TooltipLib/Helpers"

-- One shared section-state shape per run keeps beginSection working (label +
-- inline rule, since there's no ornament hook on Starlit's single-pass card).
local function freshSectionState()
    return { list = {}, meta = {}, dressed = false }
end

--- The onFillItemTooltip listener: run active item providers into Starlit's
--- layout. Stashes the declared accent for the Hook render path to draw at
--- the final (post-render) height.
local function fillFromProviders(tooltip, layout, item)
    -- Mark that Starlit's onFillItemTooltip actually reached us this render.
    -- The Hook's Starlit branch resets this to false before running the render
    -- chain; if it's still false afterward, another mod owned the render and
    -- bypassed Starlit's wrapper, so the Hook falls back to a deferred append
    -- rather than silently dropping provider content.
    TooltipLib._starlitFillFired = true
    TooltipLib._starlitAccent = nil
    TooltipLib._starlitDressed = false
    if not (item and layout) then return end

    -- Run our active item providers INTO Starlit's layout (if any). The skin
    -- and accent below run regardless — an item with only vanilla + Starlit
    -- content still wears the kraft card when the skin is on (consistency).
    local accentState = { color = nil }
    local providers = TooltipLib._getProvidersForTarget("item")
    if providers and #providers > 0 then
        local detailHeld = false
        pcall(function() detailHeld = TooltipLib._readDetailKey() end)
        local active = TooltipLib._evaluateProviders(providers, detailHeld, item)
        if active then
            for i = 1, #active do
                local p = active[i]
                -- Starlit already added the vanilla rows via DoTooltipEmbedded;
                -- a full-card claimer would re-emit them = duplicate. Stand down.
                if not p.replacesVanilla and type(p.callback) == "function" then
                    local ctx = setmetatable({
                        item = item,
                        tooltip = tooltip,
                        detail = detailHeld,
                        surface = "item",
                        layout = layout,
                        helpers = TooltipLib.Helpers,
                        _accentState = accentState,
                        _sectionState = freshSectionState(),
                        ornamented = false,   -- no ornament hook under Starlit
                    }, TooltipLib._ContextMT)
                    local ok, err = pcall(p.callback, ctx)
                    if not ok then
                        TooltipLib._log("Provider '" .. tostring(p.id) ..
                            "' callback error under Starlit adapter: " .. tostring(err))
                        TooltipLib._recordError(p.id)
                    else
                        -- Reset the circuit breaker on success, mirroring the
                        -- owned render path (Hook.lua:502). WITHOUT this, the
                        -- Starlit path only ever RECORDS errors — a provider
                        -- that throws even occasionally accumulates cumulatively
                        -- to ERROR_THRESHOLD and gets latched `disabled` for the
                        -- whole Lua VM (surviving save-reloads), turning one bad
                        -- hover into a permanent, all-items tooltip blackout.
                        TooltipLib._recordSuccess(p.id)
                    end
                end
            end
        end
    end

    -- accent is declared during the callback; the Hook's render early-path
    -- draws the classic line at the tooltip's final height
    TooltipLib._starlitAccent = accentState.color

    -- OPTIONAL SKIN (mixedDress on): paint the registered dress's card body
    -- under Starlit's text. The real pass is the one window where the size
    -- is known (from the measure pass that ran first) and layout:render
    -- hasn't drawn text yet — so the kraft card lands UNDER everything, at
    -- the right size, with no patch to Starlit. Body + accent rail only:
    -- ornaments need row geometry we can't reconstruct here. Hook's early-
    -- path suppresses vanilla's box + skips the separate accent line when
    -- the skin is on (the rail carries the accent).
    if TooltipLib._starlitSkinWanted and TooltipLib._starlitSkinWanted() then
        local measuring = true
        pcall(function() measuring = tooltip:isMeasureOnly() end)
        local spec = TooltipLib._panelDress
        if not measuring and spec and type(spec.draw) == "function" then
            local w, h
            pcall(function() w = tooltip:getWidth(); h = tooltip:getHeight() end)
            if w and h and w > 0 and h > 0 then
                local ok = pcall(spec.draw, nil, tooltip, w, h, "item", accentState.color)
                if ok then TooltipLib._starlitDressed = true end
            end
        end
    end
end

--- Is the kraft skin wanted under Starlit? mixedDress option ON and a dress
--- registered whose active() (if any) passes. Default OFF = clean Starlit
--- card with our data (the consistent default the user settled on).
function TooltipLib._starlitSkinWanted()
    if not (TooltipLib._mixedDressAllowed and TooltipLib._mixedDressAllowed()) then
        return false
    end
    local spec = TooltipLib._panelDress
    if not spec then return false end
    if spec.active then
        local ok, on = pcall(spec.active)
        if not ok or not on then return false end
    end
    return true
end

--- Install: register on Starlit's event if present. Idempotent; safe when
--- StarlitLibrary is absent (does nothing).
local function installStarlitAdapter()
    if TooltipLib._starlitAdapter then return end
    local ok, InventoryUI = pcall(require, "Starlit/client/ui/InventoryUI")
    if not ok or type(InventoryUI) ~= "table" then return end
    local ev = InventoryUI.onFillItemTooltip
    if not ev or type(ev.addListener) ~= "function" then return end
    ev:addListener(fillFromProviders)
    TooltipLib._starlitAdapter = true
    TooltipLib._log("StarlitLibrary detected — native tooltip integration active " ..
        "(provider content flows into Starlit's card; the tooltip skin stands " ..
        "down for Starlit-owned cards).")
end

-- After InstallHook (both on OnGameStart, added later so it runs after).
Events.OnGameStart.Add(installStarlitAdapter)

TooltipLib._installStarlitAdapter = installStarlitAdapter
TooltipLib._starlitFill = fillFromProviders   -- exposed for tests
TooltipLib._log("StarlitAdapter module loaded")
