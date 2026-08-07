--[[
    TooltipLib panel dress — ISToolTipInv hook contract
    ===================================================
    Loads the REAL TooltipLib Hook.lua against a vanilla-shaped ISToolTipInv
    mock (measure DoTooltip -> flat box draw -> real DoTooltip, the exact
    B42 render sequence) and locks the dress contract on the item surface:

      - the dress draws exactly ONCE per render (real pass only), before
        vanilla/provider content, with final tooltip geometry
      - vanilla's flat box is suppressed during the render (alphas zeroed)
        and restored after — the shared panel fields never leak a zero
      - a foreign framework's panel is NEVER suppressed — including the
        very first frame (suppression is EARNED by a fired wrapper; the
        latch starts foreign) — and a healthy panel re-arms after one frame
      - active()=false stands down; a draw error clears the dress (fail-open)
      - setPanelDress/clearPanelDress validate and scope by owner id
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"

if isClient == nil then function isClient() return false end end
if isServer == nil then function isServer() return false end end
-- Hook's subject-type guard calls instanceof on every render (vanilla global;
-- the fluid-bar regression below drives it with a non-item subject)
if instanceof == nil then
    function instanceof(o, c) return type(o) == "table" and o._type == c end
end

-- ── vanilla-shaped ISToolTipInv mock (must exist BEFORE Hook.lua loads) ─────
-- Real flow (ISToolTipInv.lua): measure DoTooltip -> clamp/reposition ->
-- drawRect/drawRectBorder from backgroundColor/borderColor -> real DoTooltip.
-- boxRec captures the alphas AT box-draw time — that's what the screen gets.
ISToolTipInv = ISToolTipInv or {}

local boxRec = {}
local seq = {}   -- paint-order log: "dress" / "layout" entries

local function vanillaImpl(self)
    local tt = self.tooltip
    tt:setWidth(50)
    tt:setMeasureOnly(true)
    if self.item then self.item:DoTooltip(tt) end
    tt:setMeasureOnly(false)
    boxRec.bgA = self.backgroundColor.a
    boxRec.bdA = self.borderColor.a
    if self.item then self.item:DoTooltip(tt) end
end

ISToolTipInv.render = function(self)
    return (self._impl or vanillaImpl)(self)
end

require "TooltipLib/Core"
require "TooltipLib/Hook"

-- harness opts into MIXED dress (no PZAPI here, and consistency mode would
-- kill the dress for every test after the first deferred frame)
TooltipLib._mixedDressAllowed = function() return true end
triggerEvent("OnGameStart")                  -- InstallHook wraps our mock
local hookedRender = ISToolTipInv.render     -- stable capture (later OnGameStart
                                             -- triggers may re-wrap the global)

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
function ItemProto.getName(item) return "Mock Item" end
local ItemMT = { __index = ItemProto }

local nextId = 9000
local function makeItem()
    nextId = nextId + 1
    return setmetatable({ _id = nextId }, ItemMT)
end

local function makeTT()
    local t = { _w = 0, _h = 0, _x = 0, _y = 0, _measure = false }
    function t.setWidth(self, w) self._w = w end
    function t.getWidth(self) return self._w end
    function t.setHeight(self, h) self._h = h end
    function t.getHeight(self) return self._h end
    function t.setX(self, x) self._x = x end
    function t.getX(self) return self._x end
    function t.setY(self, y) self._y = y end
    function t.getY(self) return self._y end
    function t.setMeasureOnly(self, b) self._measure = b end
    function t.isMeasureOnly(self) return self._measure end
    function t.getLineSpacing(self) return 14 end
    -- Faithful ObjectTooltip.Layout model: the inner class's METHODS work
    -- (addItem / render / setMinValueWidth) but its Java instance FIELDS are
    -- NOT Lua-exposed — reading layout.items in-game returns nil (the
    -- 2026-07-03 error-spam lesson). Internal state lives under underscore
    -- names so framework code that wrongly reads Java fields fails here the
    -- way it fails in-game. render() advances y per item like Layout.render.
    t._layouts = {}
    function t.beginLayout(self)
        local L = { _items = {} }
        function L.addItem(layout)
            local it = {
                hasValue = false, rightJustify = false, progressFraction = -1,
                labelWidth = 0, valueWidth = 0, valueWidthRight = 0,
                progressWidth = 0, height = 14,
            }
            function it.setLabel(item, txt, r, g, b, a)
                item.label = txt
                item.lr, item.lg, item.lb, item.la = r, g, b, a
            end
            function it.setValue(item, txt, r, g, b, a)
                item.value = txt
                item.hasValue = true
                item.rightJustify = true
            end
            function it.setValueRight(item, v, hg)
                item.value = tostring(v)
                item.hasValue = true
                item.rightJustify = true
            end
            function it.setProgress(item, f, r, g, b, a)
                item.progressFraction = f
                item.r1, item.g1, item.b1, item.a1 = r, g, b, a
                item.hasValue = true
            end
            layout._items[#layout._items + 1] = it
            return it
        end
        function L.setMinValueWidth(layout, w) layout._minValueWidth = w end
        function L.render(layout, x, y, tooltip)
            seq[#seq + 1] = "layout"
            layout._renderY = y   -- where the framework placed the row block
            for i = 1, #layout._items do
                local it = layout._items[i]
                it.labelWidth = it.label and (#tostring(it.label) * 8) or 0
                if it.hasValue and it.value then
                    local vw = #tostring(it.value) * 8
                    if it.rightJustify then it.valueWidthRight = vw
                    else it.valueWidth = vw end
                end
                -- calcSizes counts embedded \n: a multi-line label is ONE
                -- item spanning lines * lineSpacing (ObjectTooltip.java)
                local lines = 1
                if it.label then
                    for _ in string.gmatch(tostring(it.label), "\n") do
                        lines = lines + 1
                    end
                end
                it.height = 14 * lines
                y = y + it.height
            end
            return y
        end
        t._layouts[#t._layouts + 1] = L
        return L
    end
    function t.endLayout(self, layout) end
    function t.getFont(self) return UIFont.Small end
    t.texts = {}
    function t.DrawText(self, font, str, x, y, r, g, b, a)
        t.texts[#t.texts + 1] = { str = str, x = x, y = y }
    end
    function t.DrawTextRight(self, ...) end
    t.draws = {}
    function t.DrawTextureScaledColor(self, tex, x, y, w, h, r, g, b, a)
        t.draws[#t.draws + 1] = { tex = tex, x = x, y = y, w = w, h = h,
                                  r = r, g = g, b = b, a = a }
    end
    return t
end

-- the framework accent line: a nil-texture 2px-wide draw at x=1
local function findBarDraw(tt)
    for _, d in ipairs(tt.draws) do
        if d.tex == nil and d.x == 1 and d.w == 2 then return d end
    end
    return nil
end

local function makePanel(item, impl)
    local p = {
        item = item,
        tooltip = makeTT(),
        backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 },
        borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 },
        _impl = impl,
        rects = {},
        setHeight = function(self, h) self._panelH = h end,
        setWidth = function(self, w) self._panelW = w end,
        getHeight = function(self) return self._panelH or 0 end,
        getWidth = function(self) return self._panelW or 0 end,
    }
    function p.drawRect(self, x, y, w, h, a, r, g, b)
        self.rects[#self.rects + 1] = { x = x, y = y, w = w, h = h, a = a }
    end
    function p.drawTextureScaled(self, tex, x, y, w, h, a, r, g, b)
        self.rects[#self.rects + 1] = { tex = tex, x = x, y = y, w = w, h = h, a = a }
    end
    return p
end

-- recording dress; draw signature per the setPanelDress contract
local function makeDress(opts)
    opts = opts or {}
    local d = { calls = {} }
    d.spec = {
        id = opts.id or "TestDress",
        active = opts.active,
        surfaces = opts.surfaces,
        draw = opts.draw or function(panel, tooltip, w, h, surface)
            d.calls[#d.calls + 1] = {
                w = w, h = h, surface = surface,
                measure = (tooltip and tooltip:isMeasureOnly()) or false,
            }
            seq[#seq + 1] = "dress"
        end,
    }
    return d
end

local function reset()
    TooltipLib.clearPanelDress("TestDress")
    TooltipLib._deferrerSeen = nil
    boxRec.bgA, boxRec.bdA = nil, nil
    for i = #seq, 1, -1 do seq[i] = nil end
end

local tests = {}

tests["baseline_no_dress_vanilla_box_untouched"] = function()
    reset()
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(boxRec.bgA, 0.5, "bg alpha at box draw")
    ok = Assert.equal(boxRec.bdA, 1, "border alpha at box draw") and ok
    ok = Assert.equal(p.item._doCalls, 2, "vanilla DoTooltip ran both passes") and ok
    return ok
end

tests["dress_draws_once_real_pass_final_geometry"] = function()
    reset()
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(#d.calls, 1, "one draw per render (real pass only)")
    ok = Assert.isFalse(d.calls[1] and d.calls[1].measure or false, "not on the measure pass") and ok
    ok = Assert.equal(d.calls[1] and d.calls[1].w, 200, "measured width") and ok
    ok = Assert.equal(d.calls[1] and d.calls[1].h, 80, "measured height") and ok
    ok = Assert.equal(d.calls[1] and d.calls[1].surface, "item", "surface tag") and ok
    ok = Assert.equal(p.item._doCalls, 2, "vanilla content still rendered both passes") and ok
    reset()
    return ok
end

tests["vanilla_box_suppressed_then_restored"] = function()
    reset()
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)   -- ownership frame: latch starts foreign, wrapper earns it
    hookedRender(p)
    local ok = Assert.equal(boxRec.bgA, 0, "bg alpha zero at box-draw time")
    ok = Assert.equal(boxRec.bdA, 0, "border alpha zero at box-draw time") and ok
    ok = Assert.equal(p.backgroundColor.a, 0.5, "bg alpha restored after render") and ok
    ok = Assert.equal(p.borderColor.a, 1, "border alpha restored after render") and ok
    reset()
    return ok
end

tests["active_false_stands_down_frame"] = function()
    reset()
    local d = makeDress({ active = function() return false end })
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(#d.calls, 0, "no dress draw while inactive")
    ok = Assert.equal(boxRec.bgA, 0.5, "vanilla box untouched while inactive") and ok
    ok = Assert.notNil(TooltipLib.getPanelDress(), "dress stays registered") and ok
    reset()
    return ok
end

tests["surfaces_optout_leaves_item_vanilla"] = function()
    reset()
    local d = makeDress({ surfaces = { object = true } })
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(#d.calls, 0, "item surface not opted in")
    ok = Assert.equal(boxRec.bgA, 0.5, "vanilla box untouched") and ok
    reset()
    return ok
end

tests["draw_error_clears_dress_fail_open"] = function()
    reset()
    TooltipLib.setPanelDress({ id = "TestDress", draw = function() error("boom") end })
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.isNil(TooltipLib.getPanelDress(), "dress cleared on draw error")
    ok = Assert.equal(p.backgroundColor.a, 0.5, "bg alpha restored despite error") and ok
    ok = Assert.equal(p.borderColor.a, 1, "border alpha restored despite error") and ok
    boxRec.bgA = nil
    hookedRender(makePanel(makeItem()))
    ok = Assert.equal(boxRec.bgA, 0.5, "next render is fully vanilla") and ok
    return ok
end

tests["foreign_owner_latch_and_rearm"] = function()
    reset()
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    -- foreign framework: replaces the render path, draws its own panel,
    -- never calls item:DoTooltip, never touches self.tooltip
    local foreignImpl = function(self)
        boxRec.bgA = self.backgroundColor.a
        boxRec.bdA = self.borderColor.a
    end
    local p = makePanel(makeItem(), foreignImpl)

    hookedRender(p)   -- frame 1: latch starts foreign — NO boxless flash
    local ok = Assert.equal(#d.calls, 0, "foreign panel never dressed")
    ok = Assert.equal(boxRec.bgA, 0.5, "frame 1 box intact (suppression is earned, not assumed)") and ok

    hookedRender(p)   -- frame 2: latch holds, vanilla box left alone
    ok = Assert.equal(boxRec.bgA, 0.5, "no suppression while foreign owns the panel") and ok
    ok = Assert.equal(#d.calls, 0, "still no dress draw") and ok

    -- healthy panel again: wrapper fires, latch releases, dress resumes
    local p2 = makePanel(makeItem())
    hookedRender(p2)   -- earns ownership (box still intact this frame)
    ok = Assert.equal(boxRec.bgA, 0.5, "first owned frame keeps the box under the dress") and ok
    hookedRender(p2)
    ok = Assert.equal(boxRec.bgA, 0, "suppression armed from the second owned frame") and ok
    ok = Assert.greater(#d.calls, 0, "dress draws again") and ok
    reset()
    return ok
end

tests["provider_path_dress_under_content"] = function()
    reset()
    local probeRan = false
    TooltipLib.registerProvider({
        id = "DressPathProbe",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) probeRan = true end,
        description = "dress-order probe",
    })
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.isTrue(probeRan, "provider dispatch ran")
    ok = Assert.equal(#d.calls, 1, "one dress draw with providers active") and ok
    -- paint order: measure layout, then (real pass) dress BEFORE layout
    ok = Assert.equal(seq[1], "layout", "measure-pass layout first") and ok
    ok = Assert.equal(seq[2], "dress", "dress opens the real pass") and ok
    ok = Assert.equal(seq[3], "layout", "content paints over the dress") and ok
    TooltipLib.removeProvider("DressPathProbe")
    reset()
    return ok
end

tests["accent_channel_framework_draws_one_bar"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "AccentProbe",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) end,
        postRender = function(ctx) ctx:setAccentColor({ 0.9, 0.3, 0.3, 1 }) end,
        description = "accent channel probe",
    })
    local p = makePanel(makeItem())
    hookedRender(p)
    local bar = findBarDraw(p.tooltip)
    local ok = Assert.notNil(bar, "framework drew the accent line")
    ok = Assert.nearEqual(bar and bar.r or 0, 0.9, 0.001, "declared colour used") and ok
    local n = 0
    for _, d in ipairs(p.tooltip.draws) do
        if d.tex == nil and d.x == 1 and d.w == 2 then n = n + 1 end
    end
    ok = Assert.equal(n, 1, "exactly one bar (real pass only, one source)") and ok
    TooltipLib.removeProvider("AccentProbe")
    return ok
end

tests["accent_last_write_wins"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "AccentTheme",
        target = "item",
        priority = TooltipLib.Priorities.FIRST,
        enabled = function() return true end,
        callback = function(ctx) end,
        postRender = function(ctx) ctx:setAccentColor({ 0.1, 0.1, 0.1, 1 }) end,
        description = "theme colour (first)",
    })
    TooltipLib.registerProvider({
        id = "AccentTier",
        target = "item",
        priority = 100,
        enabled = function() return true end,
        callback = function(ctx) end,
        postRender = function(ctx) ctx:setAccentColor({ 0.6, 0.2, 0.8, 1 }) end,
        description = "tier colour (later, wins)",
    })
    local p = makePanel(makeItem())
    hookedRender(p)
    local bar = findBarDraw(p.tooltip)
    local ok = Assert.notNil(bar, "bar drawn")
    ok = Assert.nearEqual(bar and bar.b or 0, 0.8, 0.001, "later provider's colour wins") and ok
    TooltipLib.removeProvider("AccentTheme")
    TooltipLib.removeProvider("AccentTier")
    return ok
end

tests["accent_reaches_dress_next_frame_no_bar"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "AccentProbe2",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) end,
        postRender = function(ctx) ctx:setAccentColor({ 0.2, 0.8, 0.4, 1 }) end,
        description = "accent channel probe",
    })
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local calls, seen = 0, {}
    d.spec.draw = function(panel, tooltip, w, h, surface, accent)
        calls = calls + 1
        seen[calls] = accent
    end
    local p = makePanel(makeItem())
    hookedRender(p)   -- frame 1: providers declare, dress drew before them
    hookedRender(p)   -- frame 2: dress catches up from the accent cache
    local ok = Assert.equal(calls, 2, "one dress draw per render")
    ok = Assert.isNil(seen[1], "frame 1: accent not yet known to the dress") and ok
    ok = Assert.notNil(seen[2], "frame 2: dress receives the accent") and ok
    ok = Assert.nearEqual(seen[2] and seen[2][2] or 0, 0.8, 0.001, "the declared colour") and ok
    ok = Assert.isNil(findBarDraw(p.tooltip), "no framework bar while dressed") and ok
    TooltipLib.removeProvider("AccentProbe2")
    reset()
    return ok
end

tests["callback_declared_accent_reaches_dress_same_frame"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "AccentWarm",
        target = "item",
        enabled = function() return true end,
        -- CALLBACK declaration (the recommended path): runs on the measure
        -- pass, which warms the accent cache before this same render's real
        -- pass — the dress never flashes its default rail
        callback = function(ctx) ctx:setAccentColor({ 0.1, 0.2, 0.9, 1 }) end,
        description = "callback-declared accent",
    })
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local calls, seen = 0, {}
    d.spec.draw = function(panel, tooltip, w, h, surface, accent)
        calls = calls + 1
        seen[calls] = accent
    end
    local p = makePanel(makeItem())
    hookedRender(p)   -- ONE render: measure pass warms, real pass reads
    local ok = Assert.equal(calls, 1, "one real-pass draw")
    ok = Assert.notNil(seen[1], "accent known on the FIRST frame") and ok
    ok = Assert.nearEqual(seen[1] and seen[1][3] or 0, 0.9, 0.001, "the declared colour") and ok
    TooltipLib.removeProvider("AccentWarm")
    reset()
    return ok
end

tests["section_undressed_label_plus_divider_rows"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "SectionPlain",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx)
            ctx:beginSection("Nutrition")
            ctx:addKeyValue("Calories:", "120")
        end,
        description = "plain section probe",
    })
    local p = makePanel(makeItem())
    hookedRender(p)
    local L = p.tooltip._layouts[#p.tooltip._layouts]   -- real-pass layout
    local ok = Assert.equal(#L._items, 3, "label + divider rule + content row")
    ok = Assert.equal(L._items[1].label, "NUTRITION", "uppercased section label") and ok
    ok = Assert.nearEqual(L._items[2].progressFraction or -1, 1.0, 0.001,
        "plain divider rule row (classic look)") and ok
    ok = Assert.equal(L._items[3].value, "120", "content row follows the rule") and ok
    TooltipLib.removeProvider("SectionPlain")
    return ok
end

tests["section_dressed_geometry_reaches_ornaments"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "SectionGeom",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx)
            ctx:beginSection("Nutrition")
            ctx:addKeyValue("Calories:", "120")
            ctx:addProgress("Freshness:", 0.5)
        end,
        description = "section geometry probe",
    })
    local d = makeDress()
    local ornCalls, gotGeom, gotSurface = 0, nil, nil
    d.spec.ornaments = function(panel, tooltip, geom, surface, accent)
        ornCalls = ornCalls + 1
        gotGeom, gotSurface = geom, surface
    end
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local L = p.tooltip._layouts[#p.tooltip._layouts]
    local ok = Assert.equal(#L._items, 3, "divider row OMITTED while ornaments active")
    ok = Assert.equal(ornCalls, 1, "ornaments once per render (real pass only)") and ok
    ok = Assert.equal(gotSurface, "item", "surface tag") and ok
    ok = Assert.equal(#(gotGeom and gotGeom.sections or {}), 1, "one declared section") and ok
    local s = gotGeom and gotGeom.sections[1] or {}
    ok = Assert.equal(s.label, "NUTRITION", "section label in geometry") and ok
    -- startY = padTop(5) + lineSpacing(14); the label is the first layout row
    ok = Assert.equal(s.y, 19, "section label row y = startY") and ok
    ok = Assert.equal(s.h, 14, "row height = lineSpacing") and ok
    local rows = gotGeom and gotGeom.rows or {}
    ok = Assert.equal(#rows, 3, "one geometry entry per layout row") and ok
    ok = Assert.equal(rows[1].kind, "label", "section label row kind") and ok
    ok = Assert.equal(rows[2].kind, "kv", "key/value row kind") and ok
    ok = Assert.equal(rows[2].y, 33, "second row advances by lineSpacing") and ok
    ok = Assert.isTrue(rows[2].labelW > 0 and rows[2].valueW > 0,
        "kv row carries measured label/value widths") and ok
    ok = Assert.equal(rows[3].kind, "bar", "progress row kind") and ok
    ok = Assert.isTrue((gotGeom.valueRightX or 0) > (gotGeom.left or 0),
        "value column right edge computed") and ok
    ok = Assert.isTrue(rows[1].provider and rows[2].provider,
        "rows attributed to the provider region") and ok
    TooltipLib.removeProvider("SectionGeom")
    reset()
    return ok
end

tests["bar_rows_carry_fraction_and_colour_dividers_are_rules"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "BarGeom",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx)
            ctx:addProgress("Freshness:", 0.62, nil, { 0.2, 0.8, 0.3, 1 })
            ctx:addDivider()
        end,
        description = "bar geometry probe",
    })
    local d = makeDress()
    local gotGeom
    d.spec.ornaments = function(panel, tooltip, geom) gotGeom = geom end
    TooltipLib.setPanelDress(d.spec)
    hookedRender(makePanel(makeItem()))
    local rows = gotGeom and gotGeom.rows or {}
    local ok = Assert.equal(#rows, 2, "bar + divider rows")
    ok = Assert.equal(rows[1] and rows[1].kind, "bar", "labelled progress row = bar") and ok
    ok = Assert.nearEqual(rows[1] and rows[1].fraction or 0, 0.62, 0.001,
        "bar fraction in geometry") and ok
    ok = Assert.nearEqual(rows[1] and rows[1].barColor and rows[1].barColor[2] or 0,
        0.8, 0.001, "bar's declared colour in geometry") and ok
    ok = Assert.equal(rows[2] and rows[2].kind, "rule",
        "labelless divider row = rule (not restyled as a gauge)") and ok
    ok = Assert.equal(gotGeom and gotGeom.barH, 5, "vanilla bar height for Small font") and ok
    TooltipLib.removeProvider("BarGeom")
    reset()
    return ok
end

tests["vps_shaped_cacheable_provider_keeps_bar_geometry_across_frames"] = function()
    -- Repro harness for the 2026-07-03 report "VPS tooltips don't get chrome
    -- gauges": VPS's provider is cacheable + hasDetailContent with long KV
    -- labels, indented addProgress bars, headers and wrapped lore. The bar
    -- rows must land in the ornament geometry with correct fraction and
    -- aligned y on BOTH the record frame and the cache-replay frame.
    reset()
    TooltipLib.registerProvider({
        id = "VpsShaped",
        target = "item",
        cacheable = true,
        hasDetailContent = true,
        maxAge = 120,
        minWidth = 180,
        separator = false,
        enabled = function() return true end,
        callback = function(ctx)
            ctx:addHeader("Mark: Deadly", { 0.7, 0.62, 0.97, 1 }, true)
            ctx:addKeyValue("Personality Stage:", "Proven  2/5",
                { 0.7, 0.7, 0.7, 1 }, { 0.9, 0.6, 0.3, 1 })
            ctx:addProgress("  Power  85%", 0.85,
                { 0.9, 0.6, 0.3, 1 }, { 0.9, 0.6, 0.3, 1 })
            ctx:addText("It remembers every kill, and asks for more of them.",
                { 0.72, 0.66, 0.55, 1 }, 200)
            ctx:addProgress("Condition:", 0.5, nil, { 0.2, 0.8, 0.3, 1 })
        end,
        description = "VPS-shaped geometry probe",
    })
    local d = makeDress()
    local geoms = {}
    d.spec.ornaments = function(panel, tooltip, geom)
        geoms[#geoms + 1] = geom
    end
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)   -- frame 1: measure records, real pass replays from L2
    hookedRender(p)   -- frame 2: both passes replay from L2
    local ok = Assert.equal(#geoms, 2, "ornaments ran on both real passes")
    for f = 1, #geoms do
        local g = geoms[f]
        local bars, lastY = {}, nil
        for i = 1, #g.rows do
            local r = g.rows[i]
            if lastY then
                ok = Assert.equal(r.y, lastY + g.lineSpacing,
                    "frame " .. f .. " row " .. i .. " y advances one lineSpacing") and ok
            end
            lastY = r.y
            if r.kind == "bar" then bars[#bars + 1] = r end
        end
        ok = Assert.equal(#bars, 2, "frame " .. f .. ": both bars in geometry") and ok
        ok = Assert.nearEqual(bars[1] and bars[1].fraction or 0, 0.85, 0.001,
            "frame " .. f .. ": indented bar fraction") and ok
        ok = Assert.greater((g.valueRightX or 0) - (g.midX or 0), 8,
            "frame " .. f .. ": gauge band wider than the draw threshold") and ok
    end
    TooltipLib.removeProvider("VpsShaped")
    reset()
    return ok
end

tests["multiline_label_keeps_geometry_grid_aligned"] = function()
    -- The VPS shard-lore pattern: ONE addLabel carrying multi-paragraph text
    -- with embedded \n is a single layout item spanning several lines. The
    -- geometry must account its true height or every row (and the whole
    -- provider region's startY) shifts — the 2026-07-03 shard report.
    reset()
    TooltipLib.registerProvider({
        id = "LoreShaped",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx)
            ctx:addKeyValue("Uses:", "3")
            ctx:addLabel("line one\nline two\n\nline four", { 1, 1, 0.8, 1 })
            ctx:addProgress("Charge:", 0.5, nil, { 0.9, 0.4, 0.2, 1 })
        end,
        description = "multi-line lore geometry probe",
    })
    local d = makeDress()
    local gotGeom
    d.spec.ornaments = function(panel, tooltip, geom) gotGeom = geom end
    TooltipLib.setPanelDress(d.spec)
    hookedRender(makePanel(makeItem()))
    local g = gotGeom
    local rows = g and g.rows or {}
    local ls = g and g.lineSpacing or 14
    local ok = Assert.equal(#rows, 3, "three noted rows")
    ok = Assert.equal(rows[2] and rows[2].h, 4 * ls,
        "multi-line label row spans its 4 lines") and ok
    ok = Assert.equal(rows[3] and rows[3].y, (rows[2] and rows[2].y or 0) + 4 * ls,
        "bar row sits BELOW the full lore block, not one line into it") and ok
    ok = Assert.equal((rows[3] and rows[3].y or 0) + ls, g and g.endY or -1,
        "last row ends at the layout end (grid re-anchored)") and ok
    ok = Assert.equal(rows[3] and rows[3].kind, "bar", "bar row keeps its kind") and ok
    TooltipLib.removeProvider("LoreShaped")
    reset()
    return ok
end

tests["dress_only_frame_still_gets_ruling_geometry"] = function()
    reset()
    local d = makeDress()
    local gotGeom
    d.spec.ornaments = function(panel, tooltip, geom) gotGeom = geom end
    TooltipLib.setPanelDress(d.spec)
    hookedRender(makePanel(makeItem()))   -- no providers: dress-only frame
    local ok = Assert.notNil(gotGeom, "ornaments fire on a pure-vanilla tooltip")
    ok = Assert.equal(#(gotGeom and gotGeom.rows or { 1 }), 0,
        "no rows described (nothing declared)") and ok
    -- line grid from vanilla metrics: padTop 5 + lineSpacing 14
    ok = Assert.equal(gotGeom and gotGeom.top, 19, "grid top under the name line") and ok
    ok = Assert.equal(gotGeom and gotGeom.endY, 75, "grid extent = height - padBottom") and ok
    reset()
    return ok
end

tests["divider_flat_bar_suppressed_under_ornaments"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "DividerChrome",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) ctx:addDivider() end,
        description = "divider suppression probe",
    })
    local d = makeDress()
    local gotGeom
    d.spec.ornaments = function(panel, tooltip, geom) gotGeom = geom end
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local L = p.tooltip._layouts[#p.tooltip._layouts]
    local ok = Assert.nearEqual(L._items[1].progressFraction or -1, -1, 0.001,
        "flat Java bar suppressed (skin draws the rule)")
    ok = Assert.equal(gotGeom and gotGeom.rows[1] and gotGeom.rows[1].kind, "rule",
        "row still noted as a rule for the skin") and ok
    TooltipLib.removeProvider("DividerChrome")
    reset()
    return ok
end

tests["section_label_takes_dress_declared_color"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "SectionTint",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) ctx:beginSection("Bait") end,
        description = "section label colour probe",
    })
    local d = makeDress()
    d.spec.sectionLabelColor = { 0.9, 0.2, 0.3, 1 }
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local L = p.tooltip._layouts[#p.tooltip._layouts]
    local lbl
    for i = 1, #L._items do
        if L._items[i].label == "BAIT" then lbl = L._items[i] end
    end
    local ok = Assert.notNil(lbl, "section label row present")
    ok = Assert.nearEqual(lbl and lbl.lr or 0, 0.9, 0.001,
        "label wears the dress's sectionLabelColor") and ok
    TooltipLib.removeProvider("SectionTint")
    reset()
    return ok
end

tests["cacheable_replay_keeps_sections"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "SectionCached",
        target = "item",
        enabled = function() return true end,
        cacheable = true,
        callback = function(ctx)
            ctx:beginSection("Trap")
            ctx:addKeyValue("Catch:", "Rabbit")
        end,
        description = "cacheable section probe",
    })
    local d = makeDress()
    local geoms = {}
    d.spec.ornaments = function(panel, tooltip, geom) geoms[#geoms + 1] = geom end
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)   -- frame 1: records the display list
    hookedRender(p)   -- frame 2: replays it from the L2 cache
    local ok = Assert.equal(#geoms, 2, "ornaments both frames")
    ok = Assert.equal(#(geoms[2] and geoms[2].sections or {}), 1,
        "replayed frame still declares the section") and ok
    ok = Assert.equal(geoms[2] and geoms[2].sections[1].label, "TRAP",
        "replayed section label intact") and ok
    TooltipLib.removeProvider("SectionCached")
    reset()
    return ok
end

tests["ornaments_error_clears_dress_fail_open"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "SectionBoom",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) ctx:beginSection("Boom") end,
        description = "ornaments fail-open probe",
    })
    local d = makeDress()
    d.spec.ornaments = function() error("ornament boom") end
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.isNil(TooltipLib.getPanelDress(), "dress cleared on ornaments error")
    ok = Assert.equal(p.backgroundColor.a, 0.5, "bg alpha restored despite error") and ok
    boxRec.bgA = nil
    hookedRender(makePanel(makeItem()))
    ok = Assert.equal(boxRec.bgA, 0.5, "next render is fully vanilla") and ok
    TooltipLib.removeProvider("SectionBoom")
    return ok
end

tests["replacing_provider_claims_vanilla_rows"] = function()
    reset()
    local accepted = TooltipLib.registerProvider({
        id = "VanillaClaim",
        target = "item",
        replacesVanilla = true,
        enabled = function() return true end,
        callback = function(ctx)
            ctx:addKeyValue("Weight:", "2.0")
        end,
        description = "vanilla-claim probe",
    })
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.isTrue(accepted, "replacesVanilla accepted on the item target")
    ok = Assert.equal(p.item._embedCalls or 0, 0,
        "DoTooltipEmbedded skipped — the provider owns the rows") and ok
    -- the framework draws the name line the embed would have (real pass only)
    local names = 0
    for _, tx in ipairs(p.tooltip.texts) do
        if tx.str == "Mock Item" then names = names + 1 end
    end
    ok = Assert.equal(names, 1, "framework drew the name line once (real pass)") and ok
    TooltipLib.removeProvider("VanillaClaim")
    return ok
end

tests["non_replacing_provider_keeps_vanilla_rows"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "NoClaim",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) end,
        description = "no-claim probe",
    })
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(p.item._embedCalls, 2,
        "DoTooltipEmbedded ran both passes as before")
    TooltipLib.removeProvider("NoClaim")
    return ok
end

tests["set_clear_validation"] = function()
    reset()
    local ok = Assert.isFalse(TooltipLib.setPanelDress(nil), "nil spec rejected")
    ok = Assert.isFalse(TooltipLib.setPanelDress({ id = "X" }), "missing draw rejected") and ok
    ok = Assert.isFalse(TooltipLib.setPanelDress({ draw = function() end }), "missing id rejected") and ok
    ok = Assert.isTrue(TooltipLib.setPanelDress({ id = "TestDress", draw = function() end }), "valid spec accepted") and ok
    ok = Assert.isFalse(TooltipLib.clearPanelDress("SomeoneElse"), "wrong owner cannot clear") and ok
    ok = Assert.notNil(TooltipLib.getPanelDress(), "dress survives wrong-owner clear") and ok
    ok = Assert.isTrue(TooltipLib.clearPanelDress("TestDress"), "owner clears") and ok
    ok = Assert.isNil(TooltipLib.getPanelDress(), "slot empty after clear") and ok
    return ok
end

tests["deferred_extension_wears_the_dress"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "DeferProbe",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx)
            ctx:setAccentColor({ 0.9, 0.3, 0.3, 1 })
            ctx:addLabel("appended", { 1, 1, 1, 1 })
        end,
        description = "deferred probe",
    })
    local d = makeDress()
    d.deferred = {}
    d.spec.drawDeferred = function(panel, foreignH, totalH, totalW, surface, accent)
        d.deferred[#d.deferred + 1] = {
            foreignH = foreignH, totalH = totalH, totalW = totalW, surface = surface,
        }
    end
    TooltipLib.setPanelDress(d.spec)

    -- legit deferred host (StarlitLibrary shape): renders THROUGH the
    -- ObjectTooltip with fresh dimensions every frame, never calls the
    -- item's DoTooltip (our wrapper never fires)
    local n = 0
    local deferImpl = function(self)
        boxRec.bgA = self.backgroundColor.a
        n = n + 1
        self.tooltip:setWidth(120)
        self.tooltip:setHeight(60 + n)
    end
    local p = makePanel(makeItem(), deferImpl)

    hookedRender(p)   -- frame 1: no cached extension dims yet -> flat path
    local ok = Assert.equal(boxRec.bgA, 0.5, "no suppression in deferred mode (frame 1)")
    ok = Assert.equal(#d.calls, 0, "the CARD dress never runs on a foreign panel") and ok

    hookedRender(p)   -- frame 2: cached dims -> the extension wears the dress
    ok = Assert.greater(#d.deferred, 0, "drawDeferred skins the appended extension") and ok
    local call = d.deferred[#d.deferred]
    ok = Assert.isTrue(call and call.foreignH > 0, "extension starts below the foreign card") and ok
    ok = Assert.isTrue(call and call.totalH > call.foreignH, "extension has provider height") and ok
    ok = Assert.equal(call and call.surface, "item", "surface tag") and ok
    -- the classic accent line spans the whole card in deferred mode — the
    -- accent must be CONSISTENT across foreign + appended regions, dressed
    -- extension or not (the one-frame appear/vanish flicker the field
    -- report caught)
    ok = Assert.isTrue(findBarDraw(p.tooltip) ~= nil,
        "classic accent line drawn while the extension is dressed") and ok

    TooltipLib.removeProvider("DeferProbe")
    reset()
    return ok
end

tests["deferred_drops_replacesVanilla_claimers"] = function()
    reset()
    -- a full-card claimer (VanillaCore shape): in deferred mode the foreign
    -- chain already drew vanilla's rows — re-emitting them below would
    -- duplicate the whole card
    TooltipLib.registerProvider({
        id = "DeferClaimer",
        target = "item",
        replacesVanilla = true,
        enabled = function() return true end,
        callback = function(ctx)
            ctx:addLabel("mirrored vanilla row", { 1, 1, 1, 1 })
        end,
        description = "claimer probe",
    })
    local n = 0
    local deferImpl = function(self)
        boxRec.bgA = self.backgroundColor.a
        n = n + 1
        self.tooltip:setWidth(120)
        self.tooltip:setHeight(60 + n)
    end
    local p = makePanel(makeItem(), deferImpl)

    hookedRender(p)
    hookedRender(p)
    -- claimers-only: NOTHING appended — the tooltip keeps exactly the
    -- foreign framework's height (our dispatch would have grown it)
    local ok = Assert.equal(p.tooltip:getHeight(), 62, "claimer-only deferred appends nothing")

    -- mixed: a normal provider still appends; the claimer stays dropped
    TooltipLib.registerProvider({
        id = "DeferPlain",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) ctx:addLabel("appended", { 1, 1, 1, 1 }) end,
        description = "plain probe",
    })
    local p2 = makePanel(makeItem(), deferImpl)
    hookedRender(p2)
    hookedRender(p2)
    local h = p2.tooltip:getHeight()
    ok = Assert.greater(h, 60 + n, "plain provider content still appends") and ok
    -- exactly ONE appended row: the claimer's mirror row must not be there
    local lastLayout = p2.tooltip._layouts[#p2.tooltip._layouts]
    ok = Assert.equal(lastLayout and #lastLayout._items, 1,
        "only the plain provider's single row is appended") and ok

    TooltipLib.removeProvider("DeferClaimer")
    TooltipLib.removeProvider("DeferPlain")
    reset()
    return ok
end

tests["deferred_once_per_hover_measurer_stays_appended"] = function()
    reset()
    -- the field-reported erratic case: a legit host that measures ONCE per
    -- hover (touches the tooltip height only on its first frame, draws text
    -- every frame). The old same-ref+same-height heuristic read the stable
    -- height — OUR OWN last write — as an EHR bypass and stood down, so the
    -- append flapped between accented and plain vanilla.
    TooltipLib.registerProvider({
        id = "OnceProbe",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx)
            ctx:setAccentColor({ 0.3, 0.6, 0.9, 1 })
            ctx:addLabel("appended", { 1, 1, 1, 1 })
        end,
        description = "once-measurer probe",
    })
    local measured = false
    local onceImpl = function(self)
        boxRec.bgA = self.backgroundColor.a
        if not measured then
            measured = true
            self.tooltip:setWidth(120)
            self.tooltip:setHeight(60)
        end
        -- every frame: draws text, never touches dimensions again
    end
    local p = makePanel(makeItem(), onceImpl)

    hookedRender(p)                       -- frame 1: lays out, appends
    local h1 = p.tooltip:getHeight()
    local ok = Assert.greater(h1, 60, "frame 1 appends below the foreign card")

    local heightsStable, accentEveryFrame = true, true
    for _ = 1, 3 do                       -- frames 2-4: height untouched by host
        for i = #p.tooltip.draws, 1, -1 do p.tooltip.draws[i] = nil end
        hookedRender(p)
        if p.tooltip:getHeight() ~= h1 then heightsStable = false end
        if findBarDraw(p.tooltip) == nil then accentEveryFrame = false end
    end
    ok = Assert.isTrue(heightsStable, "no unbounded growth (append base is the remembered foreign extent)") and ok
    ok = Assert.isTrue(accentEveryFrame, "append + accent on EVERY frame — no flapping to plain vanilla") and ok

    -- RE-HOVER: hosts with per-item layout caches never re-lay on a
    -- re-hover — the memo must survive hovering something else in between
    -- (the single-slot memory stood whole re-hovers down: accents present
    -- one hover, gone the next)
    local other = makePanel(makeItem(), onceImpl)   -- fresh item: host measures it
    hookedRender(other)
    for i = #p.tooltip.draws, 1, -1 do p.tooltip.draws[i] = nil end
    hookedRender(p)   -- re-hover of the FIRST item: host does not re-measure
    ok = Assert.equal(p.tooltip:getHeight(), h1,
        "re-hover appends from the remembered per-item extent") and ok
    ok = Assert.isTrue(findBarDraw(p.tooltip) ~= nil,
        "re-hover keeps the accent (no per-hover stand-down)") and ok

    TooltipLib.removeProvider("OnceProbe")
    reset()
    return ok
end

tests["dress_covers_late_growers_next_frame"] = function()
    reset()
    -- a non-TooltipLib mod that skips the measure pass and appends rows +
    -- height during the real DoTooltip: the dress drew before the growth and
    -- under-covered — foreign rows sat on empty space below the card.
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local grower = makeItem()
    local GrowerMT = { __index = setmetatable({
        DoTooltip = function(item, tooltip)
            item._doCalls = (item._doCalls or 0) + 1
            tooltip:setWidth(200)
            tooltip:setHeight(80)
            if not tooltip:isMeasureOnly() then
                tooltip:setHeight(110)   -- real-pass growth (well-behaved skip-measure mod)
                tooltip:setWidth(260)    -- ...and a long row widens it too
            end
        end,
    }, getmetatable(grower).__index and { __index = getmetatable(grower).__index } or nil) }
    setmetatable(grower, GrowerMT)
    local p = makePanel(grower)

    hookedRender(p)   -- frame 1: dress drew at the pre-growth height
    hookedRender(p)   -- frame 2: height memory covers the grown card
    local last = d.calls[#d.calls]
    local ok = Assert.equal(last and last.h, 110,
        "dress covers last frame's FINAL height (late growth included)")
    ok = Assert.equal(last and last.w, 260,
        "dress covers last frame's FINAL width (long late rows included)") and ok
    reset()
    return ok
end

tests["dress_covers_panel_extent_render_replacers"] = function()
    reset()
    -- SWSP-shaped mod: replaces the render for some items, sizes its extra
    -- stats region on the PANEL (setHeight(tooltipH + extra)) before the
    -- real DoTooltip, draws its own box from the panel bg fields (which the
    -- dress suppresses), then stats below the tooltip extent. The card must
    -- cover the panel's declared extent or the stats sit on empty space.
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local swspImpl = function(self)
        local tt = self.tooltip
        tt:setWidth(50)
        tt:setMeasureOnly(true)
        if self.item then self.item:DoTooltip(tt) end
        tt:setMeasureOnly(false)
        self:setWidth(tt:getWidth())
        self:setHeight(tt:getHeight() + 42)   -- extra stats region, panel-only
        boxRec.bgA = self.backgroundColor.a
        if self.item then self.item:DoTooltip(tt) end
        -- (stats drawn here, below tt:getHeight())
    end
    local p = makePanel(makeItem(), swspImpl)
    hookedRender(p)   -- ownership earned
    hookedRender(p)
    local last = d.calls[#d.calls]
    local ok = Assert.equal(last and last.h, 80 + 42,
        "dress covers the panel's declared extent (tooltip + stats region)")
    reset()
    return ok
end

tests["consistency_mode_stands_dress_down_session_wide"] = function()
    reset()
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    -- default (option off / absent): once a foreign framework is seen, the
    -- dress stands down EVERYWHERE so every tooltip matches
    local savedGate = TooltipLib._mixedDressAllowed
    TooltipLib._mixedDressAllowed = function() return false end

    local p = makePanel(makeItem())
    hookedRender(p); hookedRender(p)
    local ok = Assert.greater(#d.calls, 0, "dress active before any deferrer is seen")
    local before = #d.calls

    TooltipLib._deferrerSeen = true   -- what the deferred branches set
    hookedRender(p)
    ok = Assert.equal(#d.calls, before, "dress stands down session-wide (consistency)") and ok

    TooltipLib._mixedDressAllowed = function() return true end
    hookedRender(p)
    ok = Assert.greater(#d.calls, before, "mixed option restores the dressed look") and ok

    TooltipLib._mixedDressAllowed = savedGate
    reset()
    return ok
end

tests["deferred_append_clears_panel_extent_stats"] = function()
    reset()
    -- mixed mode, deferrer + SWSP-class mod: the stats region lives on the
    -- PANEL, below the tooltip extent. The deferred append must start below
    -- it, not inside it (field report: overlap with mixedDress ON).
    TooltipLib.registerProvider({
        id = "PanelExtentProbe",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) ctx:addLabel("appended", { 1, 1, 1, 1 }) end,
        description = "panel-extent probe",
    })
    local d = makeDress()
    d.deferred = {}
    d.spec.drawDeferred = function(panel, foreignH, totalH, totalW)
        d.deferred[#d.deferred + 1] = { foreignH = foreignH, totalH = totalH }
    end
    TooltipLib.setPanelDress(d.spec)
    local n = 0
    local impl = function(self)
        n = n + 1
        self.tooltip:setWidth(120)
        self.tooltip:setHeight(60 + n)     -- tooltip extent (re-laid each frame)
        self:setWidth(120)
        self:setHeight(60 + n + 40)        -- panel extent: +40 stats region
        -- never calls item DoTooltip (deferred)
    end
    local p = makePanel(makeItem(), impl)
    hookedRender(p)
    hookedRender(p)
    local call = d.deferred[#d.deferred]
    local ok = Assert.isTrue(call ~= nil, "extension dressed on frame 2")
    ok = Assert.isTrue(call and call.foreignH >= 60 + 40,
        "deferred append starts below the PANEL-declared stats region") and ok
    TooltipLib.removeProvider("PanelExtentProbe")
    reset()
    return ok
end

tests["detail_toggle_never_draws_stale_extent"] = function()
    reset()
    -- detail mode legitimately RESIZES the card: the extent memory must be
    -- keyed by detail state, or every Shift release drew the grown card for
    -- a frame (a strobe while toggling — the detail-mode jank report)
    TooltipLib.registerProvider({
        id = "DetailProbe",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx)
            ctx:addLabel("base row", { 1, 1, 1, 1 })
            if ctx.detail then
                for i = 1, 4 do ctx:addLabel("detail row " .. i, { 1, 1, 1, 1 }) end
            end
        end,
        description = "detail probe",
    })
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local held = false
    local savedRead = TooltipLib._readDetailKey
    TooltipLib._readDetailKey = function() return held end

    local p = makePanel(makeItem())
    hookedRender(p)                 -- earn ownership, small card
    hookedRender(p)
    local smallH = d.calls[#d.calls].h
    held = true
    hookedRender(p); hookedRender(p)
    local bigH = d.calls[#d.calls].h
    local ok = Assert.greater(bigH, smallH, "detail grows the card")
    held = false
    hookedRender(p)                 -- RELEASE frame: must NOT reuse the grown extent
    local releaseH = d.calls[#d.calls].h
    ok = Assert.equal(releaseH, smallH, "release frame draws the small card, not last frame's grown one") and ok

    TooltipLib._readDetailKey = savedRead
    TooltipLib.removeProvider("DetailProbe")
    reset()
    return ok
end

tests["deferred_thrash_retires_item_to_vanilla"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "ThrashProbe",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) ctx:addLabel("appended", { 1, 1, 1, 1 }) end,
        description = "thrash probe",
    })
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    -- chaotic stack: the reported foreign extent swings wildly every frame
    local heights, i = { 60, 200, 60, 200, 60, 200 }, 0
    local impl = function(self)
        i = i + 1
        self.tooltip:setWidth(120)
        self.tooltip:setHeight(heights[math.min(i, #heights)])
    end
    local p = makePanel(makeItem(), impl)
    for _ = 1, 6 do hookedRender(p) end
    -- retired: our append no longer grows the tooltip past the host's write
    local hBefore = p.tooltip:getHeight()
    hookedRender(p)
    local ok = Assert.equal(p.tooltip:getHeight(), heights[#heights],
        "thrashing item retired — nothing appended (clean vanilla)")
    TooltipLib.removeProvider("ThrashProbe")
    reset()
    return ok
end

-- ── non-InventoryItem subjects (the ISFluidBar tooltip) ─────────────────────
-- Vanilla reuses ISToolTipInv for other subjects: ISFluidBar:activateToolTip
-- passes a FluidContainer (or ResourceFluid) as the tooltip's item. It has
-- DoTooltip (the ObjectTooltip overload) but none of the item API — getID on
-- it is a nil-call that escapes Kahlua's pcall and logs every rendered frame
-- (the 2026-07-11 "Object tried to call nil in render (Hook.lua:915)" field
-- report, hovering the liquid tiles in the fluid-details panel).

local FluidProto = { _type = "FluidContainer" }
function FluidProto.DoTooltip(subject, tooltip)
    subject._doCalls = (subject._doCalls or 0) + 1
    tooltip:setWidth(160)
    tooltip:setHeight(40)
end
local function makeFluidContainer()
    return setmetatable({}, { __index = FluidProto })
end

tests["non_item_subject_falls_back_to_vanilla"] = function()
    reset()
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeFluidContainer())
    hookedRender(p)
    local ok = Assert.equal(p.item._doCalls, 2, "vanilla render ran untouched (both passes)")
    ok = Assert.equal(#d.calls, 0, "no dress on a non-item subject") and ok
    ok = Assert.equal(boxRec.bgA, 0.5, "vanilla box untouched") and ok
    reset()
    return ok
end

tests["prelayout_strips_reserved_contains_and_spices"] = function()
    -- FIELD REPORT: on evolved-recipe food, "Encumbrance" shares a line with
    -- "Contains" (default settings, all other mods off).
    --
    -- InventoryItem.DoTooltipEmbedded draws the name, then TWO imperative
    -- icon strips BEFORE handing back the layout — "Contains:" (extraItems,
    -- java:760) and "Spices:" (Food.spices, java:782) — each advancing its own
    -- y by lineSpacing + 5, and publishes the total in layoutOverride.offsetY.
    -- That field is not Lua-readable (see the Layout model in makeTT), and the
    -- framework hardcoded startY = padTop + lineSpacing: with a Contains strip
    -- present the first vanilla row (Encumbrance) landed ON the strip. Only
    -- items carrying these components are affected, which is why it took a
    -- soup to surface it.
    reset()
    TooltipLib.registerProvider({
        id = "StripProbe",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) ctx:addLabel("row", { 1, 1, 1, 1 }) end,
        description = "pre-layout strip probe",
    })

    local function renderAndGetY(item)
        local p = makePanel(item)
        hookedRender(p)
        return p.tooltip._layouts[#p.tooltip._layouts]._renderY
    end

    -- baseline: no strips — the name line only (padTop 5 + lineSpacing 14)
    local plain = makeItem()
    local plainY = renderAndGetY(plain)
    local ok = Assert.equal(plainY, 19, "plain item: rows start below the name line")

    -- a soup: extraItems present -> one strip reserved (lineSpacing + 5 = 19)
    local soup = makeItem()
    soup.getExtraItems = function() return { size = function() return 3 end } end
    ok = Assert.equal(renderAndGetY(soup), 19 + 19,
        "Contains strip reserved: rows clear the ingredient icons") and ok

    -- spiced soup: both strips
    local spiced = makeItem()
    spiced.getExtraItems = function() return { size = function() return 2 end } end
    spiced.getSpices = function() return { size = function() return 1 end } end
    ok = Assert.equal(renderAndGetY(spiced), 19 + 19 + 19,
        "Contains + Spices strips both reserved") and ok

    -- vanilla tests spices ~= nil with NO isEmpty check — an empty list still
    -- draws the label, so it must still be reserved
    local emptySpice = makeItem()
    emptySpice.getSpices = function() return { size = function() return 0 end } end
    ok = Assert.equal(renderAndGetY(emptySpice), 19 + 19,
        "empty-but-present spices list still draws its label") and ok

    -- an item whose class has neither method must not shift (nil method calls
    -- escape pcall in Kahlua — the guard is a field probe, not a pcall)
    local bare = makeItem()
    ok = Assert.equal(renderAndGetY(bare), 19, "items without the components are untouched") and ok

    TooltipLib.removeProvider("StripProbe")
    reset()
    return ok
end

tests["context_menu_noop_frame_is_not_a_deferrer"] = function()
    -- FIELD REPORT: "I only see the full card when I start the game. After
    -- looking at certain items the full card look disappears" — for the rest
    -- of the session, no other tooltip mod installed.
    --
    -- Vanilla ISToolTipInv:render() wraps its ENTIRE body in
    --   if not ISContextMenu.instance or not ISContextMenu.instance.visibleCheck
    -- (ISToolTipInv.lua:45, and ISToolTipItemSlot.lua:45 for the slot surface).
    -- ISContextMenu:render() sets visibleCheck = true every frame it draws. So
    -- while a context menu is open, vanilla's render is a NO-OP: item:DoTooltip
    -- is never called. That looks identical to "a foreign framework replaced
    -- our DoTooltip wrapper" — and latches TooltipLib._deferrerSeen, which
    -- consistency mode reads to stand the dress down SESSION-WIDE.
    -- Right-clicking one item must not cost the player the skin until restart.
    reset()
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local savedGate = TooltipLib._mixedDressAllowed
    TooltipLib._mixedDressAllowed = function() return false end   -- default
    local savedMenu = ISContextMenu

    local p = makePanel(makeItem())
    hookedRender(p); hookedRender(p)
    local before = #d.calls
    local ok = Assert.greater(before, 0, "dress is on before the context menu opens")

    -- right-click: menu visible, vanilla render draws nothing at all
    ISContextMenu = { instance = { visibleCheck = true } }
    p._impl = function(self) end
    hookedRender(p)
    ok = Assert.isNil(TooltipLib._deferrerSeen,
        "a context-menu no-op frame is not a foreign deferrer") and ok

    -- menu closed: normal frames resume, the card is still dressed
    ISContextMenu = { instance = { visibleCheck = false } }
    p._impl = nil
    hookedRender(p)
    ok = Assert.greater(#d.calls, before,
        "the dressed card survives a context menu (no session-wide stand-down)") and ok

    TooltipLib._mixedDressAllowed = savedGate
    ISContextMenu = savedMenu
    reset()
    return ok
end

tests["aiming_gate_suppresses_all_drawing"] = function()
    -- "Hide tooltips while aiming" (Mod Options, default ON): while the local
    -- player holds aim, renderBody returns before the render chain — nothing
    -- draws, vanilla included, no hook state mutates — and rendering resumes
    -- untouched the frame the aim ends. Untick = tooltips draw as always.
    reset()
    local savedGetPlayer = getPlayer
    local aiming = true
    getPlayer = function()
        return { isAiming = function() return aiming end }
    end

    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(p.item._doCalls or 0, 0,
        "no DoTooltip pass while aiming — the render chain never ran")

    aiming = false
    hookedRender(p)
    ok = Assert.equal(p.item._doCalls, 2,
        "render resumes normally the frame after the aim ends") and ok

    -- option OFF: tooltips draw even while aiming
    aiming = true
    TooltipLib._hideWhileAimingEnabled = function() return false end
    local p2 = makePanel(makeItem())
    hookedRender(p2)
    ok = Assert.equal(p2.item._doCalls, 2,
        "unticking the option keeps tooltips visible while aiming") and ok

    TooltipLib._hideWhileAimingEnabled = nil
    getPlayer = savedGetPlayer
    reset()
    return ok
end

tests["non_item_subject_safe_under_starlit_gate"] = function()
    -- the exact crash line: with StarlitLibrary present, the wrapper's gate
    -- read item:getID() before any subject-type check
    reset()
    local savedAdapter = TooltipLib._starlitAdapter
    TooltipLib._starlitAdapter = true
    local p = makePanel(makeFluidContainer())
    local okCall, err = pcall(hookedRender, p)
    TooltipLib._starlitAdapter = savedAdapter
    local ok = Assert.isTrue(okCall,
        "render survives a non-item subject with Starlit present: " .. tostring(err))
    ok = Assert.equal(p.item._doCalls, 2, "vanilla render still ran both passes") and ok
    return ok
end

return tests
