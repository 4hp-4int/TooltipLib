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

require "TooltipLib/Core"

if not PZAPI or not PZAPI.ModOptions then
    TooltipLib._log("PZAPI.ModOptions not available — detail key defaults to LShift")
    --- Fallback: always return LShift when ModOptions isn't present.
    function TooltipLib._getDetailKeyCode()
        return Keyboard.KEY_LSHIFT
    end
    --- Fallback: hide-while-aiming keeps its ON default without ModOptions.
    function TooltipLib._hideWhileAimingEnabled()
        return true
    end
    return
end

local modOptions = PZAPI.ModOptions:create("TooltipLib", "UI_TL_ModName")
-- B42 vanilla bug workaround: MainOptions.keyPressHandler matches a mod keybind
-- by comparing setKeybindDialog.keybindName (the raw `name` we pass here) against
-- the row label text, which is getText(name). If name is a translation KEY, those
-- never match, the captured key is dropped, and rebinding silently no-ops. Passing
-- the already-resolved string makes both sides equal so rebinds take effect.
-- (onDefault uses getText() on both sides and works; keyPressHandler/onClear don't.)
modOptions:addKeyBind("detailKey", getText("UI_TL_DetailKey"), Keyboard.KEY_LSHIFT,
    "UI_TL_DetailKeyDesc")

-- Consistency vs chrome under foreign tooltip frameworks: OFF (default) =
-- the panel dress stands down for the session once a deferrer is detected,
-- so every tooltip matches; ON = mixed look (owned tooltips dressed,
-- foreign ones vanilla). Information is identical either way.
modOptions:addTickBox("mixedDress", "UI_TL_MixedDress", false, "UI_TL_MixedDressDesc")

-- Hide tooltips while the player is aiming a weapon: ON (default) = no
-- tooltip draws (vanilla card included) while aim is held — hover mid-fight
-- is almost always accidental and tooltip layout is the most expensive
-- per-frame UI work; OFF = tooltips draw as always.
modOptions:addTickBox("hideWhileAiming", "UI_TL_HideWhileAiming", true, "UI_TL_HideWhileAimingDesc")

-- One-click compatibility check: runs TooltipLib.diagnose(), shows the
-- verdict in a small modal, prints the full report to the console/debug log.
-- Works from the main menu too (the check says to re-run in-game).
modOptions:addButton("diagnose", getText("UI_TL_Diagnose"), "UI_TL_DiagnoseDesc", function()
    local ok, err = pcall(function()
        if not TooltipLib.diagnose then
            require "TooltipLib/Diagnostics"
        end
        local _, level, summary = TooltipLib.diagnose()
        local textBody = "[" .. level .. "] " .. summary .. "\n\n" .. getText("UI_TL_DiagnoseConsole")
        local w, h = 420, 170
        local core = getCore()
        local modal = ISModalDialog:new(
            (core:getScreenWidth() - w) / 2, (core:getScreenHeight() - h) / 2,
            w, h, textBody, false, nil, nil)
        modal:initialise()
        modal:addToUIManager()
    end)
    if not ok then
        TooltipLib._log("diagnose button error: " .. tostring(err))
    end
end)

--- Live gate read by _aimingSuppressed (Core). Missing/unreadable option
--- resolves to true, matching the tick box's ON default.
---@return boolean
function TooltipLib._hideWhileAimingEnabled()
    local ok, v = pcall(function()
        return PZAPI.ModOptions:getOptions("TooltipLib"):getOption("hideWhileAiming"):getValue()
    end)
    if not ok or v == nil then return true end
    return v and true or false
end

--- Live gate read by _resolvePanelDress (Core).
---@return boolean
function TooltipLib._mixedDressAllowed()
    local ok, v = pcall(function()
        return PZAPI.ModOptions:getOptions("TooltipLib"):getOption("mixedDress"):getValue()
    end)
    return ok and (v and true or false)
end

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
            provider.description
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
