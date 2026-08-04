--[[
    TooltipLib Diagnostics — verdict engine contract
    ================================================
    diagnose() turns runtime evidence (ownership probe + _diag counters +
    circuit-breaker state) into OK / MITIGATED / ACTION verdicts with
    user-actionable advice. Locks:
      - healthy owned session -> OK, "holds the tooltip hook"
      - cycle breaks recorded -> MITIGATED, names the loop containment
      - foreign slot owner + zero evidence -> ACTION, bypass/load-order advice
      - pre-install (main menu) -> graceful "run again in-game"
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"

if isClient == nil then function isClient() return false end end
if isServer == nil then function isServer() return false end end
if instanceof == nil then
    function instanceof(o, c) return type(o) == "table" and o._type == c end
end

ISToolTipInv = ISToolTipInv or {}
local savedRender = ISToolTipInv.render

local function vanillaImpl(self)
    local tt = self.tooltip
    if not tt then return end
    tt:setWidth(50)
    tt:setMeasureOnly(true)
    if self.item and self.item.DoTooltip then self.item:DoTooltip(tt) end
    tt:setMeasureOnly(false)
    if self.item and self.item.DoTooltip then self.item:DoTooltip(tt) end
end
ISToolTipInv.render = function(self) return (self._impl or vanillaImpl)(self) end

require "TooltipLib/Core"
require "TooltipLib/Hook"
pcall(function() require "TooltipLib/Diagnostics" end)

TooltipLib._itemHookInstalled = false
triggerEvent("OnGameStart")
local tlRender = ISToolTipInv.render

-- ── fixtures (minimal clones of the slot-test shapes) ───────────────────────
local ItemProto = { _type = "InventoryItem" }
function ItemProto.DoTooltip(item, tooltip) tooltip:setWidth(200); tooltip:setHeight(80) end
function ItemProto.DoTooltipEmbedded() end
function ItemProto.getID(item) return item._id end
function ItemProto.getName() return "Diag Mock" end
local ItemMT = { __index = ItemProto }
local nextId = 99000
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
            function it.setLabel() end
            function it.setValue() end
            function it.setValueRight() end
            function it.setProgress() end
            layout._items[#layout._items + 1] = it
            return it
        end
        function L.setMinValueWidth() end
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

-- needs one active provider so renders take the dispatch path
TooltipLib.registerProvider({
    id = "DiagT", target = "item",
    enabled = function() return true end,
    callback = function(ctx) ctx:addLabel("diag row") end,
    description = "diag test provider",
})

-- ── Scenario A: healthy owned render ────────────────────────────────────────
TooltipLib._diag = {}
ISToolTipInv.render = tlRender
pcall(function() ISToolTipInv.render(makePanel(makeItem())) end)
local aReport, aLevel = TooltipLib.diagnose(true)

-- ── Scenario B: recorded cycle breaks -> MITIGATED ──────────────────────────
TooltipLib._diag = { ownedRenders = 10, cycleBreaks = 3 }
local bReport, bLevel = TooltipLib.diagnose(true)

-- ── Scenario C: foreign owner, zero evidence -> ACTION (bypass advice) ──────
TooltipLib._diag = {}
ISToolTipInv.render = function() end            -- foreign replacer owns slot
local cReport, cLevel = TooltipLib.diagnose(true)
ISToolTipInv.render = tlRender

-- ── Scenario D: pre-install (main menu) ─────────────────────────────────────
local savedInstalled = TooltipLib._installedRender
TooltipLib._installedRender = {}
local dReport, dLevel = TooltipLib.diagnose(true)
TooltipLib._installedRender = savedInstalled

-- cleanup
pcall(TooltipLib.removeProvider, "DiagT")
TooltipLib._diag = {}
if savedRender then ISToolTipInv.render = savedRender end

-- ── assertions ──────────────────────────────────────────────────────────────
local tests = {}

tests["healthy_session_is_ok"] = function()
    local ok = Assert.equal(aLevel, "OK", "healthy verdict")
    return Assert.isTrue(aReport:find("holds the tooltip hook", 1, true) ~= nil,
        "ownership line present") and ok
end

tests["cycle_breaks_are_mitigated_not_action"] = function()
    local ok = Assert.equal(bLevel, "MITIGATED", "cycle verdict")
    return Assert.isTrue(bReport:find("loop was detected and broken", 1, true) ~= nil,
        "containment explained") and ok
end

tests["silent_bypass_demands_action"] = function()
    local ok = Assert.equal(cLevel, "ACTION", "bypass verdict")
    ok = Assert.isTrue(cReport:find("BYPASS", 1, true) ~= nil, "names the bypass") and ok
    return Assert.isTrue(cReport:find("load order", 1, true) ~= nil,
        "gives load-order advice") and ok
end

tests["preinstall_degrades_gracefully"] = function()
    local ok = Assert.equal(dLevel, "OK", "no false alarms in main menu")
    return Assert.isTrue(dReport:find("not installed yet", 1, true) ~= nil,
        "asks to re-run in-game") and ok
end

return tests
