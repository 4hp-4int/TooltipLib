--[[
    TooltipLib MPClient — request-gating tests

    Locks the hover-dwell gate added 2026-08-03. Context: OnPreUIDraw polls
    getLastPicked() every frame, and every distinct world object is its own
    cache key, so the per-key REQUEST_COOLDOWN_MS never applied to objects the
    cursor merely swept over. Measured on the live dedicated server (4 players,
    ~100 min): 41,714 readObject commands, 63% of them arriving within 250ms of
    the previous one. These tests pin the gate so that never silently regresses
    into a command flood again -- or, in the other direction, so the gate can't
    accidentally start swallowing legitimate refreshes.
]]

if isServer() and not isClient() then return end

require "TooltipLib/MPClient"

local Assert = PZTestKit.Assert

local tests = {}

-- ---------------------------------------------------------------- harness ---
-- Controllable clock + send capture. MPClient looks both up as globals at call
-- time, so replacing them here is enough.

local clock = 0
getTimestampMs = function() return clock end

local sent = {}
sendClientCommand = function(_player, module, command, args)
    sent[#sent + 1] = { module = module, command = command, args = args }
end

local SPEC = { fields = { "isActivated" } }

local function at(ms)
    clock = ms
end

local function reset()
    sent = {}
end

local function req(x, y, z, idx)
    TooltipLib._mpRequest(SPEC, x, y, z, idx)
end

--- Seed the client cache for an object by replaying a server response.
local function cacheObject(x, y, z, idx)
    triggerEvent("OnServerCommand", "TooltipLib", "objectData", {
        x = x, y = y, z = z, objectIndex = idx, fields = {},
    })
end

-- MPClient state (cache/dwell/cooldown) is module-local and persists across
-- tests, so every test below uses its own coordinates.

-- ============================================================================
-- DWELL GATE — cold objects
-- ============================================================================

tests["mpclient_cold_object_sends_nothing_on_first_frame"] = function()
    reset()
    at(1000)
    req(10, 10, 0, 1)
    return Assert.equal(#sent, 0, "first frame on a new object costs no round trip")
end

tests["mpclient_cold_object_still_silent_before_dwell_elapses"] = function()
    reset()
    at(2000)
    req(11, 10, 0, 1)
    at(2150) -- 150ms < HOVER_DWELL_MS (200)
    req(11, 10, 0, 1)
    return Assert.equal(#sent, 0, "still nothing 150ms into the hover")
end

tests["mpclient_cold_object_sends_once_dwell_satisfied"] = function()
    reset()
    at(3000)
    req(12, 10, 0, 1)
    at(3200) -- exactly HOVER_DWELL_MS
    req(12, 10, 0, 1)
    if not Assert.equal(#sent, 1, "request goes out once the cursor settles") then
        return false
    end
    return Assert.equal(sent[1].command, "readObject", "sends the readObject command")
end

tests["mpclient_sweeping_across_objects_sends_nothing"] = function()
    -- The actual bug: walking with the cursor over the world used to fire one
    -- request per object touched. 50 objects, 20ms apart, none settled on.
    reset()
    for i = 1, 50 do
        at(4000 + i * 20)
        req(100 + i, 10, 0, 1)
    end
    return Assert.equal(#sent, 0, "50 swept-over objects cost zero round trips")
end

tests["mpclient_dwell_resets_when_cursor_moves_away_and_back"] = function()
    reset()
    at(6000)
    req(13, 10, 0, 1)  -- start dwelling on A
    at(6150)
    req(14, 10, 0, 1)  -- cursor jumps to B, A's dwell is abandoned
    at(6250)
    req(13, 10, 0, 1)  -- back to A: dwell restarts, does NOT inherit the old one
    return Assert.equal(#sent, 0, "returning to an object restarts its dwell")
end

-- ============================================================================
-- DWELL GATE — warm objects bypass it
-- ============================================================================

tests["mpclient_cached_object_refreshes_without_dwell"] = function()
    reset()
    at(8000)
    cacheObject(20, 10, 0, 1)
    at(8010) -- only 10ms later; a cold object would still be waiting
    req(20, 10, 0, 1)
    return Assert.equal(#sent, 1, "an object we already know refreshes immediately")
end

-- ============================================================================
-- COOLDOWN still governs the steady state
-- ============================================================================

tests["mpclient_cooldown_suppresses_rapid_refresh"] = function()
    reset()
    at(9000)
    cacheObject(21, 10, 0, 1)
    at(9010)
    req(21, 10, 0, 1) -- sends
    at(9110)          -- 100ms later, well under REQUEST_COOLDOWN_MS
    req(21, 10, 0, 1)
    return Assert.equal(#sent, 1, "second request inside the cooldown is dropped")
end

tests["mpclient_refresh_resumes_after_cooldown"] = function()
    reset()
    at(11000)
    cacheObject(22, 10, 0, 1)
    at(11010)
    req(22, 10, 0, 1) -- sends
    at(12700)         -- >1500ms after the send
    req(22, 10, 0, 1)
    return Assert.equal(#sent, 2, "refresh resumes once the cooldown expires")
end

-- ============================================================================
-- SANDBOX GATE unchanged
-- ============================================================================

tests["mpclient_respects_EnableMPSync_off"] = function()
    reset()
    local prev = SandboxVars.TooltipLib
    SandboxVars.TooltipLib = { EnableMPSync = false }
    at(13000)
    cacheObject(23, 10, 0, 1) -- warm, so only the sandbox gate can stop it
    at(13010)
    req(23, 10, 0, 1)
    SandboxVars.TooltipLib = prev
    return Assert.equal(#sent, 0, "sync disabled means no client traffic at all")
end

PZTestKit.registerTests("test_mpclient", tests)

return tests
