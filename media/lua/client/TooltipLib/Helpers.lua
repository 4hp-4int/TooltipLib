-- ============================================================================
-- TooltipLib Helpers — Colors, context methods, and static layout utilities
-- ============================================================================
-- Provides three context metatables for unified tooltip content across surfaces:
--
--   ContextMT         — Layout-based surfaces (item, itemSlot, object)
--   RichTextContextMT — Rich text surfaces (skill, vehicle)
--   RecipeContextMT   — Recipe surface (ISTableLayout widgets)
--
-- All three share the same add* method signatures:
--   ctx:addLabel, ctx:addKeyValue, ctx:addProgress, ctx:addInteger,
--   ctx:addFloat, ctx:addPercentage, ctx:addSpacer, ctx:addHeader,
--   ctx:addDivider, ctx:addText
--
-- Layout surfaces additionally support:
--   ctx:addTexture, ctx:addTextureRow
--
-- Rich text surfaces additionally support:
--   ctx:appendLine, ctx:appendKeyValue, ctx:appendRichText, ctx:setName
--
-- Static helpers (backward compat):
--   TooltipLib.Helpers.addLabel(layout, text, r, g, b, a)
--
-- NOTE: If a new method is added to ContextMT, corresponding wrappers in
-- RecordingContextMT + replayDispatch, RichTextContextMT +
-- RecordingRichTextContextMT + richTextReplayDispatch, and RecipeContextMT
-- MUST also be added.
-- ============================================================================

if isServer() then return end

require "TooltipLib/Core"
require "TooltipLib/Filters"

-- ============================================================================
-- Color palette (frozen — read-only after creation)
-- ============================================================================

---@class TooltipLibColor : table
---@field [1] number Red (0.0-1.0)
---@field [2] number Green (0.0-1.0)
---@field [3] number Blue (0.0-1.0)
---@field [4] number Alpha (0.0-1.0)

--- Freeze a table so writes error.
--- NOTE: In Lua 5.1/Kahlua, #, pairs(), ipairs(), and unpack() operate on the
--- proxy (empty table), not the real data. Always access by index: t[1], t[2].
--- To copy a frozen color: {color[1], color[2], color[3], color[4]}
local function freeze(t)
    return setmetatable({}, {
        __index = t,
        __newindex = function()
            error("[TooltipLib] Attempt to modify a frozen table. " ..
                "Copy with {color[1], color[2], color[3], color[4]} " ..
                "if you need a mutable color.", 2)
        end,
        __len = function() return #t end,
    })
end

---@class TooltipLibColors
---@field WHITE TooltipLibColor
---@field GRAY TooltipLibColor
---@field DARK_GRAY TooltipLibColor
---@field GREEN TooltipLibColor
---@field RED TooltipLibColor
---@field BLUE TooltipLibColor
---@field YELLOW TooltipLibColor
---@field GOLD TooltipLibColor
---@field ORANGE TooltipLibColor
---@field PURPLE TooltipLibColor
---@field HEADER TooltipLibColor
---@field PROGRESS TooltipLibColor

local rawColors = {
    WHITE       = { 1.0,  1.0,  1.0,  1.0 },
    GRAY        = { 0.7,  0.7,  0.7,  1.0 },
    DARK_GRAY   = { 0.5,  0.5,  0.5,  1.0 },
    GREEN       = { 0.4,  1.0,  0.4,  1.0 },
    RED         = { 1.0,  0.4,  0.4,  1.0 },
    BLUE        = { 0.4,  0.6,  1.0,  1.0 },
    YELLOW      = { 1.0,  1.0,  0.4,  1.0 },
    GOLD        = { 1.0,  0.84, 0.0,  1.0 },
    ORANGE      = { 1.0,  0.7,  0.3,  1.0 },
    PURPLE      = { 0.8,  0.4,  1.0,  1.0 },
    HEADER      = { 0.9,  0.9,  0.9,  1.0 },
    PROGRESS    = { 0.4,  0.6,  1.0,  1.0 },
}

-- Freeze each individual color array, then freeze the Colors table itself
for k, v in pairs(rawColors) do
    rawColors[k] = freeze(v)
end
TooltipLib.Colors = freeze(rawColors)

-- ============================================================================
-- Shared internal helpers (used by all three context metatables)
-- ============================================================================

--- Resolve a color table to r, g, b, a numbers. Accepts nil (use defaults)
--- or {r, g, b} / {r, g, b, a} tables.
local function resolveColor(color, defR, defG, defB, defA)
    if color == nil then
        return (defR ~= nil and defR or 1), (defG ~= nil and defG or 1),
               (defB ~= nil and defB or 1), (defA ~= nil and defA or 1)
    end
    return (color[1] ~= nil and color[1] or 1), (color[2] ~= nil and color[2] or 1),
           (color[3] ~= nil and color[3] or 1), (color[4] ~= nil and color[4] or 1)
end

--- Resolve key-value arguments from either positional or table form.
---@param keyOrOpts string|table
---@param value string?
---@param keyColor TooltipLibColor?
---@param valColor TooltipLibColor?
---@return string key, string value, TooltipLibColor? keyColor, TooltipLibColor? valueColor
local function resolveKeyValueArgs(keyOrOpts, value, keyColor, valColor)
    if type(keyOrOpts) == "table" then
        return keyOrOpts.key, keyOrOpts.value, keyOrOpts.keyColor, keyOrOpts.valueColor
    end
    return keyOrOpts, value, keyColor, valColor
end

--- Format a numeric value with sign prefix and determine color.
---@param value number
---@param decimals number
---@param highGood boolean
---@param suffix string? Optional suffix (e.g., "%")
---@return string formatted, TooltipLibColor valueColor
local function formatSignedValue(value, decimals, highGood, suffix)
    local C = TooltipLib.Colors
    local fmt = string.format("%." .. decimals .. "f", value)
    if value > 0 then fmt = "+" .. fmt end
    if suffix then fmt = fmt .. suffix end
    local vc
    if value > 0 then
        vc = highGood and C.GREEN or C.RED
    elseif value < 0 then
        vc = highGood and C.RED or C.GREEN
    else
        vc = C.WHITE
    end
    return fmt, vc
end

--- Generate a PZ rich text color tag from a color table.
---@param color TooltipLibColor {r,g,b,a}
---@return string tag e.g., "<RGB:0.4,1,0.4> "
local function rtColorTag(color)
    return string.format("<RGB:%s,%s,%s> ", color[1], color[2], color[3])
end

-- ============================================================================
-- ContextMT — Layout-based surfaces (item, itemSlot, object)
-- ============================================================================
-- One shared metatable; each context table gets setmetatable(ctx, ContextMT).
-- Methods delegate to self.layout which is set in Hook.lua Phase 2.
--
-- NOTE: If a new method is added here, corresponding wrappers in
-- RecordingContextMT + replayDispatch MUST also be added.
-- Layout-adding methods must call maybeInsertSeparator() and increment _itemCount.
-- ============================================================================

---@class TooltipLibContext
---@field item InventoryItem? The item being tooltipped (item/itemSlot surfaces)
---@field object IsoObject? The world object being hovered (object surface)
---@field square IsoGridSquare? The grid square of the hovered object (object surface)
---@field tooltip ObjectTooltip The Java tooltip object
---@field layout ObjectTooltip_Layout? Current layout (only in callback phase)
---@field helpers TooltipLibHelpers? Static helper functions
---@field detail boolean True when detail modifier key is held (e.g., Shift)
---@field surface string Surface name ("item", "itemSlot", "object")
---@field endY number? Bottom Y position (only in postRender phase)
---@field width number? Tooltip width (only in postRender phase)
---@field padLeft number? Left padding (only in postRender phase)
---@field padRight number? Right padding (only in postRender phase)
---@field padBottom number? Bottom padding (only in postRender phase)

