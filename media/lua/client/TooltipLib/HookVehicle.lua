-- ============================================================================
-- TooltipLib HookVehicle — Vehicle tooltip hook
-- ============================================================================
-- Hooks ISVehicleMechanics tooltip rendering to let providers append rich
-- text to vehicle part tooltips.
--
-- Context shape for target = "vehicle" providers:
--   ctx.part     — VehiclePart being hovered
--   ctx.vehicle  — BaseVehicle
--   ctx.player   — IsoGameCharacter
--   ctx.tooltip  — ISToolTip
--   ctx.surface  — "vehicle"
--   ctx.detail   — boolean (detail key held)
--   ctx._lines   — internal line accumulator (do not use directly)
--
-- Unified methods: ctx:addLabel(), ctx:addKeyValue(), ctx:addProgress(),
--   ctx:addInteger(), ctx:addFloat(), ctx:addPercentage(), ctx:addSpacer(),
--   ctx:addHeader(), ctx:addDivider(), ctx:addText()
-- Native methods: ctx:appendLine(), ctx:appendKeyValue(),
--   ctx:appendRichText(), ctx:setName()
--
-- enabled() signature: function(part, vehicle) -> boolean
-- ============================================================================

require "TooltipLib/Core"
require "TooltipLib/Helpers"

