-- ============================================================================
-- TooltipLib HookSkill — Skill tooltip hook
-- ============================================================================
-- Hooks ISSkillProgressBar:updateTooltip to let providers append rich text
-- to skill progress bar tooltips.
--
-- Context shape for target = "skill" providers:
--   ctx.perk     — PerkFactory.Perk being hovered
--   ctx.level    — number, current perk level
--   ctx.player   — IsoGameCharacter
--   ctx.tooltip  — ISToolTip
--   ctx.surface  — "skill"
--   ctx.detail   — boolean (detail key held)
--   ctx._lines   — internal line accumulator (do not use directly)
--
-- Unified methods: ctx:addLabel(), ctx:addKeyValue(), ctx:addProgress(),
--   ctx:addInteger(), ctx:addFloat(), ctx:addPercentage(), ctx:addSpacer(),
--   ctx:addHeader(), ctx:addDivider(), ctx:addText()
-- Native methods: ctx:appendLine(), ctx:appendKeyValue(),
--   ctx:appendRichText(), ctx:setName()
--
-- enabled() signature: function(perk, level) -> boolean
-- ============================================================================

require "TooltipLib/Core"
require "TooltipLib/Helpers"

local function InstallSkillHook()
    -- ISSkillProgressBar must exist
    pcall(function() require "XpSystem/ISUI/ISSkillProgressBar" end)

    if not ISSkillProgressBar or type(ISSkillProgressBar.updateTooltip) ~= "function" then
        TooltipLib._warn("ISSkillProgressBar.updateTooltip not found — skill hook not installed")
        TooltipLib._hookStatus.skill = "ISSkillProgressBar.updateTooltip not found"
        return
    end

    local original_updateTooltip = ISSkillProgressBar.updateTooltip

    ISSkillProgressBar.updateTooltip = function(self, lvlSelected)
        -- Let vanilla build the tooltip first
        original_updateTooltip(self, lvlSelected)

        local providers = TooltipLib._getProvidersForTarget("skill")
        if #providers == 0 then return end

        -- Validate expected fields from ISSkillProgressBar
        if not self.perk then
            TooltipLib._logOnce("skill_missing_perk",
                "ISSkillProgressBar missing .perk field — PZ API may have changed")
            return
        end

        -- Read detail key state
        local detailHeld = TooltipLib._readDetailKey()

        -- Evaluate enabled() for each provider (skill providers receive perk, level)
        local activeProviders = TooltipLib._evaluateProviders(providers, detailHeld, self.perk, self.level)

        if not activeProviders then return end

        -- Build per-provider contexts with shared line accumulator
        local lines = {}
        local contexts = {}
        for i = 1, #activeProviders do
            contexts[i] = setmetatable({
                perk = self.perk,
                level = self.level,
                player = self.char,
                tooltip = self.tooltip,
                surface = "skill",
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

        -- Append collected lines to self.message
        if #lines > 0 then
            self.message = (self.message or "") .. " <LINE> " .. table.concat(lines, " <LINE> ")
        end

        -- ================================================================
        -- PHASE 3: postRender (framework-managed render wrap)
        -- ================================================================
        -- Rich text surfaces lack direct drawing during the hook. The
        -- framework wraps the tooltip's render() method so postRender
        -- handlers fire after vanilla rendering, with access to drawRect
        -- and other ISPanel drawing methods.
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
    end

    TooltipLib._hookStatus.skill = true
    TooltipLib._log("Skill tooltip hook installed (" ..
        TooltipLib.getProviderCount("skill") .. " skill providers)")
end

Events.OnGameStart.Add(InstallSkillHook)

TooltipLib._log("HookSkill module loaded")
