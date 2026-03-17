-- ============================================================================
-- TooltipLib HookRecipe — Recipe panel hook
-- ============================================================================
-- Hooks ISCraftRecipePanel:createDynamicChildren to let providers add
-- content to the recipe detail side panel in the B42 crafting UI.
--
-- In B42, ISCraftRecipeTooltip (floating tooltip) is effectively dead in the
-- main hand-craft panel (noTooltip=true, tooltipRecipe never propagated).
-- Recipe details are shown in ISCraftRecipePanel, the persistent side panel
-- that updates via the onRecipeChanged event from HandcraftLogic.
--
-- The framework provides a RecipeContentPanel (ISPanel subclass) that draws
-- provider content via drawText/drawRect in prerender, giving providers the
-- same add* methods as other surfaces.
--
-- Context shape for target = "recipe" providers:
--   ctx.recipe    — CraftRecipe object
--   ctx.logic     — HandcraftLogic reference
--   ctx.player    — IsoGameCharacter
--   ctx.tooltip   — ISCraftRecipePanel
--   ctx.rootTable — ISTableLayout (for direct widget access)
--   ctx.surface   — "recipe"
--   ctx.detail    — boolean (detail key held)
--   ctx._panel    — RecipeContentPanel (internal, used by add* methods)
--
-- Unified methods: ctx:addLabel(), ctx:addKeyValue(), ctx:addProgress(),
--   ctx:addInteger(), ctx:addFloat(), ctx:addPercentage(), ctx:addSpacer(),
--   ctx:addHeader(), ctx:addDivider(), ctx:addText()
--
-- Direct widget access: ctx.rootTable for ISTableLayout API.
--
-- enabled() signature: function(recipe) -> boolean
--
-- NOTE: Caching is NOT supported for recipe providers (ISPanel objects are
-- stateful per-frame).
-- ============================================================================

require "TooltipLib/Core"
require "TooltipLib/Helpers"

--- Inject provider content into a recipe panel's rootTable.
--- Shared between ISCraftRecipePanel and ISCraftRecipeTooltip hooks.
---@param self table  The panel/tooltip instance (has .rootTable, .player, .logic/.recipe)
---@param recipe table  CraftRecipe object
local function injectProviderContent(self, recipe)
    local providers = TooltipLib._getProvidersForTarget("recipe")
    if #providers == 0 then return end

    -- Read detail key state
    local detailHeld = TooltipLib._readDetailKey()

    -- Evaluate enabled() for each provider (recipe providers receive recipe)
    local activeProviders = TooltipLib._evaluateProviders(providers, detailHeld, recipe)

    if not activeProviders then return end

    -- Build provider contexts with a single shared RecipeContentPanel
    -- (shared panel lets theme providers style all recipe content together)
    local RecipeContentPanel = TooltipLib._RecipeContentPanel
    local sharedPanel = RecipeContentPanel:new(0, 0, self.rootTable:getWidth(), 10)
    local contexts = {}
    for i = 1, #activeProviders do
        contexts[i] = setmetatable({
            recipe = recipe,
            logic = self.logic,
            player = self.player,
            tooltip = self,
            rootTable = self.rootTable,
            surface = "recipe",
            detail = detailHeld,
            _panel = sharedPanel,
            _itemCount = 0,
        }, TooltipLib._RecipeContextMT)
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

    -- Add shared panel to rootTable (if any provider added content)
    if sharedPanel._totalHeight > 0 then
        local panelOk, panelErr = pcall(function()
            sharedPanel:initialise()
            sharedPanel:instantiate()
            local row = self.rootTable:addRow()
            self.rootTable:setElement(0, row:index(), sharedPanel)
        end)
        if not panelOk then
            TooltipLib._log("Recipe panel add error: " .. tostring(panelErr))
        end
    end

    -- Force layout recalculation after providers add widgets
    if self.xuiRecalculateLayout then
        self:xuiRecalculateLayout()
    elseif self.dirtyLayout ~= nil then
        self.dirtyLayout = true
    end

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

local function InstallRecipeHook()
    -- ================================================================
    -- Primary hook: ISCraftRecipePanel (side panel in B42 crafting UI)
    -- ================================================================
    -- This is the panel that shows recipe details when you select a recipe.
    -- It rebuilds via createDynamicChildren on each recipe change.
    pcall(function() require "Entity/ISUI/CraftRecipe/ISCraftRecipePanel" end)

    if ISCraftRecipePanel and type(ISCraftRecipePanel.createDynamicChildren) == "function" then
        local original_panel_createDynamic = ISCraftRecipePanel.createDynamicChildren

        ISCraftRecipePanel.createDynamicChildren = function(self)
            -- Let vanilla build the widget tree first
            original_panel_createDynamic(self)

            local recipe = self.logic and self.logic:getRecipe()
            if not recipe then return end

            local ok, err = pcall(injectProviderContent, self, recipe)
            if not ok then
                TooltipLib._logOnce("recipe_panel_inject_error",
                    "Recipe panel inject error: " .. tostring(err))
            end
        end

        TooltipLib._log("Recipe panel hook installed (ISCraftRecipePanel)")
    else
        TooltipLib._warn("ISCraftRecipePanel.createDynamicChildren not found — recipe panel hook not installed")
    end

    -- ================================================================
    -- Fallback hook: ISCraftRecipeTooltip (floating tooltip, if used)
    -- ================================================================
    -- In the main hand-craft panel this is dead code, but other UIs
    -- (e.g. build menu) may still use the floating tooltip.
    pcall(function() require "Entity/ISUI/CraftRecipe/ISCraftRecipeTooltip" end)

    if ISCraftRecipeTooltip and type(ISCraftRecipeTooltip.createDynamicChildren) == "function" then
        local original_tooltip_createDynamic = ISCraftRecipeTooltip.createDynamicChildren

        ISCraftRecipeTooltip.createDynamicChildren = function(self)
            original_tooltip_createDynamic(self)

            if not self.recipe then return end

            local ok, err = pcall(injectProviderContent, self, self.recipe)
            if not ok then
                TooltipLib._logOnce("recipe_tooltip_inject_error",
                    "Recipe tooltip inject error: " .. tostring(err))
            end
        end

        TooltipLib._log("Recipe tooltip hook installed (ISCraftRecipeTooltip)")
    else
        TooltipLib._warn("ISCraftRecipeTooltip.createDynamicChildren not found — recipe tooltip hook not installed")
    end

    TooltipLib._hookStatus.recipe = true
    TooltipLib._log("Recipe hooks installed (" ..
        TooltipLib.getProviderCount("recipe") .. " recipe providers)")
end

Events.OnGameStart.Add(InstallRecipeHook)

TooltipLib._log("HookRecipe module loaded")
