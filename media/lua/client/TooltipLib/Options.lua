-- ============================================================================
-- TooltipLib Options — PZAPI.ModOptions integration
-- ============================================================================
-- Provides:
--   1. Configurable keybind for the "detail mode" modifier key
--   2. Dynamic per-provider enable/disable tick boxes
-- Requires PZAPI.ModOptions (Umbrella); gracefully degrades if unavailable.
--
-- All ModOptions controls are registered at file-load time or at provider
-- registration time (via _onProviderRegistered hook). OnGameStart only syncs
-- saved state from ModOptions.ini back into _providerOverrides.
-- ============================================================================

if isServer() then return end

require "TooltipLib/Core"

if not PZAPI or not PZAPI.ModOptions then
    TooltipLib._log("PZAPI.ModOptions not available — detail key defaults to LShift")
    --- Fallback: always return LShift when ModOptions isn't present.
    function TooltipLib._getDetailKeyCode()
        return Keyboard.KEY_LSHIFT
    end
    return
end

local modOptions = PZAPI.ModOptions:create("TooltipLib", "TooltipLib")
modOptions:addKeyBind("detailKey", "Detail Modifier Key", Keyboard.KEY_LSHIFT,
    "Hold to show detailed tooltip information from providers that support it")

--- Return the currently configured detail key code from ModOptions.
---@return number keyCode
function TooltipLib._getDetailKeyCode()
    local ok, result = pcall(function()
        return PZAPI.ModOptions:getOptions("TooltipLib"):getOption("detailKey"):getValue()
    end)
    return ok and result or Keyboard.KEY_LSHIFT
end

-- ============================================================================
-- Dynamic per-provider tick boxes
-- ============================================================================
-- Tick boxes are created immediately when a provider registers (via the
-- _onProviderRegistered hook called from registerProvider in Core.lua).
-- Providers registered before Options.lua loads get their tick boxes created
-- retroactively in the loop below.
--
-- Tick box state is persisted by PZAPI.ModOptions to modOptions.ini.
-- On game start, saved state is synced back to TooltipLib._providerOverrides.
--
-- onChangeApply fires when the user applies settings in the Mod Options UI,
-- immediately syncing tick box state into _providerOverrides so providers
-- enable/disable without restarting.
-- ============================================================================

-- Live sync: PZAPI calls option:onChangeApply(newValue) when user applies.
-- self is the individual option table (has .id = "provider_<providerId>").
-- Must be set before addTickBox so tick boxes inherit the callback.
function modOptions:onChangeApply(newValue)
    local optId = self.id
    if not optId then return end
    local provId = optId:match("^provider_(.+)$")
    if not provId then return end

    if newValue == false then
        TooltipLib._providerOverrides[provId] = false
    else
        TooltipLib._providerOverrides[provId] = nil
    end
    if TooltipLib.invalidateActiveProviders then
        TooltipLib.invalidateActiveProviders()
    end
    TooltipLib._debugLog("Options: provider '" .. provId ..
        "' " .. (newValue == false and "disabled" or "enabled") .. " via Mod Options")
end

-- Track which providers already have tick boxes (avoid duplicates)
local registeredOptions = {}

--- Add a tick box for a single provider. Called at registration time.
---@param provider table Provider info table (needs .id and .description)
local function addProviderTickBox(provider)
    if not provider.description then return end
    if registeredOptions[provider.id] then return end

    local addOk, addErr = pcall(function()
        modOptions:addTickBox(
            "provider_" .. provider.id,
            provider.description,
            true,
            "Enable or disable the '" .. provider.id .. "' tooltip provider"
        )
    end)
    if addOk then
        registeredOptions[provider.id] = true
        TooltipLib._debugLog("Options: added tick box for provider '" .. provider.id .. "'")
    else
        TooltipLib._logOnce("opt_tickbox_" .. provider.id,
            "Options: failed to add tick box for '" .. provider.id .. "': " .. tostring(addErr))
    end
end

--- Hook called by Core.lua registerProvider() after a provider is added.
--- Creates the tick box immediately at registration time.
function TooltipLib._onProviderRegistered(provider)
    addProviderTickBox(provider)
end

-- Retroactively add tick boxes for providers that registered before Options loaded
local providers = TooltipLib.getProviders()
for i = 1, #providers do
    addProviderTickBox(providers[i])
end

--- Sync tick box state from ModOptions into _providerOverrides.
--- Called on game start to apply saved user preferences.
local function syncOverrides()
    local ok, opts = pcall(function()
        return PZAPI.ModOptions:getOptions("TooltipLib")
    end)
    if not ok or not opts then return end

    for provId, _ in pairs(registeredOptions) do
        local optOk, opt = pcall(function()
            return opts:getOption("provider_" .. provId)
        end)
        if optOk and opt then
            local valOk, val = pcall(function()
                return opt:getValue()
            end)
            if valOk then
                if val == false then
                    TooltipLib._providerOverrides[provId] = false
                else
                    TooltipLib._providerOverrides[provId] = nil
                end
            end
        end
    end
    if TooltipLib.invalidateActiveProviders then
        TooltipLib.invalidateActiveProviders()
    end
end

--- Create tick boxes for all registered providers that have descriptions.
--- Safe to call multiple times — skips providers that already have tick boxes.
function TooltipLib._refreshProviderOptions()
    local allProviders = TooltipLib.getProviders()
    for i = 1, #allProviders do
        addProviderTickBox(allProviders[i])
    end
    local sOk, sErr = pcall(syncOverrides)
    if not sOk then
        TooltipLib._logOnce("opt_sync_error",
            "Options: syncOverrides error: " .. tostring(sErr))
    end
end

-- On game start, sync saved tick box state into _providerOverrides
Events.OnGameStart.Add(function()
    -- Pick up any providers registered between file load and game start
    local ok, err = pcall(TooltipLib._refreshProviderOptions)
    if not ok then
        TooltipLib._logOnce("opt_gamestart",
            "Options: OnGameStart error: " .. tostring(err))
    end
end)

TooltipLib._log("Options loaded (detail key + provider toggles via Mod Options)")