local ContextMT = {}
ContextMT.__index = ContextMT

local function requireLayout(self, method)
    if not self.layout then
        error("[TooltipLib] ctx:" .. method ..
            "() requires layout — only available during callback phase", 3)
    end
end

--- Insert a deferred auto-separator (spacer) if flagged by the framework.
--- Called at the top of every layout-adding method. The _needsSeparator flag
--- is set by Hook.lua before each provider's callback runs.
local function maybeInsertSeparator(self)
    if self._needsSeparator then
        self._needsSeparator = false
        local sepItem = self.layout:addItem()
        sepItem:setLabel(" ", 1, 1, 1, 1)
    end
end

--- Add a colored label line.
---@param text string
---@param color TooltipLibColor? {r,g,b,a} or nil for white
---@return ObjectTooltip_LayoutItem
function ContextMT:addLabel(text, color)
    requireLayout(self, "addLabel")
    maybeInsertSeparator(self)
    local r, g, b, a = resolveColor(color, 1, 1, 1, 1)
    local item = self.layout:addItem()
    item:setLabel(text, r, g, b, a)
    self._itemCount = (self._itemCount or 0) + 1
    return item
end

--- Add a key-value pair line.
--- Supports two calling conventions:
---   ctx:addKeyValue("Key:", "Value", keyColor, valColor)
---   ctx:addKeyValue({ key = "Key:", value = "Value", keyColor = ..., valueColor = ... })
---@param keyOrOpts string|table
---@param value string?
---@param keyColor TooltipLibColor?
---@param valColor TooltipLibColor?
---@return ObjectTooltip_LayoutItem
function ContextMT:addKeyValue(keyOrOpts, value, keyColor, valColor)
    requireLayout(self, "addKeyValue")
    maybeInsertSeparator(self)
    local key, val, kc, vc = resolveKeyValueArgs(keyOrOpts, value, keyColor, valColor)
    local kr, kg, kb, ka = resolveColor(kc, 1, 1, 1, 1)
    local vr, vg, vb, va = resolveColor(vc, 1, 1, 1, 1)
    local item = self.layout:addItem()
    item:setLabel(key, kr, kg, kb, ka)
    item:setValue(val, vr, vg, vb, va)
    self._itemCount = (self._itemCount or 0) + 1
    return item
end

--- Add a progress bar line.
---@param label string
---@param fraction number 0.0-1.0
---@param labelColor TooltipLibColor?
---@param barColor TooltipLibColor? Defaults to PROGRESS blue
---@return ObjectTooltip_LayoutItem
function ContextMT:addProgress(label, fraction, labelColor, barColor)
    requireLayout(self, "addProgress")
    maybeInsertSeparator(self)
    local C = TooltipLib.Colors
    local lr, lg, lb, la = resolveColor(labelColor, 1, 1, 1, 1)
    local br, bg, bb, ba = resolveColor(barColor, C.PROGRESS[1], C.PROGRESS[2], C.PROGRESS[3], C.PROGRESS[4])
    local item = self.layout:addItem()
    item:setLabel(label, lr, lg, lb, la)
    -- PZ's ObjectTooltip_Layout passes widthValueRight as the render
    -- width for progress bars. Without any setValue/setValueRight calls
    -- in the layout, widthValueRight is 0 and bars render at 0 width.
    -- Item tooltips avoid this because vanilla DoTooltipEmbedded items
    -- establish column widths, but object tooltips have no vanilla items.
    -- Fix: setValueRight sets rightJustify=true, then setValue overrides
    -- the formatted text with invisible padding that sizes the column.
    item:setValueRight(0, true)
    item:setValue(string.rep(" ", 12), 0, 0, 0, 0)
    item:setProgress(fraction or 0, br, bg, bb, ba)
    self._itemCount = (self._itemCount or 0) + 1
    return item
end

--- Add an integer value with +/- coloring (Java built-in).
---@param label string
---@param value integer
---@param highGood boolean True = positive is green, false = positive is red
---@param labelColor TooltipLibColor?
---@return ObjectTooltip_LayoutItem
function ContextMT:addInteger(label, value, highGood, labelColor)
    requireLayout(self, "addInteger")
    maybeInsertSeparator(self)
    local r, g, b, a = resolveColor(labelColor, 1, 1, 1, 1)
    local item = self.layout:addItem()
    item:setLabel(label, r, g, b, a)
    item:setValueRight(value, highGood)
    self._itemCount = (self._itemCount or 0) + 1
    return item
end

--- Add a blank spacer line.
---@return ObjectTooltip_LayoutItem
function ContextMT:addSpacer()
    requireLayout(self, "addSpacer")
    maybeInsertSeparator(self)
    local item = self.layout:addItem()
    item:setLabel(" ", 1, 1, 1, 1)
    self._itemCount = (self._itemCount or 0) + 1
    return item
end

--- Add a section header with automatic leading spacer.
---@param text string
---@param color TooltipLibColor? Defaults to HEADER gray
---@param noSpacer boolean? Pass true to suppress the automatic leading spacer
---@return ObjectTooltip_LayoutItem
function ContextMT:addHeader(text, color, noSpacer)
    requireLayout(self, "addHeader")
    maybeInsertSeparator(self)
    if not noSpacer and (self._itemCount or 0) > 0 then
        local spacerItem = self.layout:addItem()
        spacerItem:setLabel(" ", 1, 1, 1, 1)
    end
    local C = TooltipLib.Colors
    local r, g, b, a = resolveColor(color, C.HEADER[1], C.HEADER[2], C.HEADER[3], C.HEADER[4])
    local item = self.layout:addItem()
    item:setLabel(text, r, g, b, a)
    self._itemCount = (self._itemCount or 0) + 1
    return item
end

--- Add a visual divider line (thin progress bar).
---@param color TooltipLibColor? Defaults to muted gray
---@return ObjectTooltip_LayoutItem
function ContextMT:addDivider(color)
    requireLayout(self, "addDivider")
    maybeInsertSeparator(self)
    local r, g, b, a = resolveColor(color, 0.35, 0.35, 0.35, 0.6)
    local item = self.layout:addItem()
    item:setLabel(" ", 0, 0, 0, 0)
    item:setProgress(1.0, r, g, b, a)
    self._itemCount = (self._itemCount or 0) + 1
    return item
end

