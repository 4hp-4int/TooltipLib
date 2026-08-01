-- ============================================================================
-- TooltipLib Diagnostics — user-facing compatibility check
-- ============================================================================
-- Turns the runtime evidence the hooks already collect (TooltipLib._diag
-- counters, slot-ownership probe, circuit-breaker state) plus the user's
-- actual load order (getActivatedMods) into a three-level verdict:
--
--   OK        — healthy; nothing to do
--   MITIGATED — a conflict pattern was detected and contained automatically;
--               tooltips keep working, optional improvements listed
--   ACTION    — something needs the USER (fix load order / disable a mod) or
--               needs to be REPORTED (to TooltipLib or another mod's author);
--               the report says which, per finding
--
-- Surfaces:
--   TooltipLib.diagnose()        — full report -> debug log/console + returned
--   Mod Options > TooltipLib > "Run compatibility check" (button, Options.lua)
--   Automatic one-shot nudge ~2 min into a session when verdict is ACTION
--
-- The pattern taxonomy behind the rules is documented in
-- docs/COMPATIBILITY.md — each finding here corresponds to a class there.
-- ============================================================================

require "TooltipLib/Core"

-- Known tooltip-touching mods, by verified mod ID. class values:
--   bypasser  — replaces the render, never chains (TooltipLib must load AFTER)
--   ownpanel  — draws its own panel; TooltipLib stands down for its items
--   host      — layout framework TooltipLib integrates with natively
--   reclaimer — re-takes the render slot; contained by the cycle breaker
local KNOWN_MODS = {
    { id = "Tempo_PerfKit", name = "Tempo - PZ Performance Toolkit", class = "bypasser" },
    { id = "showweaponstatsplus4213", name = "Show Weapon Stats Plus", class = "bypasser" },
    { id = "ExtensiveHealthReworkB42", name = "Extensive Health Rework Evolved", class = "ownpanel" },
    { id = "StarlitLibrary", name = "StarlitLibrary", class = "host" },
    { id = "MagicAccessories", name = "Magic Accessories", class = "reclaimer" },
    { id = "ArmorMakesSense", name = "Armor Makes Sense", class = "reclaimer",
      note = "its Burden/Breathing tooltip rows CANNOT show while StarlitLibrary owns the " ..
          "card (AMS only integrates with EuryTooltipController; Starlit builds the card " ..
          "without dispatching AMS's hook) — no load order fixes that; the AMS author " ..
          "would need to register a TooltipLib or Starlit provider" },
}

local OWN_MOD_ID = "TooltipLib"

local LEVEL_RANK = { OK = 1, MITIGATED = 2, ACTION = 3 }

--- Active mod IDs in load order -> { map = id->position(1-based), list }.
--- nil map when the API is unavailable (test harness, weird contexts).
local function readLoadOrder()
    local map, list = {}, {}
    local ok = pcall(function()
        local mods = getActivatedMods()
        for i = 0, mods:size() - 1 do
            local id = mods:get(i)
            map[id] = i + 1
            list[#list + 1] = id
        end
    end)
    if not ok then return nil, nil end
    return map, list
end

--- Build the report. Returns (reportString, level, summaryLine).
--- silent=true skips printing (used by the automatic nudge).
function TooltipLib.diagnose(silent)
    local d = TooltipLib._diag or {}
    local n = function(key) return d[key] or 0 end
    local lines = {}
    local advice = {}
    local level = "OK"

    local function raise(to)
        if LEVEL_RANK[to] > LEVEL_RANK[level] then level = to end
    end
    local function addAdvice(lvl, text)
        raise(lvl)
        advice[#advice + 1] = { lvl = lvl, text = text }
    end

    -- ── Hooks installed? ────────────────────────────────────────────────
    local hs = TooltipLib._hookStatus or {}
    local hooksLine = {}
    for _, surface in ipairs({ "item", "itemSlot", "object", "skill", "vehicle", "recipe" }) do
        local s = hs[surface]
        if s == true then
            hooksLine[#hooksLine + 1] = surface .. ": ok"
        elseif s ~= nil then
            hooksLine[#hooksLine + 1] = surface .. ": FAILED (" .. tostring(s) .. ")"
            addAdvice("ACTION", "The " .. surface .. " hook failed to install: " .. tostring(s) ..
                ". This is a TooltipLib/PZ-build problem, not a load-order problem — " ..
                "REPORT it on the TooltipLib Workshop page with this whole check.")
        end
    end

    local installed = TooltipLib._installedRender or {}
    if not installed.item then
        -- Pre-OnGameStart (main menu) — most evidence doesn't exist yet.
        local report =
            "=== TooltipLib Compatibility Check (v" .. tostring(TooltipLib.VERSION) .. ") ===\n" ..
            "Hooks are not installed yet — load a game, hover a few inventory items, then run this again."
        if not silent then TooltipLib._log(report) end
        return report, "OK", "Not in-game yet — run again after loading a save."
    end

    -- ── Render-slot ownership (item surface is the load-bearing one) ────
    local ownership
    local cur = ISToolTipInv and ISToolTipInv.render
    local contentFlowing = n("ownedRenders") > 0 or n("starlitFills") > 0 or n("deferredRenders") > 0
    if cur == installed.item then
        ownership = "TooltipLib holds the tooltip hook (outermost). Ideal."
    elseif n("ownedRenders") > 0 or n("starlitFills") > 0 then
        ownership = "Another mod wrapped the hook after TooltipLib, but content is flowing through " ..
            "the chain — coexisting correctly."
    elseif n("deferredRenders") > 0 then
        ownership = "A foreign tooltip framework owns the tooltip card; TooltipLib appends its " ..
            "content below it (deferred mode)."
        addAdvice("MITIGATED", "Deferred mode is active: content shows but alignment is approximate. " ..
            "For native integration, move TooltipLib AFTER (below) the other tooltip framework in the load order.")
    else
        ownership = "Another mod took the tooltip hook and NO TooltipLib content has rendered yet."
        addAdvice("ACTION", "Either no item has been hovered yet this session, or a mod is BYPASSING " ..
            "TooltipLib entirely. Hover a few inventory items and run this check again — if these " ..
            "counters stay at zero, move TooltipLib LOWER (later) in the Mods load order: whatever " ..
            "loads last wins the hook, and TooltipLib knows how to share it; bypassing mods don't.")
    end

    -- ── Counter-driven findings ─────────────────────────────────────────
    if n("cycleBreaks") > 0 then
        addAdvice("MITIGATED", "A render-slot loop was detected and broken " .. n("cycleBreaks") ..
            " time(s): a mod keeps re-taking the tooltip hook and chained back into TooltipLib. " ..
            "Tooltips keep working. If this happens on every fresh start, that mod's author should " ..
            "apply the boot-render fix from TooltipLib's compatibility notes (docs/COMPATIBILITY.md §6).")
    end
    if n("starlitBypasses") > 0 then
        addAdvice("ACTION", "StarlitLibrary is present but another mod bypassed it for " ..
            n("starlitBypasses") .. " item(s) — their content shows one frame late via the fallback " ..
            "path. Fix: move TooltipLib to the BOTTOM of the load order.")
    end
    if n("thrashRetires") > 0 then
        addAdvice("MITIGATED", n("thrashRetires") .. " item(s) had multiple mods fighting over their " ..
            "tooltip size; TooltipLib retired them to plain vanilla for stability. If content is " ..
            "missing on those items, reduce the number of tooltip-replacing mods.")
    end
    if n("chainErrors") > 0 then
        addAdvice("MITIGATED", "Another tooltip mod threw " .. n("chainErrors") .. " error(s) during " ..
            "rendering (contained by TooltipLib). Find the 'Render chain error' line in the debug log " ..
            "and report it to THAT mod's author.")
    end

    -- ── Load-order analysis against known tooltip mods ──────────────────
    local orderMap = readLoadOrder()
    local knownLines = {}
    if orderMap and orderMap[OWN_MOD_ID] then
        local tlPos = orderMap[OWN_MOD_ID]
        for _, mod in ipairs(KNOWN_MODS) do
            local pos = orderMap[mod.id]
            if pos then
                local line = mod.name .. " [" .. mod.class .. "] at #" .. pos ..
                    " (TooltipLib at #" .. tlPos .. ")"
                if mod.class == "bypasser" then
                    if tlPos < pos then
                        line = line .. " — WRONG ORDER"
                        addAdvice("ACTION", "Move TooltipLib BELOW " .. mod.name .. " in the Mods " ..
                            "load order. It replaces the tooltip renderer without sharing; only mods " ..
                            "that load after it stay visible. TooltipLib currently loads before it.")
                    else
                        line = line .. " — ordered correctly"
                    end
                elseif mod.class == "host" then
                    if pos > tlPos then
                        line = line .. " — works; loading it ABOVE TooltipLib is cleanest"
                    else
                        line = line .. " — ideal (host above, TooltipLib below)"
                    end
                elseif mod.class == "reclaimer" then
                    line = line .. " — re-takes the hook by design; contained automatically" ..
                        (n("cycleBreaks") > 0 and (" (" .. n("cycleBreaks") .. " loop-breaks this session)") or "")
                elseif mod.class == "ownpanel" then
                    line = line .. " — draws its own tooltips for its items; TooltipLib stands down there by design"
                end
                if mod.note then
                    line = line .. ". NOTE: " .. mod.note
                end
                knownLines[#knownLines + 1] = "  " .. line
            end
        end
    end

    -- ── Circuit-breaker state ────────────────────────────────────────────
    local disabled = {}
    for id, state in pairs(TooltipLib._errorCounts or {}) do
        if state and state.disabled then disabled[#disabled + 1] = id end
    end
    if #disabled > 0 then
        addAdvice("ACTION", "Provider(s) disabled after repeated errors: " .. table.concat(disabled, ", ") ..
            ". Their tooltips are hidden for this session. Report to the mod that registers them; " ..
            "TooltipLib.resetProvider(\"<id>\") re-enables one for testing.")
    end

    -- ── Assemble ─────────────────────────────────────────────────────────
    local summary
    if level == "OK" then
        summary = "Everything healthy — no conflicts detected."
    elseif level == "MITIGATED" then
        summary = "Conflicts detected and contained automatically — tooltips are working; see advice for optional improvements."
    else
        summary = "Action needed — see the numbered advice (load order fix or a report to a mod author)."
    end

    lines[#lines + 1] = "=== TooltipLib Compatibility Check (v" .. tostring(TooltipLib.VERSION) .. ") ==="
    lines[#lines + 1] = "VERDICT: " .. level .. " — " .. summary
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Hooks: " .. table.concat(hooksLine, " | ")
    lines[#lines + 1] = "Ownership: " .. ownership
    lines[#lines + 1] = "Session evidence: owned=" .. n("ownedRenders") ..
        " starlit=" .. n("starlitFills") ..
        " deferred=" .. n("deferredRenders") ..
        " standdowns=" .. n("standDowns") ..
        " cycles-broken=" .. n("cycleBreaks") ..
        " thrash-retired=" .. n("thrashRetires") ..
        " starlit-bypassed=" .. n("starlitBypasses") ..
        " chain-errors=" .. n("chainErrors")
    lines[#lines + 1] = "Providers: " .. tostring(TooltipLib.getProviderCount()) .. " registered" ..
        (#disabled > 0 and (", DISABLED: " .. table.concat(disabled, ", ")) or ", none disabled")
    if #knownLines > 0 then
        lines[#lines + 1] = "Known tooltip mods in this load order:"
        for _, l in ipairs(knownLines) do lines[#lines + 1] = l end
    elseif not orderMap then
        lines[#lines + 1] = "Load order: unavailable in this context."
    end
    if #advice > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Advice:"
        for i, a in ipairs(advice) do
            lines[#lines + 1] = "  " .. i .. ". [" .. a.lvl .. "] " .. a.text
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "If a problem isn't covered above, copy this whole check into a report on the TooltipLib Workshop page."

    local report = table.concat(lines, "\n")
    if not silent then TooltipLib._log(report) end
    return report, level, summary
end

-- ── Automatic one-shot nudge ─────────────────────────────────────────────
-- ~2 minutes into a session (enough hovering for the counters to mean
-- something), run silently; if the verdict is ACTION, print ONE always-on
-- warning pointing at the check. Never a modal, never repeated.
if Events and Events.EveryOneMinute then
    local minuteTicks = 0
    local autoCheck
    autoCheck = function()
        minuteTicks = minuteTicks + 1
        if minuteTicks < 2 then return end
        Events.EveryOneMinute.Remove(autoCheck)
        pcall(function()
            local _, level, summary = TooltipLib.diagnose(true)
            if level == "ACTION" then
                TooltipLib._warn("Compatibility check: " .. summary ..
                    " Run TooltipLib.diagnose() in the Lua console, or Mod Options > TooltipLib > " ..
                    "Run compatibility check.")
            end
        end)
    end
    Events.EveryOneMinute.Add(autoCheck)
end

TooltipLib._log("Diagnostics loaded (TooltipLib.diagnose())")