local function InstallVehicleHook()
    -- ISVehicleMechanics must exist
    pcall(function() require "Vehicles/ISUI/ISVehicleMechanics" end)

    if not ISVehicleMechanics then
        TooltipLib._warn("ISVehicleMechanics not found — vehicle hook not installed")
        TooltipLib._hookStatus.vehicle = "ISVehicleMechanics not found"
        return
    end

    -- Hook doMenuTooltip: called for context menu option tooltips (right-click
    -- on vehicle parts). Appends to tooltip.description after vanilla builds it.
    if type(ISVehicleMechanics.doMenuTooltip) ~= "function" then
        TooltipLib._warn("ISVehicleMechanics.doMenuTooltip not found — vehicle menu tooltip hook not installed")
        TooltipLib._hookStatus.vehicle = "ISVehicleMechanics.doMenuTooltip not found"
        return
    end

    local original_doMenuTooltip = ISVehicleMechanics.doMenuTooltip

    ISVehicleMechanics.doMenuTooltip = function(self, part, option, lua, name)
        -- Let vanilla build the tooltip first
        local result = original_doMenuTooltip(self, part, option, lua, name)

        local providers = TooltipLib._getProvidersForTarget("vehicle")
        if #providers == 0 then return result end
        if not part then return result end

        -- Read detail key state
        local detailHeld = TooltipLib._readDetailKey()

        -- Evaluate enabled() for each provider (vehicle providers receive part, vehicle)
        local activeProviders = TooltipLib._evaluateProviders(providers, detailHeld, part, self.vehicle)

        if not activeProviders then return result end

        -- Build per-provider contexts with shared line accumulator
        local lines = {}
        local contexts = {}
        for i = 1, #activeProviders do
            contexts[i] = setmetatable({
                part = part,
                vehicle = self.vehicle,
                player = self.chr,
                tooltip = self.tooltip,
                surface = "vehicle",
                detail = detailHeld,
                _lines = lines,
                _itemCount = 0,
            }, TooltipLib._RichTextContextMT)
        end

        -- ================================================================
        -- PHASE 1: preTooltip
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
        -- PHASE 2: Provider callbacks
        -- ================================================================
        local prevAddedContent = false

        for i = 1, #activeProviders do
            local p = activeProviders[i]

            -- Auto-separator: set flag for deferred insertion
            contexts[i]._needsSeparator = prevAddedContent and p.separator ~= false
            contexts[i]._itemCount = 0

            local cOk, cErr = pcall(p.callback, contexts[i])
            if not cOk then
                TooltipLib._log("Provider '" .. p.id ..
                    "' callback error: " .. tostring(cErr))
                TooltipLib._recordError(p.id)
            else
                TooltipLib._recordSuccess(p.id)
            end

            -- Track if this provider added content
            if (contexts[i]._itemCount or 0) > 0 then
                prevAddedContent = true
            end
        end

        -- Append collected lines to tooltip description
        if #lines > 0 and self.tooltip then
            local existing = self.tooltip.description or ""
            self.tooltip.description = existing .. " <LINE> " .. table.concat(lines, " <LINE> ")
        end

        -- ================================================================
        -- PHASE 3: postRender (framework-managed render wrap)
        -- ================================================================
        TooltipLib._installPostRenderWrap(self.tooltip, activeProviders, contexts)

        -- ================================================================
        -- PHASE 4: Cleanup (guaranteed, reuses callback ctx)
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

        return result
    end

    -- ================================================================
    -- Hook renderCarOverlayTooltip: called each frame when hovering
    -- vehicle parts in the mechanics overlay diagram. Providers fully
    -- replace vanilla's description (vanilla still handles tooltip
    -- creation, visibility, and part name).
    -- ================================================================
    if type(ISVehicleMechanics.renderCarOverlayTooltip) == "function" then
        local original_renderCarOverlayTooltip = ISVehicleMechanics.renderCarOverlayTooltip

        ISVehicleMechanics.renderCarOverlayTooltip = function(self, partProps, part, carType)
            local result = original_renderCarOverlayTooltip(self, partProps, part, carType)

            -- Only run providers when the tooltip is actually visible
            if not result then return result end
            if not part or not self.tooltip then return result end

            local providers = TooltipLib._getProvidersForTarget("vehicle")
            if #providers == 0 then return result end

            local detailHeld = TooltipLib._readDetailKey()
            local activeProviders = TooltipLib._evaluateProviders(providers, detailHeld, part, self.vehicle)
            if not activeProviders then return result end

            -- Save vanilla description; providers replace it only if they add content
            local vanillaDescription = self.tooltip.description or ""
            self.tooltip.description = ""

            local lines = {}
            local contexts = {}
            for i = 1, #activeProviders do
                contexts[i] = setmetatable({
                    part = part,
                    vehicle = self.vehicle,
                    player = self.chr,
                    tooltip = self.tooltip,
                    surface = "vehicle",
                    detail = detailHeld,
                    _lines = lines,
                    _itemCount = 0,
                }, TooltipLib._RichTextContextMT)
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

            -- PHASE 2: Provider callbacks
            local prevAddedContent = false
            for i = 1, #activeProviders do
                local p = activeProviders[i]
                contexts[i]._needsSeparator = prevAddedContent and p.separator ~= false
                contexts[i]._itemCount = 0

                local cOk, cErr = pcall(p.callback, contexts[i])
                if not cOk then
                    TooltipLib._log("Provider '" .. p.id ..
                        "' callback error: " .. tostring(cErr))
                    TooltipLib._recordError(p.id)
                else
                    TooltipLib._recordSuccess(p.id)
                end

                if (contexts[i]._itemCount or 0) > 0 then
                    prevAddedContent = true
                end
            end

            -- Set description from collected lines (replaces vanilla),
            -- or restore vanilla description if providers added nothing
            if #lines > 0 then
                self.tooltip.description = table.concat(lines, " <LINE> ")
            else
                self.tooltip.description = vanillaDescription
            end

            -- PHASE 3: postRender (framework-managed render wrap)
            TooltipLib._installPostRenderWrap(self.tooltip, activeProviders, contexts)

            -- PHASE 4: Cleanup
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

            return result
        end

        TooltipLib._log("Vehicle overlay tooltip hook installed")
    else
        TooltipLib._warn("ISVehicleMechanics.renderCarOverlayTooltip not found — overlay tooltip hook not installed")
    end

    TooltipLib._hookStatus.vehicle = true
    TooltipLib._log("Vehicle tooltip hook installed (" ..
        TooltipLib.getProviderCount("vehicle") .. " vehicle providers)")
end

Events.OnGameStart.Add(InstallVehicleHook)

TooltipLib._log("HookVehicle module loaded")