--- Add multi-line text with automatic word wrapping at tooltip width.
---@param text string
---@param color TooltipLibColor?
---@param maxWidth number? Override wrap width in pixels
---@return ObjectTooltip_LayoutItem? lastItem
function ContextMT:addText(text, color, maxWidth)
    requireLayout(self, "addText")
    if not text or text == "" then return nil end
    maybeInsertSeparator(self)
    local r, g, b, a = resolveColor(color, 1, 1, 1, 1)
    local wrapAt = maxWidth or 250
    if not maxWidth then
        pcall(function()
            local tw = self.tooltip:getWidth()
            if tw and tw > 50 then
                local pl = self.tooltip.padLeft or 5
                local pr = self.tooltip.padRight or 5
                wrapAt = tw - pl - pr - 10
            end
        end)
    end
    local tm = getTextManager()
    local font = UIFont.Small
    local lines = {}
    local current = ""
    for word in text:gmatch("%S+") do
        local test = current == "" and word or (current .. " " .. word)
        if tm:MeasureStringX(font, test) > wrapAt and current ~= "" then
            lines[#lines + 1] = current
            current = word
        else
            current = test
        end
    end
    if current ~= "" then
        lines[#lines + 1] = current
    end
    local lastItem
    for i = 1, #lines do
        local item = self.layout:addItem()
        item:setLabel(lines[i], r, g, b, a)
        lastItem = item
    end
    self._itemCount = (self._itemCount or 0) + #lines
    return lastItem
end

--- Add a formatted floating-point value with +/- coloring.
---@param label string
---@param value number
---@param decimals number? Decimal places (default 1)
---@param highGood boolean? True = positive is green (default true)
---@param labelColor TooltipLibColor?
---@return ObjectTooltip_LayoutItem
function ContextMT:addFloat(label, value, decimals, highGood, labelColor)
    requireLayout(self, "addFloat")
    maybeInsertSeparator(self)
    local dec = decimals or 1
    local hg = (highGood == nil) and true or highGood
    local fmt, vc = formatSignedValue(value, dec, hg)
    local lr, lg, lb, la = resolveColor(labelColor, 1, 1, 1, 1)
    local vr, vg, vb, va = resolveColor(vc)
    local item = self.layout:addItem()
    item:setLabel(label, lr, lg, lb, la)
    item:setValue(fmt, vr, vg, vb, va)
    self._itemCount = (self._itemCount or 0) + 1
    return item
end

--- Add a percentage value with +/- coloring.
---@param label string
---@param fraction number 0.0-1.0 range (displayed as 0-100%)
---@param decimals number? Decimal places (default 0)
---@param highGood boolean? True = positive percentage is green (default true)
---@param labelColor TooltipLibColor?
---@return ObjectTooltip_LayoutItem
function ContextMT:addPercentage(label, fraction, decimals, highGood, labelColor)
    requireLayout(self, "addPercentage")
    maybeInsertSeparator(self)
    local dec = decimals or 0
    local hg = (highGood == nil) and true or highGood
    local pct = fraction * 100
    local fmt, vc = formatSignedValue(pct, dec, hg, "%")
    local lr, lg, lb, la = resolveColor(labelColor, 1, 1, 1, 1)
    local vr, vg, vb, va = resolveColor(vc)
    local item = self.layout:addItem()
    item:setLabel(label, lr, lg, lb, la)
    item:setValue(fmt, vr, vg, vb, va)
    self._itemCount = (self._itemCount or 0) + 1
    return item
end

--- Queue a single texture to be drawn below the layout.
---@param texture Texture PZ texture object
---@param width number? Render width (default 32)
---@param height number? Render height (default 32)
function ContextMT:addTexture(texture, width, height)
    if not self._textureQueue then self._textureQueue = {} end
    self._textureQueue[#self._textureQueue + 1] = {
        type = "single",
        texture = texture,
        width = width or 32,
        height = height or 32,
    }
end

--- Queue a row of textures to be drawn below the layout (auto-wrapping).
---@param textures Texture[] Array of PZ texture objects
---@param iconSize number? Icon width and height (default 16)
---@param spacing number? Gap between icons (default 2)
function ContextMT:addTextureRow(textures, iconSize, spacing)
    if not self._textureQueue then self._textureQueue = {} end
    self._textureQueue[#self._textureQueue + 1] = {
        type = "row",
        textures = textures,
        iconSize = iconSize or 16,
        spacing = spacing or 2,
    }
end

--- Bulk-read Java methods on ctx.object with pcall protection.
--- Returns a table mapping friendly names to method return values.
--- Methods that fail or don't exist return nil (key absent from result).
--- Only useful on object surface — returns empty table if ctx.object is nil.
---
--- Usage:
---   local data = ctx:readObject({
---       activated = "isActivated",
---       fuel = "getFuelPercentage",
---   })
---   if data.activated then ... end
---@param fieldMap table<string, string> Map of result key -> Java method name
---@return table<string, any> Result table (nil values omitted)
function ContextMT:readObject(fieldMap)
    local obj = self.object
    if not obj then return {} end
    local result = {}
    for key, method in pairs(fieldMap) do
        local fn = obj[method]
        if fn then
            local ok, val = pcall(fn, obj)
            if ok then result[key] = val end
        end
    end
    return result
end

--- Safe single method call on ctx.object with pcall protection.
--- Returns the method's return value, or nil on error / missing method.
--- Only useful on object surface — returns nil if ctx.object is nil.
---
--- Usage:
---   local fuel = ctx:safeCall("getFuelPercentage")
---@param methodName string Java method name on the object
---@param ... any Additional arguments to pass to the method
---@return any|nil Return value or nil on error
function ContextMT:safeCall(methodName, ...)
    local obj = self.object
    if not obj then return nil end
    local fn = obj[methodName]
    if not fn then return nil end
    local ok, val = pcall(fn, obj, ...)
    if ok then return val end
    return nil
end

-- Expose for Hook.lua
TooltipLib._ContextMT = ContextMT

-- ============================================================================
-- RichTextContextMT — Rich text surfaces (skill, vehicle)
-- ============================================================================
-- ISToolTip renders via ISRichTextPanel. Content is a rich text string with
-- PZ markup tags (<RGB:r,g,b>, <LINE>, <SETX:n>, <SIZE:medium>, etc.).
-- Providers build content through the unified add* methods; the framework
-- concatenates lines and sets tooltip.description.
--
-- The add* methods match ContextMT signatures for cross-surface portability.
-- Surface-specific methods (appendLine, appendRichText, setName) are also
-- available for providers that need raw rich text control.
--
-- Limitations vs Layout surfaces:
--   - No column alignment across providers (SETX aligns within each provider)
--   - No visual progress bars (rendered as colored percentage text)
--   - No addTexture/addTextureRow (use appendRichText with <IMAGE:path> if needed)
--
-- NOTE: If a new method is added here, a corresponding wrapper in
-- RecordingRichTextContextMT and an entry in richTextReplayDispatch
-- MUST also be added.
-- ============================================================================

---@class TooltipLibRichTextContext
---@field tooltip ISToolTip The ISToolTip object
---@field surface string Surface name ("skill" or "vehicle")
---@field detail boolean True when detail modifier key is held
---@field perk PerkFactory_Perk? Perk being hovered (skill surface)
---@field level number? Current perk level (skill surface)
---@field player IsoGameCharacter? The player character (skill/vehicle surfaces)
---@field part VehiclePart? Vehicle part being hovered (vehicle surface)
---@field vehicle BaseVehicle? The vehicle (vehicle surface)
---@field _lines table Internal line accumulator

local RichTextContextMT = {}
RichTextContextMT.__index = RichTextContextMT

--- Insert a deferred auto-separator for rich text surfaces.
local function maybeInsertRichTextSeparator(self)
    if self._needsSeparator then
        self._needsSeparator = false
        self._lines[#self._lines + 1] = " "
    end
end

-- ---------------------------------------------------------------------------
-- Unified methods (same signatures as ContextMT)
-- ---------------------------------------------------------------------------

--- Add a colored label line.
---@param text string
---@param color TooltipLibColor?
function RichTextContextMT:addLabel(text, color)
    maybeInsertRichTextSeparator(self)
    local prefix = ""
    if color then prefix = rtColorTag(color) end
    self._lines[#self._lines + 1] = prefix .. tostring(text)
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a key-value pair with measured alignment.
---@param keyOrOpts string|table
---@param value string?
---@param keyColor TooltipLibColor?
---@param valColor TooltipLibColor?
function RichTextContextMT:addKeyValue(keyOrOpts, value, keyColor, valColor)
    maybeInsertRichTextSeparator(self)
    local key, val, kc, vc = resolveKeyValueArgs(keyOrOpts, value, keyColor, valColor)
    local tm = getTextManager()
    local keyWidth = tm:MeasureStringX(UIFont.Small, tostring(key))
    local valueX = math.max(math.floor(keyWidth + 10), 120)
    local line = ""
    if kc then line = rtColorTag(kc) end
    line = line .. tostring(key) .. " <SETX:" .. valueX .. "> "
    if vc then line = line .. rtColorTag(vc) end
    line = line .. tostring(val)
    self._lines[#self._lines + 1] = line
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a progress indicator (text percentage — no visual bar in rich text).
---@param label string
---@param fraction number 0.0-1.0
---@param labelColor TooltipLibColor?
---@param barColor TooltipLibColor? Color for percentage text (defaults to PROGRESS)
function RichTextContextMT:addProgress(label, fraction, labelColor, barColor)
    maybeInsertRichTextSeparator(self)
    local C = TooltipLib.Colors
    local pct = math.floor((fraction or 0) * 100 + 0.5)
    local bc = barColor or C.PROGRESS
    local tm = getTextManager()
    local keyWidth = tm:MeasureStringX(UIFont.Small, tostring(label))
    local valueX = math.max(math.floor(keyWidth + 10), 120)
    local line = ""
    if labelColor then line = rtColorTag(labelColor) end
    line = line .. tostring(label) .. " <SETX:" .. valueX .. "> " .. rtColorTag(bc) .. pct .. "%"
    self._lines[#self._lines + 1] = line
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add an integer value with +/- coloring.
---@param label string
---@param value integer
---@param highGood boolean
---@param labelColor TooltipLibColor?
function RichTextContextMT:addInteger(label, value, highGood, labelColor)
    maybeInsertRichTextSeparator(self)
    local hg = (highGood == nil) and true or highGood
    local fmt, vc = formatSignedValue(value, 0, hg)
    local tm = getTextManager()
    local keyWidth = tm:MeasureStringX(UIFont.Small, tostring(label))
    local valueX = math.max(math.floor(keyWidth + 10), 120)
    local line = ""
    if labelColor then line = rtColorTag(labelColor) end
    line = line .. tostring(label) .. " <SETX:" .. valueX .. "> " .. rtColorTag(vc) .. fmt
    self._lines[#self._lines + 1] = line
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a formatted floating-point value with +/- coloring.
---@param label string
---@param value number
---@param decimals number? Default 1
---@param highGood boolean? Default true
---@param labelColor TooltipLibColor?
function RichTextContextMT:addFloat(label, value, decimals, highGood, labelColor)
    maybeInsertRichTextSeparator(self)
    local dec = decimals or 1
    local hg = (highGood == nil) and true or highGood
    local fmt, vc = formatSignedValue(value, dec, hg)
    local tm = getTextManager()
    local keyWidth = tm:MeasureStringX(UIFont.Small, tostring(label))
    local valueX = math.max(math.floor(keyWidth + 10), 120)
    local line = ""
    if labelColor then line = rtColorTag(labelColor) end
    line = line .. tostring(label) .. " <SETX:" .. valueX .. "> " .. rtColorTag(vc) .. fmt
    self._lines[#self._lines + 1] = line
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a percentage value with +/- coloring.
---@param label string
---@param fraction number 0.0-1.0
---@param decimals number? Default 0
---@param highGood boolean? Default true
---@param labelColor TooltipLibColor?
function RichTextContextMT:addPercentage(label, fraction, decimals, highGood, labelColor)
    maybeInsertRichTextSeparator(self)
    local dec = decimals or 0
    local hg = (highGood == nil) and true or highGood
    local pct = fraction * 100
    local fmt, vc = formatSignedValue(pct, dec, hg, "%")
    local tm = getTextManager()
    local keyWidth = tm:MeasureStringX(UIFont.Small, tostring(label))
    local valueX = math.max(math.floor(keyWidth + 10), 120)
    local line = ""
    if labelColor then line = rtColorTag(labelColor) end
    line = line .. tostring(label) .. " <SETX:" .. valueX .. "> " .. rtColorTag(vc) .. fmt
    self._lines[#self._lines + 1] = line
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a blank spacer line.
function RichTextContextMT:addSpacer()
    maybeInsertRichTextSeparator(self)
    self._lines[#self._lines + 1] = " "
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a section header with automatic leading spacer.
---@param text string
---@param color TooltipLibColor? Defaults to HEADER
---@param noSpacer boolean? Suppress leading spacer
function RichTextContextMT:addHeader(text, color, noSpacer)
    maybeInsertRichTextSeparator(self)
    if not noSpacer and (self._itemCount or 0) > 0 then
        self._lines[#self._lines + 1] = " "
    end
    local C = TooltipLib.Colors
    local c = color or C.HEADER
    self._lines[#self._lines + 1] = "<SIZE:medium> " .. rtColorTag(c) .. tostring(text)
    self._itemCount = (self._itemCount or 0) + 1
end

local DEFAULT_DIVIDER_COLOR = { 0.35, 0.35, 0.35, 0.6 }

--- Add a visual divider line (dashes).
---@param color TooltipLibColor? Defaults to muted gray
function RichTextContextMT:addDivider(color)
    maybeInsertRichTextSeparator(self)
    local c = color or DEFAULT_DIVIDER_COLOR
    self._lines[#self._lines + 1] = rtColorTag(c) .. "----------------"
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add text (ISRichTextPanel handles word wrapping natively).
---@param text string
---@param color TooltipLibColor?
---@param maxWidth number? Ignored on rich text (ISRichTextPanel auto-wraps)
function RichTextContextMT:addText(text, color, maxWidth)
    if not text or text == "" then return end
    maybeInsertRichTextSeparator(self)
    local prefix = ""
    if color then prefix = rtColorTag(color) end
    self._lines[#self._lines + 1] = prefix .. tostring(text)
    self._itemCount = (self._itemCount or 0) + 1
end

-- ---------------------------------------------------------------------------
-- Native rich text methods (not available on other surfaces)
-- ---------------------------------------------------------------------------

--- Append a colored line of text (native rich text method).
---@param text string
---@param color TooltipLibColor?
function RichTextContextMT:appendLine(text, color)
    local prefix = ""
    if color then prefix = rtColorTag(color) end
    self._lines[#self._lines + 1] = prefix .. tostring(text)
end

--- Append a key-value pair (native rich text method, no SETX alignment).
---@param key string
---@param value string
---@param keyColor TooltipLibColor?
---@param valueColor TooltipLibColor?
function RichTextContextMT:appendKeyValue(key, value, keyColor, valueColor)
    local line = ""
    if keyColor then line = rtColorTag(keyColor) end
    line = line .. tostring(key) .. " "
    if valueColor then line = line .. rtColorTag(valueColor) end
    line = line .. tostring(value)
    self._lines[#self._lines + 1] = line
end

--- Append raw PZ rich text markup.
---@param markup string Raw PZ rich text
function RichTextContextMT:appendRichText(markup)
    self._lines[#self._lines + 1] = markup
end

--- Set the tooltip title (ISToolTip.name field).
---@param text string
function RichTextContextMT:setName(text)
    if self.tooltip then
        self.tooltip.name = text
    end
end

-- Expose for hook files
TooltipLib._RichTextContextMT = RichTextContextMT

-- ============================================================================
-- RecipeContentPanel — ISPanel subclass for rendering provider content
-- ============================================================================
-- Stores content entries as data during callbacks and draws them in prerender().
-- This gives full control over multi-color text, progress bars, and alignment
-- without requiring providers to know ISPanel internals.
-- ============================================================================

local RecipeContentPanel = ISPanel:derive("TooltipLib_RecipePanel")

function RecipeContentPanel:new(x, y, w, h)
    local o = ISPanel.new(self, x, y, w, h)
    o._entries = {}
    o._totalHeight = 0
    o.background = false
    return o
end

function RecipeContentPanel:addEntry(entry)
    self._entries[#self._entries + 1] = entry
    -- Estimate height for ISTableLayout sizing
    local tm = getTextManager()
    local font = entry.font or UIFont.Small
    local fontH = tm:getFontHeight(font) + 2
    local h = entry.height or fontH
    self._totalHeight = self._totalHeight + h
    self:setHeight(self._totalHeight)
end

function RecipeContentPanel:prerender()
    local tm = getTextManager()
    local panelW = self:getWidth()
    local panelH = self:getHeight()

    -- Accent bar offset (2px bar + 1px gap)
    local accentW = self.accentColor and 3 or 0
    local padX = 5 + accentW

    -- Background tint (drawn first, behind content)
    if self.bgColor then
        local bg = self.bgColor
        self:drawRect(0, 0, panelW, panelH, bg[4], bg[1], bg[2], bg[3])
    end

    -- Accent bar
    if self.accentColor then
        local ac = self.accentColor
        self:drawRect(0, 0, 2, panelH, ac[4], ac[1], ac[2], ac[3])
    end

    local y = 0

    for i = 1, #self._entries do
        local e = self._entries[i]
        local font = e.font or UIFont.Small
        local fontH = tm:getFontHeight(font) + 2

        if e.type == "label" then
            self:drawText(e.text, padX, y, e.r, e.g, e.b, e.a, font)
            y = y + fontH

        elseif e.type == "keyvalue" then
            self:drawText(e.key, padX, y, e.kr, e.kg, e.kb, e.ka, font)
            local keyW = tm:MeasureStringX(font, e.key)
            local valueX = math.max(math.floor(padX + keyW + 10), 120)
            self:drawText(e.value, valueX, y, e.vr, e.vg, e.vb, e.va, font)
            y = y + fontH

        elseif e.type == "progress" then
            self:drawText(e.label, padX, y, e.lr, e.lg, e.lb, e.la, font)
            local labelW = tm:MeasureStringX(font, e.label)
            local barX = math.max(math.floor(padX + labelW + 10), 120)
            local barW = math.max(panelW - barX - 40, 30)
            local barH = fontH - 6
            local barY = y + 3
            -- Background
            self:drawRect(barX, barY, barW, barH, 0.3, 0.3, 0.3, 0.3)
            -- Fill
            local fillW = barW * math.max(0, math.min(1, e.fraction))
            self:drawRect(barX, barY, fillW, barH, e.ba, e.br, e.bg, e.bb)
            -- Percentage text
            local pctText = tostring(math.floor(e.fraction * 100 + 0.5)) .. "%"
            self:drawText(pctText, barX + barW + 5, y, e.lr, e.lg, e.lb, e.la, font)
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
            -- Word-wrap at panel width
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

    -- Update actual height after rendering
    if y ~= self._totalHeight then
        self._totalHeight = y
        self:setHeight(y)
    end
end

-- ============================================================================
-- RecipeContextMT — Recipe surface (ISTableLayout widgets)
-- ============================================================================
-- Provides the same add* methods as ContextMT and RichTextContextMT.
-- Under the hood, methods add entries to a RecipeContentPanel which draws
-- them via drawText/drawRect in prerender. ctx.rootTable remains accessible
-- for providers that need direct ISTableLayout widget control.
--
-- Caching is NOT supported for recipe providers (ISPanel objects are stateful).
-- ============================================================================

---@class TooltipLibRecipeContext
---@field recipe CraftRecipe The recipe being displayed
---@field logic table? HandcraftLogic reference (may be nil for floating tooltip fallback)
---@field player IsoGameCharacter? The player character
---@field tooltip table The ISCraftRecipePanel instance
---@field rootTable ISTableLayout Direct widget access for ISTableLayout API
---@field surface string Surface name ("recipe")
---@field detail boolean True when detail modifier key is held
---@field _panel RecipeContentPanel Internal panel used by add* methods

local RecipeContextMT = {}
RecipeContextMT.__index = RecipeContextMT

--- Insert a deferred auto-separator for recipe surfaces.
local function maybeInsertRecipeSeparator(self)
    if self._needsSeparator then
        self._needsSeparator = false
        self._panel:addEntry({ type = "spacer" })
    end
end

--- Add a colored label line.
---@param text string
---@param color TooltipLibColor?
function RecipeContextMT:addLabel(text, color)
    maybeInsertRecipeSeparator(self)
    local r, g, b, a = resolveColor(color, 1, 1, 1, 1)
    self._panel:addEntry({ type = "label", text = tostring(text), r = r, g = g, b = b, a = a })
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a key-value pair with measured alignment.
---@param keyOrOpts string|table
---@param value string?
---@param keyColor TooltipLibColor?
---@param valColor TooltipLibColor?
function RecipeContextMT:addKeyValue(keyOrOpts, value, keyColor, valColor)
    maybeInsertRecipeSeparator(self)
    local key, val, kc, vc = resolveKeyValueArgs(keyOrOpts, value, keyColor, valColor)
    local kr, kg, kb, ka = resolveColor(kc, 1, 1, 1, 1)
    local vr, vg, vb, va = resolveColor(vc, 1, 1, 1, 1)
    self._panel:addEntry({
        type = "keyvalue",
        key = tostring(key), value = tostring(val),
        kr = kr, kg = kg, kb = kb, ka = ka,
        vr = vr, vg = vg, vb = vb, va = va,
    })
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a progress bar (actual visual bar on recipe surface).
---@param label string
---@param fraction number 0.0-1.0
---@param labelColor TooltipLibColor?
---@param barColor TooltipLibColor? Defaults to PROGRESS blue
function RecipeContextMT:addProgress(label, fraction, labelColor, barColor)
    maybeInsertRecipeSeparator(self)
    local C = TooltipLib.Colors
    local lr, lg, lb, la = resolveColor(labelColor, 1, 1, 1, 1)
    local br, bg, bb, ba = resolveColor(barColor, C.PROGRESS[1], C.PROGRESS[2], C.PROGRESS[3], C.PROGRESS[4])
    self._panel:addEntry({
        type = "progress",
        label = tostring(label), fraction = fraction or 0,
        lr = lr, lg = lg, lb = lb, la = la,
        br = br, bg = bg, bb = bb, ba = ba,
    })
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add an integer value with +/- coloring.
---@param label string
---@param value integer
---@param highGood boolean
---@param labelColor TooltipLibColor?
function RecipeContextMT:addInteger(label, value, highGood, labelColor)
    maybeInsertRecipeSeparator(self)
    local hg = (highGood == nil) and true or highGood
    local fmt, vc = formatSignedValue(value, 0, hg)
    local lr, lg, lb, la = resolveColor(labelColor, 1, 1, 1, 1)
    local vr, vg, vb, va = resolveColor(vc)
    self._panel:addEntry({
        type = "keyvalue",
        key = tostring(label), value = fmt,
        kr = lr, kg = lg, kb = lb, ka = la,
        vr = vr, vg = vg, vb = vb, va = va,
    })
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a formatted floating-point value with +/- coloring.
---@param label string
---@param value number
---@param decimals number? Default 1
---@param highGood boolean? Default true
---@param labelColor TooltipLibColor?
function RecipeContextMT:addFloat(label, value, decimals, highGood, labelColor)
    maybeInsertRecipeSeparator(self)
    local dec = decimals or 1
    local hg = (highGood == nil) and true or highGood
    local fmt, vc = formatSignedValue(value, dec, hg)
    local lr, lg, lb, la = resolveColor(labelColor, 1, 1, 1, 1)
    local vr, vg, vb, va = resolveColor(vc)
    self._panel:addEntry({
        type = "keyvalue",
        key = tostring(label), value = fmt,
        kr = lr, kg = lg, kb = lb, ka = la,
        vr = vr, vg = vg, vb = vb, va = va,
    })
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a percentage value with +/- coloring.
---@param label string
---@param fraction number 0.0-1.0
---@param decimals number? Default 0
---@param highGood boolean? Default true
---@param labelColor TooltipLibColor?
function RecipeContextMT:addPercentage(label, fraction, decimals, highGood, labelColor)
    maybeInsertRecipeSeparator(self)
    local dec = decimals or 0
    local hg = (highGood == nil) and true or highGood
    local pct = fraction * 100
    local fmt, vc = formatSignedValue(pct, dec, hg, "%")
    local lr, lg, lb, la = resolveColor(labelColor, 1, 1, 1, 1)
    local vr, vg, vb, va = resolveColor(vc)
    self._panel:addEntry({
        type = "keyvalue",
        key = tostring(label), value = fmt,
        kr = lr, kg = lg, kb = lb, ka = la,
        vr = vr, vg = vg, vb = vb, va = va,
    })
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a blank spacer line.
function RecipeContextMT:addSpacer()
    maybeInsertRecipeSeparator(self)
    self._panel:addEntry({ type = "spacer" })
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a section header with automatic leading spacer.
---@param text string
---@param color TooltipLibColor? Defaults to HEADER
---@param noSpacer boolean? Suppress leading spacer
function RecipeContextMT:addHeader(text, color, noSpacer)
    maybeInsertRecipeSeparator(self)
    if not noSpacer and (self._itemCount or 0) > 0 then
        self._panel:addEntry({ type = "spacer" })
    end
    local C = TooltipLib.Colors
    local r, g, b, a = resolveColor(color, C.HEADER[1], C.HEADER[2], C.HEADER[3], C.HEADER[4])
    self._panel:addEntry({
        type = "header", text = tostring(text),
        r = r, g = g, b = b, a = a,
        font = UIFont.Medium,
    })
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add a visual divider line.
---@param color TooltipLibColor? Defaults to muted gray
function RecipeContextMT:addDivider(color)
    maybeInsertRecipeSeparator(self)
    local r, g, b, a = resolveColor(color, 0.35, 0.35, 0.35, 0.6)
    self._panel:addEntry({ type = "divider", r = r, g = g, b = b, a = a })
    self._itemCount = (self._itemCount or 0) + 1
end

--- Add multi-line text (word-wrapped at panel width during render).
---@param text string
---@param color TooltipLibColor?
---@param maxWidth number? Ignored on recipe (panel width used)
function RecipeContextMT:addText(text, color, maxWidth)
    if not text or text == "" then return end
    maybeInsertRecipeSeparator(self)
    local r, g, b, a = resolveColor(color, 1, 1, 1, 1)
    -- Estimate line count for height (will be corrected in prerender)
    local lineCount = 1
    pcall(function()
        local tm = getTextManager()
        local accentW = self._panel.accentColor and 3 or 0
        local padX = 5 + accentW
        local panelW = self._panel:getWidth()
        local wrapAt = maxWidth or (panelW > 0 and (panelW - padX * 2 - 5) or 200)
        local current = ""
        lineCount = 0
        for word in text:gmatch("%S+") do
            local test = current == "" and word or (current .. " " .. word)
            if tm:MeasureStringX(UIFont.Small, test) > wrapAt and current ~= "" then
                lineCount = lineCount + 1
                current = word
            else
                current = test
            end
        end
        if current ~= "" then lineCount = lineCount + 1 end
    end)
    local tm = getTextManager()
    local fontH = tm:getFontHeight(UIFont.Small) + 2
    self._panel:addEntry({
        type = "text", text = tostring(text),
        r = r, g = g, b = b, a = a,
        height = fontH * math.max(1, lineCount),
    })
    self._itemCount = (self._itemCount or 0) + 1
end

-- Expose for hook files
TooltipLib._RecipeContextMT = RecipeContextMT
TooltipLib._RecipeContentPanel = RecipeContentPanel

-- ============================================================================
-- RecordingRichTextContextMT — captures rich text calls for caching
-- ============================================================================

local RecordingRichTextContextMT = {}

RecordingRichTextContextMT.__index = function(self, key)
    local method = rawget(RecordingRichTextContextMT, key)
    if method ~= nil then return method end
    return self._realCtx[key]
end

RecordingRichTextContextMT.__newindex = function(self, key, value)
    self._realCtx[key] = value
end

-- Native methods
function RecordingRichTextContextMT:appendLine(text, color)
    self._displayList[#self._displayList + 1] = { "appendLine", text, color }
    return self._realCtx:appendLine(text, color)
end

function RecordingRichTextContextMT:appendKeyValue(key, value, keyColor, valueColor)
    self._displayList[#self._displayList + 1] = { "appendKeyValue", key, value, keyColor, valueColor }
    return self._realCtx:appendKeyValue(key, value, keyColor, valueColor)
end

function RecordingRichTextContextMT:appendRichText(markup)
    self._displayList[#self._displayList + 1] = { "appendRichText", markup }
    return self._realCtx:appendRichText(markup)
end

function RecordingRichTextContextMT:setName(text)
    self._displayList[#self._displayList + 1] = { "setName", text }
    return self._realCtx:setName(text)
end

-- Unified methods
function RecordingRichTextContextMT:addLabel(text, color)
    self._displayList[#self._displayList + 1] = { "addLabel", text, color }
    return self._realCtx:addLabel(text, color)
end

function RecordingRichTextContextMT:addKeyValue(keyOrOpts, value, keyColor, valColor)
    local recorded = keyOrOpts
    if type(keyOrOpts) == "table" then
        recorded = {
            key = keyOrOpts.key, value = keyOrOpts.value,
            keyColor = keyOrOpts.keyColor, valueColor = keyOrOpts.valueColor
        }
    end
    self._displayList[#self._displayList + 1] = { "addKeyValue", recorded, value, keyColor, valColor }
    return self._realCtx:addKeyValue(keyOrOpts, value, keyColor, valColor)
end

function RecordingRichTextContextMT:addProgress(label, fraction, labelColor, barColor)
    self._displayList[#self._displayList + 1] = { "addProgress", label, fraction, labelColor, barColor }
    return self._realCtx:addProgress(label, fraction, labelColor, barColor)
end

function RecordingRichTextContextMT:addInteger(label, value, highGood, labelColor)
    self._displayList[#self._displayList + 1] = { "addInteger", label, value, highGood, labelColor }
    return self._realCtx:addInteger(label, value, highGood, labelColor)
end

function RecordingRichTextContextMT:addFloat(label, value, decimals, highGood, labelColor)
    self._displayList[#self._displayList + 1] = { "addFloat", label, value, decimals, highGood, labelColor }
    return self._realCtx:addFloat(label, value, decimals, highGood, labelColor)
end

function RecordingRichTextContextMT:addPercentage(label, fraction, decimals, highGood, labelColor)
    self._displayList[#self._displayList + 1] = { "addPercentage", label, fraction, decimals, highGood, labelColor }
    return self._realCtx:addPercentage(label, fraction, decimals, highGood, labelColor)
end

function RecordingRichTextContextMT:addSpacer()
    self._displayList[#self._displayList + 1] = { "addSpacer" }
    return self._realCtx:addSpacer()
end

function RecordingRichTextContextMT:addHeader(text, color, noSpacer)
    self._displayList[#self._displayList + 1] = { "addHeader", text, color, noSpacer }
    return self._realCtx:addHeader(text, color, noSpacer)
end

function RecordingRichTextContextMT:addDivider(color)
    self._displayList[#self._displayList + 1] = { "addDivider", color }
    return self._realCtx:addDivider(color)
end

function RecordingRichTextContextMT:addText(text, color, maxWidth)
    self._displayList[#self._displayList + 1] = { "addText", text, color, maxWidth }
    return self._realCtx:addText(text, color, maxWidth)
end

--- Create a recording proxy for a rich text context.
---@param ctx table The real RichTextContextMT context
---@return table proxy
---@return table displayList
function TooltipLib._createRecordingRichTextContext(ctx)
    local displayList = {}
    local proxy = setmetatable({
        _realCtx = ctx,
        _displayList = displayList,
    }, RecordingRichTextContextMT)
    return proxy, displayList
end

-- Rich text replay dispatch
local richTextReplayDispatch = {
    -- Native methods
    appendLine     = function(ctx, e) ctx:appendLine(e[2], e[3]) end,
    appendKeyValue = function(ctx, e) ctx:appendKeyValue(e[2], e[3], e[4], e[5]) end,
    appendRichText = function(ctx, e) ctx:appendRichText(e[2]) end,
    setName        = function(ctx, e) ctx:setName(e[2]) end,
    -- Unified methods
    addLabel       = function(ctx, e) ctx:addLabel(e[2], e[3]) end,
    addKeyValue    = function(ctx, e) ctx:addKeyValue(e[2], e[3], e[4], e[5]) end,
    addProgress    = function(ctx, e) ctx:addProgress(e[2], e[3], e[4], e[5]) end,
    addInteger     = function(ctx, e) ctx:addInteger(e[2], e[3], e[4], e[5]) end,
    addFloat       = function(ctx, e) ctx:addFloat(e[2], e[3], e[4], e[5], e[6]) end,
    addPercentage  = function(ctx, e) ctx:addPercentage(e[2], e[3], e[4], e[5], e[6]) end,
    addSpacer      = function(ctx, e) ctx:addSpacer() end,
    addHeader      = function(ctx, e) ctx:addHeader(e[2], e[3], e[4]) end,
    addDivider     = function(ctx, e) ctx:addDivider(e[2]) end,
    addText        = function(ctx, e) ctx:addText(e[2], e[3], e[4]) end,
}

--- Replay a recorded rich text display list onto a context.
---@param ctx table A real RichTextContextMT context
---@param displayList table Array of recorded method call entries
function TooltipLib._replayRichTextDisplayList(ctx, displayList)
    for i = 1, #displayList do
        local entry = displayList[i]
        local handler = richTextReplayDispatch[entry[1]]
        if handler then
            handler(ctx, entry)
        else
            TooltipLib._log("RichText replay: unknown method '" .. tostring(entry[1]) .. "'")
        end
    end
end

-- ============================================================================
-- RecordingContextMT — captures Layout ctx: method calls for display list
-- ============================================================================
-- Used by cacheable providers. Wraps each ContextMT method to record the call
-- AND delegate to the real context. Explicit per-method wrappers avoid Lua 5.1
-- varargs nil-hole issues.
--
-- NOTE: If a new method is added to ContextMT above, a corresponding wrapper
-- and replay dispatch entry MUST be added here.
-- ============================================================================

local RecordingContextMT = {}

RecordingContextMT.__index = function(self, key)
    local method = rawget(RecordingContextMT, key)
    if method ~= nil then return method end
    return self._realCtx[key]
end

RecordingContextMT.__newindex = function(self, key, value)
    self._realCtx[key] = value
    TooltipLib._logOnce("cache_write_" .. tostring(key),
        "Cacheable callback wrote ctx." .. tostring(key) ..
        " — this write is not replayed from cache. " ..
        "Move state writes to preTooltip instead.")
end

--- Create a recording proxy around an existing context.
---@param ctx TooltipLibContext The real context (with ContextMT metatable, layout set)
---@return table proxy The recording proxy to pass to the callback
---@return table displayList The recorded call list (store in cache)
function TooltipLib._createRecordingContext(ctx)
    local displayList = {}
    local proxy = setmetatable({
        _realCtx = ctx,
        _displayList = displayList,
    }, RecordingContextMT)
    return proxy, displayList
end

function RecordingContextMT:addLabel(text, color)
    self._displayList[#self._displayList + 1] = { "addLabel", text, color }
    return self._realCtx:addLabel(text, color)
end

function RecordingContextMT:addKeyValue(keyOrOpts, value, keyColor, valColor)
    local recorded = keyOrOpts
    if type(keyOrOpts) == "table" then
        recorded = {
            key = keyOrOpts.key, value = keyOrOpts.value,
            keyColor = keyOrOpts.keyColor, valueColor = keyOrOpts.valueColor
        }
    end
    self._displayList[#self._displayList + 1] = { "addKeyValue", recorded, value, keyColor, valColor }
    return self._realCtx:addKeyValue(keyOrOpts, value, keyColor, valColor)
end

function RecordingContextMT:addProgress(label, fraction, labelColor, barColor)
    self._displayList[#self._displayList + 1] = { "addProgress", label, fraction, labelColor, barColor }
    return self._realCtx:addProgress(label, fraction, labelColor, barColor)
end

function RecordingContextMT:addInteger(label, value, highGood, labelColor)
    self._displayList[#self._displayList + 1] = { "addInteger", label, value, highGood, labelColor }
    return self._realCtx:addInteger(label, value, highGood, labelColor)
end

function RecordingContextMT:addSpacer()
    self._displayList[#self._displayList + 1] = { "addSpacer" }
    return self._realCtx:addSpacer()
end

function RecordingContextMT:addHeader(text, color, noSpacer)
    self._displayList[#self._displayList + 1] = { "addHeader", text, color, noSpacer }
    return self._realCtx:addHeader(text, color, noSpacer)
end

function RecordingContextMT:addDivider(color)
    self._displayList[#self._displayList + 1] = { "addDivider", color }
    return self._realCtx:addDivider(color)
end

function RecordingContextMT:addText(text, color, maxWidth)
    self._displayList[#self._displayList + 1] = { "addText", text, color, maxWidth }
    return self._realCtx:addText(text, color, maxWidth)
end

function RecordingContextMT:addFloat(label, value, decimals, highGood, labelColor)
    self._displayList[#self._displayList + 1] = { "addFloat", label, value, decimals, highGood, labelColor }
    return self._realCtx:addFloat(label, value, decimals, highGood, labelColor)
end

function RecordingContextMT:addPercentage(label, fraction, decimals, highGood, labelColor)
    self._displayList[#self._displayList + 1] = { "addPercentage", label, fraction, decimals, highGood, labelColor }
    return self._realCtx:addPercentage(label, fraction, decimals, highGood, labelColor)
end

function RecordingContextMT:addTexture(texture, width, height)
    self._displayList[#self._displayList + 1] = { "addTexture", texture, width, height }
    return self._realCtx:addTexture(texture, width, height)
end

function RecordingContextMT:addTextureRow(textures, iconSize, spacing)
    self._displayList[#self._displayList + 1] = { "addTextureRow", textures, iconSize, spacing }
    return self._realCtx:addTextureRow(textures, iconSize, spacing)
end

-- ============================================================================
-- Layout display list replay
-- ============================================================================

local replayDispatch = {
    addLabel      = function(ctx, e) ctx:addLabel(e[2], e[3]) end,
    addKeyValue   = function(ctx, e) ctx:addKeyValue(e[2], e[3], e[4], e[5]) end,
    addProgress   = function(ctx, e) ctx:addProgress(e[2], e[3], e[4], e[5]) end,
    addInteger    = function(ctx, e) ctx:addInteger(e[2], e[3], e[4], e[5]) end,
    addSpacer     = function(ctx, e) ctx:addSpacer() end,
    addHeader     = function(ctx, e) ctx:addHeader(e[2], e[3], e[4]) end,
    addDivider    = function(ctx, e) ctx:addDivider(e[2]) end,
    addText       = function(ctx, e) ctx:addText(e[2], e[3], e[4]) end,
    addFloat      = function(ctx, e) ctx:addFloat(e[2], e[3], e[4], e[5], e[6]) end,
    addPercentage = function(ctx, e) ctx:addPercentage(e[2], e[3], e[4], e[5], e[6]) end,
    addTexture    = function(ctx, e) ctx:addTexture(e[2], e[3], e[4]) end,
    addTextureRow = function(ctx, e) ctx:addTextureRow(e[2], e[3], e[4]) end,
}

--- Replay a recorded display list onto a context.
---@param ctx table A real context (ContextMT metatable, with layout set)
---@param displayList table Array of recorded method call entries
function TooltipLib._replayDisplayList(ctx, displayList)
    for i = 1, #displayList do
        local entry = displayList[i]
        local handler = replayDispatch[entry[1]]
        if handler then
            handler(ctx, entry)
        else
            TooltipLib._log("Replay: unknown method '" .. tostring(entry[1]) .. "'")
        end
    end
end

-- ============================================================================
-- Shared hook helpers (used by multiple hook files to eliminate duplication)
-- ============================================================================

--- Process queued textures from provider contexts (Phase 2.5).
--- Draws single textures and auto-wrapping texture rows below the layout.
--- Used by Hook.lua and HookWorldObject.lua.
---@param contexts table[] Provider context tables
---@param activeProviders table[] Provider info tables
---@param tooltip ObjectTooltip
---@param endY number Current Y position
---@param width number Current tooltip width
---@param padLeft number Left padding
---@param padRight number Right padding
---@return number endY Updated Y position after textures
function TooltipLib._processTextureQueue(contexts, activeProviders, tooltip, endY, width, padLeft, padRight)
    for i = 1, #activeProviders do
        local queue = contexts[i]._textureQueue
        if queue then
            for q = 1, #queue do
                local entry = queue[q]
                local texOk, texErr = pcall(function()
                    if entry.type == "single" then
                        local tex = entry.texture
                        if tex then
                            tooltip:DrawTextureScaledAspect(
                                tex, padLeft, endY,
                                entry.width, entry.height,
                                1, 1, 1, 1)
                            endY = endY + entry.height + 2
                        end
                    elseif entry.type == "row" then
                        local textures = entry.textures
                        if textures and #textures > 0 then
                            local iconSize = entry.iconSize
                            local spacing = entry.spacing
                            local availW = width - padLeft - padRight
                            local iconsPerRow = math.max(1,
                                math.floor(availW / (iconSize + spacing)))
                            local xOffset = padLeft
                            local rowCount = 0
                            for t = 1, #textures do
                                local tex = textures[t]
                                if tex then
                                    tooltip:DrawTextureScaledAspect(
                                        tex, xOffset, endY,
                                        iconSize, iconSize,
                                        1, 1, 1, 1)
                                    rowCount = rowCount + 1
                                    if rowCount >= iconsPerRow and t < #textures then
                                        endY = endY + iconSize + spacing
                                        xOffset = padLeft
                                        rowCount = 0
                                    else
                                        xOffset = xOffset + iconSize + spacing
                                    end
                                end
                            end
                            if rowCount > 0 then
                                endY = endY + iconSize + spacing
                            end
                        end
                    end
                end)
                if not texOk then
                    TooltipLib._log("Provider '" .. activeProviders[i].id ..
                        "' texture error: " .. tostring(texErr))
                end
            end
        end
    end
    return endY
end

--- Install a postRender render wrap on a rich text tooltip instance.
--- Collects providers with postRender callbacks, stores data for the
--- render callback, and installs the wrap once per tooltip instance.
--- Used by HookSkill.lua and HookVehicle.lua.
---@param tooltip ISToolTip The tooltip instance to wrap
---@param activeProviders table[] Active provider tables
---@param contexts table[] Provider context tables
function TooltipLib._installPostRenderWrap(tooltip, activeProviders, contexts)
    local hasPostRender = false
    for i = 1, #activeProviders do
        if activeProviders[i].postRender then
            hasPostRender = true
            break
        end
    end
    if not hasPostRender or not tooltip then return end

    local prProviders = {}
    local prContexts = {}
    for i = 1, #activeProviders do
        if activeProviders[i].postRender then
            prProviders[#prProviders + 1] = activeProviders[i]
            prContexts[#prContexts + 1] = contexts[i]
        end
    end

    tooltip._tooltipLibPostRenderData = {
        providers = prProviders,
        contexts = prContexts,
    }

    -- Install render wrap once per tooltip instance
    if not tooltip._tooltipLibRenderWrapped then
        tooltip._tooltipLibRenderWrapped = true
        tooltip._tooltipLibOrigRender = tooltip.render
        local origRender = tooltip._tooltipLibOrigRender
        if origRender then
            tooltip.render = function(ttSelf)
                origRender(ttSelf)
                local data = ttSelf._tooltipLibPostRenderData
                if not data then return end
                for pi = 1, #data.providers do
                    local p = data.providers[pi]
                    local ctx = data.contexts[pi]
                    ctx.width = ttSelf:getWidth()
                    ctx.height = ttSelf:getHeight()
                    local prOk, prErr = pcall(p.postRender, ctx)
                    if not prOk then
                        TooltipLib._log("Provider '" .. p.id ..
                            "' postRender error: " .. tostring(prErr))
                        TooltipLib._recordError(p.id)
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- Static helpers (backward compatibility)
-- ============================================================================
-- Original API: TooltipLib.Helpers.addLabel(layout, text, r, g, b, a)
-- These remain unchanged except addProgress which now uses setProgress().

---@class TooltipLibHelpers
local Helpers = {}

---@param layout ObjectTooltip_Layout
---@param text string
---@param r number?
---@param g number?
---@param b number?
---@param a number?
---@return ObjectTooltip_LayoutItem
function Helpers.addLabel(layout, text, r, g, b, a)
    local item = layout:addItem()
    item:setLabel(text, r or 1, g or 1, b or 1, a or 1)
    return item
end

function Helpers.addKeyValue(layout, key, value, keyR, keyG, keyB, keyA, valR, valG, valB, valA)
    local item = layout:addItem()
    item:setLabel(key, keyR or 1, keyG or 1, keyB or 1, keyA or 1)
    item:setValue(value, valR or 1, valG or 1, valB or 1, valA or 1)
    return item
end

function Helpers.addProgress(layout, label, fraction, labelR, labelG, labelB, labelA, barR, barG, barB, barA)
    local item = layout:addItem()
    item:setLabel(label, labelR or 1, labelG or 1, labelB or 1, labelA or 1)
    -- PZ engine fix: establish widthValueRight so progress bars render at
    -- non-zero width on the object surface (see ContextMT:addProgress).
    item:setValueRight(0, true)
    item:setValue(string.rep(" ", 12), 0, 0, 0, 0)
    item:setProgress(fraction or 0, barR or 0.4, barG or 0.6, barB or 1.0, barA or 1.0)
    return item
end

function Helpers.addInteger(layout, label, value, highGood, labelR, labelG, labelB, labelA)
    local item = layout:addItem()
    item:setLabel(label, labelR or 1, labelG or 1, labelB or 1, labelA or 1)
    item:setValueRight(value, highGood)
    return item
end

function Helpers.addSpacer(layout)
    local item = layout:addItem()
    item:setLabel(" ", 1, 1, 1, 1)
    return item
end

function Helpers.addHeader(layout, text, r, g, b, a)
    local item = layout:addItem()
    item:setLabel(text, r or 0.9, g or 0.9, b or 0.9, a or 1)
    return item
end

function Helpers.addDivider(layout, r, g, b, a)
    local item = layout:addItem()
    item:setLabel(" ", 0, 0, 0, 0)
    item:setProgress(1.0, r or 0.35, g or 0.35, b or 0.35, a or 0.6)
    return item
end

TooltipLib.Helpers = Helpers

TooltipLib._log("Helpers loaded (v" .. TooltipLib.VERSION .. " with unified context API)")
