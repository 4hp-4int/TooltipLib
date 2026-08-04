--[[
    TooltipLib x MagicAccessories — render-slot reclaim cycle
    =========================================================
    MagicAccessories (WS 3760442018) monkey-patches ISToolTipInv.render with
    an "install late to win" reclaim loop: OnGameStart + OnCreatePlayer + a
    periodic OnPlayerUpdate check keep re-grabbing the slot (re-capturing
    whatever render is current as its fallback) until it owns it.

    When MagicAccessories' OnGameStart handler runs BEFORE TooltipLib's
    (mod-list order, no require= in its mod.info to force ours first):
      1. MA installs: fallback = vanilla, slot = customRender
      2. TL InstallHook: original_render = customRender, slot = TL wrapper
      3. MA reclaims:   fallback = TL wrapper,  slot = customRender
    Now TL's captured original and MA's captured fallback point at each
    other. MA's isRendering re-entry guard delegates to fallback — which IS
    the TL wrapper — so the guard feeds the cycle instead of breaking it:
    customRender -> TL -> customRender(guarded) -> TL -> ... stack overflow
    on the first hovered item (their file documents the same crash class
    with Global Storage SiK, WS 3750612158).

    This test loads the REAL Hook.lua, reproduces the exact install
    sequence with a faithful MagicAccessories sim, and locks the contract:
    the render chain must TERMINATE (cycle broken by TooltipLib) and still
    reach the boot-time render so the tooltip actually draws.
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"

if isClient == nil then function isClient() return false end end
if isServer == nil then function isServer() return false end end
if instanceof == nil then
    function instanceof(o, c) return type(o) == "table" and o._type == c end
end

-- ── vanilla-shaped ISToolTipInv mock (must exist BEFORE Hook.lua loads) ─────
ISToolTipInv = ISToolTipInv or {}
local savedRender = ISToolTipInv.render   -- restore for later files (shared VM)

local vanillaCalls = 0
local function vanillaImpl(self)
    vanillaCalls = vanillaCalls + 1
    local tt = self.tooltip
    tt:setWidth(50)
    tt:setMeasureOnly(true)
    if self.item then self.item:DoTooltip(tt) end
    tt:setMeasureOnly(false)
    if self.item then self.item:DoTooltip(tt) end
end

-- reset slot ownership to plain vanilla for this scenario, even if an
-- earlier test file left its own wrapper installed. Honor self._impl the
-- same way test_tooltiplib_dress.lua's dispatcher does: in a shared VM the
-- Hook's boot-time render snapshot is whichever file's dispatcher was
-- installed at Hook load, and both route through _impl to reach OUR
-- instrumented vanilla.
ISToolTipInv.render = function(self) return (self._impl or vanillaImpl)(self) end

require "TooltipLib/Core"
require "TooltipLib/Hook"

-- ── fixtures (same shapes as test_tooltiplib_dress.lua) ─────────────────────
local ItemProto = { _type = "InventoryItem" }
function ItemProto.DoTooltip(item, tooltip)
    item._doCalls = (item._doCalls or 0) + 1
    tooltip:setWidth(200)
    tooltip:setHeight(80)
end
function ItemProto.DoTooltipEmbedded(item, tooltip, layout, offset) end
function ItemProto.getID(item) return item._id end
function ItemProto.getName(item) return "Mock Item" end
local ItemMT = { __index = ItemProto }

local nextId = 77000
local function makeItem()
    nextId = nextId + 1
    return setmetatable({ _id = nextId }, ItemMT)
end

local function makeTT()
    local t = { _w = 0, _h = 0, _measure = false }
    function t.setWidth(self, w) self._w = w end
    function t.getWidth(self) return self._w end
    function t.setHeight(self, h) self._h = h end
    function t.getHeight(self) return self._h end
    function t.setX(self) end
    function t.setY(self) end
    function t.setMeasureOnly(self, b) self._measure = b end
    function t.isMeasureOnly(self) return self._measure end
    function t.getLineSpacing(self) return 14 end
    function t.beginLayout(self)
        local L = { _items = {} }
        function L.addItem(layout)
            local it = {}
            function it.setLabel(item) end
            function it.setValue(item) end
            function it.setValueRight(item) end
            function it.setProgress(item) end
            layout._items[#layout._items + 1] = it
            return it
        end
        function L.setMinValueWidth(layout) end
        function L.render(layout, x, y) return y + #layout._items * 14 end
        return L
    end
    function t.endLayout(self) end
    function t.getFont(self) return UIFont.Small end
    function t.DrawText(self) end
    function t.DrawTextRight(self) end
    function t.DrawTextureScaledColor(self) end
    return t
end

local function makePanel(item)
    return {
        item = item,
        _impl = vanillaImpl,   -- see the dispatcher comment above
        tooltip = makeTT(),
        backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 },
        borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 },
        drawRect = function() end,
        drawRectBorder = function() end,
        setHeight = function(self, h) self._panelH = h end,
        setWidth = function(self, w) self._panelW = w end,
        getHeight = function(self) return self._panelH or 0 end,
        getWidth = function(self) return self._panelW or 0 end,
    }
end

-- ── faithful MagicAccessories_Tooltip.lua sim ───────────────────────────────
-- Structure transcribed from the shipped file: fallback capture, isRendering
-- guard that DELEGATES to fallback, unconditional provider registration, and
-- the ensureInstalled reclaim. Harness items carry no magicAcc_rolls, so the
-- inner path always falls through to fallback (exactly what happens in-game
-- for every non-rolled item).
local maCalls = 0
local CYCLE_CAP = 60
local fallback_render
local isRendering = false
local customRender

local function customRenderInner(self)
    -- no rolls on harness items -> MA hands the item to the captured chain
    return fallback_render(self)
end

customRender = function(self)
    maCalls = maCalls + 1
    if maCalls > CYCLE_CAP then
        error("CYCLE: ISToolTipInv.render mutual recursion", 0)
    end
    if isRendering then
        return fallback_render(self)
    end
    isRendering = true
    local ok, result = pcall(customRenderInner, self)
    isRendering = false
    if not ok then error(result, 0) end
    return result
end

local function maEnsureInstalled()
    if ISToolTipInv.render == customRender then return end
    if _G.TooltipLib and TooltipLib.registerProvider then
        TooltipLib.registerProvider({
            id = "MagicAccessories", target = "item",
            enabled = function() return false end,   -- un-rolled item
            callback = function() end,
            description = "MagicAccessories sim",
        })
    end
    fallback_render = ISToolTipInv.render
    ISToolTipInv.render = customRender
end

-- ── the crash ordering, exactly as it happens in-game ───────────────────────
-- 1. MA's OnGameStart handler runs first (MA earlier in the mod list)
maEnsureInstalled()

-- 2. TooltipLib's InstallHook runs: captures customRender as original_render
TooltipLib._itemHookInstalled = false    -- force a fresh install in shared VMs
triggerEvent("OnGameStart")

-- 3. MA's OnCreatePlayer / OnPlayerUpdate reclaim: captures the TL wrapper
--    as fallback and takes the slot back
maEnsureInstalled()

-- 4. first hovered item
local item = makeItem()
local panel = makePanel(item)
local renderOk, renderErr = pcall(function() ISToolTipInv.render(panel) end)

-- record outcomes, then clean up for any later test files
local callsAtFinish = maCalls
local vanillaAtFinish = vanillaCalls
pcall(TooltipLib.removeProvider, "MagicAccessories")
if savedRender then ISToolTipInv.render = savedRender end

-- ── assertions ──────────────────────────────────────────────────────────────
local tests = {}

tests["render_chain_terminates_under_reclaiming_wrapper_mod"] = function()
    return Assert.isTrue(renderOk,
        "render chain must terminate (got: " .. tostring(renderErr) .. ")")
end

tests["cycle_is_broken_not_merely_capped"] = function()
    -- a healthy chain passes through MA at most twice per render
    -- (outer call + at most one guarded re-entry); dozens = the A<->B loop
    return Assert.isTrue(callsAtFinish <= 4,
        "MA wrapper entered " .. callsAtFinish .. "x for one render (cycle)")
end

tests["vanilla_render_still_reached"] = function()
    -- breaking the cycle must not blank the tooltip: the boot-time render
    -- (vanilla) has to run so the card + provider dispatch still draw
    return Assert.isTrue(vanillaAtFinish >= 1 and (item._doCalls or 0) >= 1,
        "vanilla render ran " .. tostring(vanillaAtFinish) ..
        "x, DoTooltip calls " .. tostring(item._doCalls or 0))
end

return tests
