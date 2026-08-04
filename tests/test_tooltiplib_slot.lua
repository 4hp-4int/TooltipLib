--[[
    TooltipLib ISToolTipItemSlot hook — characterization contract
    =============================================================
    The itemSlot surface historically had near-zero direct coverage while
    being a hand-maintained copy of the ISToolTipInv hook. These tests lock
    its CURRENT behavior ahead of the surface-hook factory refactor:

      - item + itemSlot providers are merged priority-sorted and both render
      - owned path passes ctx.surface == "itemSlot" and ctx.itemSlot through
      - non-InventoryItem subjects go straight to the original render
      - an EHR-style bypass (foreign render never touches self.tooltip)
        stands down — no unbounded growth
      - a foreign host that lays out the tooltip gets our content APPENDED
        below its extent (deferred mode)
      - a reclaiming-wrapper cycle on the slot surface is broken by the
        boot-time render (v1.5.4 depth guard, slot side)

    All scenarios run sequentially at file load (pairs() iteration order is
    undefined); the tests are pure assertions on recorded outcomes.
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"

if isClient == nil then function isClient() return false end end
if isServer == nil then function isServer() return false end end
if instanceof == nil then
    function instanceof(o, c) return type(o) == "table" and o._type == c end
end

-- ── vanilla-shaped mocks (must exist BEFORE Hook.lua's InstallHook runs) ────
ISToolTipInv = ISToolTipInv or {}
ISToolTipItemSlot = ISToolTipItemSlot or {}
local savedInvRender = ISToolTipInv.render
local savedSlotRender = ISToolTipItemSlot.render

local vanillaCalls = 0
local function vanillaImpl(self)
    vanillaCalls = vanillaCalls + 1
    local tt = self.tooltip
    if not tt then return end
    tt:setWidth(50)
    tt:setMeasureOnly(true)
    if self.item and self.item.DoTooltip then self.item:DoTooltip(tt) end
    tt:setMeasureOnly(false)
    if self.item and self.item.DoTooltip then self.item:DoTooltip(tt) end
end

-- _impl dispatcher convention (see test_tooltiplib_magicacc.lua): keeps the
-- boot-render escape path landing in THIS file's instrumented vanilla even
-- in shared-VM runs where Hook.lua was loaded by an earlier test file.
ISToolTipInv.render = function(self) return (self._impl or vanillaImpl)(self) end
ISToolTipItemSlot.render = function(self) return (self._impl or vanillaImpl)(self) end

require "TooltipLib/Core"
require "TooltipLib/Hook"

TooltipLib._itemHookInstalled = false    -- force fresh install (shared VMs)
triggerEvent("OnGameStart")
local tlSlotRender = ISToolTipItemSlot.render

-- ── fixtures ────────────────────────────────────────────────────────────────
local ItemProto = { _type = "InventoryItem" }
function ItemProto.DoTooltip(item, tooltip)
    item._doCalls = (item._doCalls or 0) + 1
    tooltip:setWidth(200)
    tooltip:setHeight(80)
end
function ItemProto.DoTooltipEmbedded(item, tooltip, layout, offset)
    item._embedCalls = (item._embedCalls or 0) + 1
end
function ItemProto.getID(item) return item._id end
function ItemProto.getName(item) return "Mock Slot Item" end
local ItemMT = { __index = ItemProto }

local nextId = 88000
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
    t._layouts = {}
    function t.beginLayout(self)
        local L = { _items = {} }
        function L.addItem(layout)
            local it = {}
            function it.setLabel(item, txt) item.label = txt end
            function it.setValue(item, txt) item.value = txt end
            function it.setValueRight(item, v) item.value = tostring(v) end
            function it.setProgress(item) end
            layout._items[#layout._items + 1] = it
            return it
        end
        function L.setMinValueWidth(layout) end
        function L.render(layout, x, y) return y + #layout._items * 14 end
        t._layouts[#t._layouts + 1] = L
        return L
    end
    function t.endLayout(self) end
    function t.getFont(self) return UIFont.Small end
    function t.DrawText(self) end
    function t.DrawTextRight(self) end
    t.draws = {}
    function t.DrawTextureScaledColor(self, tex, x, y, w, h, r, g, b, a)
        t.draws[#t.draws + 1] = { tex = tex, x = x, y = y, w = w, h = h }
    end
    return t
end

local function makePanel(item, impl)
    return {
        item = item,
        itemSlot = { _sentinel = true },
        _impl = impl or vanillaImpl,
        tooltip = makeTT(),
        backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 },
        borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 },
        rects = {},
        drawRect = function(self, x, y, w, h, a)
            self.rects[#self.rects + 1] = { x = x, y = y, w = w, h = h, a = a }
        end,
        drawRectBorder = function() end,
        setHeight = function(self, h) self._panelH = h end,
        setWidth = function(self, w) self._panelW = w end,
        getHeight = function(self) return self._panelH or 0 end,
        getWidth = function(self) return self._panelW or 0 end,
    }
end

-- collect all row labels across every layout the tooltip began, in order
local function collectLabels(tt)
    local labels = {}
    for _, L in ipairs(tt._layouts) do
        for _, it in ipairs(L._items) do
            if it.label then labels[#labels + 1] = tostring(it.label) end
        end
    end
    return labels
end

local function indexOf(list, needle)
    for i, v in ipairs(list) do
        if v:find(needle, 1, true) then return i end
    end
    return nil
end

local function clearProviders()
    for _, id in ipairs({ "SlotT_Item", "SlotT_Slot", "SlotT_Ctx", "SlotT_Defer" }) do
        pcall(TooltipLib.removeProvider, id)
    end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Scenario A: merged providers, priority order, ctx fields (owned path)
-- ════════════════════════════════════════════════════════════════════════════
clearProviders()
local ctxSeen = {}
TooltipLib.registerProvider({
    id = "SlotT_Slot", target = "itemSlot", priority = 20,
    enabled = function() return true end,
    callback = function(ctx) ctx:addLabel("FROM_SLOT_PROVIDER") end,
    description = "slot-target",
})
TooltipLib.registerProvider({
    id = "SlotT_Item", target = "item", priority = 50,
    enabled = function() return true end,
    callback = function(ctx) ctx:addLabel("FROM_ITEM_PROVIDER") end,
    description = "item-target",
})
TooltipLib.registerProvider({
    id = "SlotT_Ctx", target = "itemSlot", priority = 90,
    enabled = function() return true end,
    callback = function(ctx)
        ctxSeen.surface = ctx.surface
        ctxSeen.itemSlotSentinel = ctx.itemSlot and ctx.itemSlot._sentinel
        ctx:addLabel("FROM_CTX_PROVIDER")
    end,
    description = "ctx-observer",
})

local aItem = makeItem()
local aPanel = makePanel(aItem)
local aOk, aErr = pcall(function() ISToolTipItemSlot.render(aPanel) end)
local aLabels = collectLabels(aPanel.tooltip)
local aSlotIdx = indexOf(aLabels, "FROM_SLOT_PROVIDER")
local aItemIdx = indexOf(aLabels, "FROM_ITEM_PROVIDER")
local aCtxIdx = indexOf(aLabels, "FROM_CTX_PROVIDER")
-- owned path routes through DoTooltipEmbedded (the wrapper claims DoTooltip)
local aEmbedCalls = aItem._embedCalls or 0

-- ════════════════════════════════════════════════════════════════════════════
-- Scenario B: non-InventoryItem subject → original render, no dispatch
-- ════════════════════════════════════════════════════════════════════════════
local bCalls = 0
TooltipLib.registerProvider({
    id = "SlotT_Defer", target = "itemSlot",
    enabled = function() bCalls = bCalls + 1; return true end,
    callback = function() end,
    description = "must not be evaluated for a Resource",
})
local bVanillaBefore = vanillaCalls
local bEnabledBefore = bCalls
local bResource = setmetatable({ _type = "Resource", _id = 999901 }, {
    __index = { getID = function(s) return s._id end },
})
local bPanel = makePanel(bResource)
local bOk = pcall(function() ISToolTipItemSlot.render(bPanel) end)
local bVanillaRan = vanillaCalls > bVanillaBefore
local bEnabledCalls = bCalls - bEnabledBefore
pcall(TooltipLib.removeProvider, "SlotT_Defer")

-- ════════════════════════════════════════════════════════════════════════════
-- Scenario C: EHR-style bypass — foreign render never touches self.tooltip
-- ════════════════════════════════════════════════════════════════════════════
-- providers from Scenario A are still registered (content IS available);
-- the foreign renderer draws its own panel and ignores the ObjectTooltip.
local cItem = makeItem()
local cPanel = makePanel(cItem, function(self) --[[ own-panel draw, no tooltip touch ]] end)
local cHeights = {}
for frame = 1, 3 do
    pcall(function() ISToolTipItemSlot.render(cPanel) end)
    cHeights[frame] = cPanel.tooltip:getHeight()
end
local cLabels = collectLabels(cPanel.tooltip)

-- ════════════════════════════════════════════════════════════════════════════
-- Scenario D: deferred append — foreign host lays out the tooltip each hover
-- ════════════════════════════════════════════════════════════════════════════
local dItem = makeItem()
local dPanel = makePanel(dItem, function(self)
    self.tooltip:setWidth(120)
    self.tooltip:setHeight(90)   -- foreign extent; never calls item:DoTooltip
end)
local dHeights = {}
for frame = 1, 2 do
    pcall(function() ISToolTipItemSlot.render(dPanel) end)
    dHeights[frame] = dPanel.tooltip:getHeight()
end
local dLabels = collectLabels(dPanel.tooltip)
local dAppended = indexOf(dLabels, "FROM_SLOT_PROVIDER") ~= nil
    or indexOf(dLabels, "FROM_ITEM_PROVIDER") ~= nil
local dGrewPastForeign = (dHeights[2] or 0) > 90
local dPanelSynced = dPanel:getHeight() == dHeights[2]

-- ════════════════════════════════════════════════════════════════════════════
-- Scenario E: reclaiming-wrapper cycle on the slot surface (depth guard)
-- ════════════════════════════════════════════════════════════════════════════
local eCalls = 0
local eFallback
local eIsRendering = false
local eCustom
eCustom = function(self)
    eCalls = eCalls + 1
    if eCalls > 60 then error("SLOT CYCLE: unbounded render recursion", 0) end
    if eIsRendering then return eFallback(self) end
    eIsRendering = true
    local ok, r = pcall(function() return eFallback(self) end)
    eIsRendering = false
    if not ok then error(r, 0) end
    return r
end
-- the exact crash topology (mirror of test_tooltiplib_magicacc.lua, slot
-- surface): 1) sim installs first, 2) TL installs FRESH and captures the
-- sim as its original, 3) sim reclaims and captures TL's new wrapper as
-- its fallback — the two now chain to each other.
eFallback = ISToolTipItemSlot.render          -- sim's first install
ISToolTipItemSlot.render = eCustom
TooltipLib._itemHookInstalled = false          -- TL installs, original = eCustom
triggerEvent("OnGameStart")
eFallback = ISToolTipItemSlot.render           -- sim reclaims, fallback = TL wrapper
ISToolTipItemSlot.render = eCustom
local eItem = makeItem()
local ePanel = makePanel(eItem)                -- default vanilla impl (terminal)
local eOk, eErr = pcall(function() ISToolTipItemSlot.render(ePanel) end)
local eCallsAtFinish = eCalls
local eVanillaRan = (eItem._doCalls or 0) >= 1 or (eItem._embedCalls or 0) >= 1
ISToolTipItemSlot.render = tlSlotRender

-- ── cleanup for later test files ────────────────────────────────────────────
clearProviders()
if savedInvRender then ISToolTipInv.render = savedInvRender end
if savedSlotRender then ISToolTipItemSlot.render = savedSlotRender end

-- ── assertions ──────────────────────────────────────────────────────────────
local tests = {}

tests["owned_path_renders_and_chain_survives"] = function()
    return Assert.isTrue(aOk and aEmbedCalls >= 1,
        "slot render ok=" .. tostring(aOk) .. " err=" .. tostring(aErr) ..
        " DoTooltipEmbedded calls=" .. aEmbedCalls)
end

tests["item_and_slot_providers_both_land_priority_sorted"] = function()
    local ok = Assert.isTrue(aSlotIdx ~= nil and aItemIdx ~= nil and aCtxIdx ~= nil,
        "labels present: slot=" .. tostring(aSlotIdx) .. " item=" ..
        tostring(aItemIdx) .. " ctx=" .. tostring(aCtxIdx))
    -- priority 20 (slot) < 50 (item) < 90 (ctx): merged order
    return Assert.isTrue(ok and aSlotIdx < aItemIdx and aItemIdx < aCtxIdx,
        "priority-merged order 20<50<90, got " .. tostring(aSlotIdx) .. "," ..
        tostring(aItemIdx) .. "," .. tostring(aCtxIdx)) and ok
end

tests["ctx_carries_surface_and_itemSlot"] = function()
    local ok = Assert.equal(ctxSeen.surface, "itemSlot", "ctx.surface")
    return Assert.isTrue(ctxSeen.itemSlotSentinel == true,
        "ctx.itemSlot is the panel's itemSlot ref") and ok
end

tests["non_item_subject_goes_straight_to_original"] = function()
    local ok = Assert.isTrue(bOk and bVanillaRan,
        "original render ran for Resource subject")
    return Assert.equal(bEnabledCalls, 0,
        "no provider enabled() evaluation for a Resource") and ok
end

tests["full_bypass_stands_down_no_growth"] = function()
    -- foreign renderer never touched self.tooltip: heights must not creep
    local ok = Assert.equal(cHeights[1], cHeights[2], "no growth frame 1->2")
    ok = Assert.equal(cHeights[2], cHeights[3], "no growth frame 2->3") and ok
    return Assert.equal(#cLabels, 0,
        "no provider content stapled onto a bypassing renderer") and ok
end

tests["deferred_append_below_foreign_extent"] = function()
    local ok = Assert.isTrue(dAppended, "provider content appended in deferred mode")
    ok = Assert.isTrue(dGrewPastForeign,
        "tooltip height " .. tostring(dHeights[2]) .. " > foreign 90") and ok
    return Assert.isTrue(dPanelSynced, "panel height synced to appended extent") and ok
end

tests["slot_cycle_breaks_and_terminates"] = function()
    local ok = Assert.isTrue(eOk,
        "slot render chain terminates (got: " .. tostring(eErr) .. ")")
    ok = Assert.isTrue(eCallsAtFinish <= 4,
        "sim wrapper entered " .. eCallsAtFinish .. "x (cycle would be 60+)") and ok
    return Assert.isTrue(eVanillaRan,
        "boot render reached — tooltip still drew") and ok
end

return tests
