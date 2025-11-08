EPS = EPS or {}

include("eps/core/init.lua")

local Util = EPS.Util or {}

local Telemetry = {}

local function linesEqual(a, b)
    if a == b then return true end
    if not istable(a) or not istable(b) then return false end
    if #a ~= #b then return false end
    for idx = 1, #a do
        if tostring(a[idx] or "") ~= tostring(b[idx] or "") then
            return false
        end
    end
    return true
end

local function normalizeLines(lines)
    if not istable(lines) then return {} end
    local header = lines[1]
    if not header or header == "" then
        return table.Copy(lines)
    end

    local secondHeader
    for idx = 2, #lines do
        if lines[idx] == header then
            secondHeader = idx
            break
        end
    end

    if not secondHeader then
        return table.Copy(lines)
    end

    local firstBlock = {}
    for i = 1, secondHeader - 1 do
        firstBlock[#firstBlock + 1] = lines[i]
    end

    local secondBlock = {}
    for i = secondHeader, #lines do
        secondBlock[#secondBlock + 1] = lines[i]
    end

    if linesEqual(firstBlock, secondBlock) then
        return firstBlock
    end

    return table.Copy(lines)
end

function Telemetry.DescribeLocation(info, locKey)
    local deck = info and info.deck
    local section = info and info.sectionName
    local deckText = deck and tostring(deck) or nil
    local sectionText = section and section ~= "" and section or nil
    if deckText or sectionText then
        deckText = deckText or "?"
        sectionText = sectionText or "Unassigned Section"
        return string.format("Deck %s / %s", deckText, sectionText)
    end
    locKey = Util.NormalizeLocKey and Util.NormalizeLocKey(locKey) or locKey
    if locKey == "global" then
        return "Global EPS Lattice"
    end
    return string.upper(locKey or "")
end

local function jitter(base, scale)
    return base + math.Rand(-scale, scale)
end

function Telemetry.Generate(locKey, savedDemand)
    savedDemand = savedDemand or {}
    local sumDemand = 0
    local sumAlloc = 0
    local perSubsystem = {}
    for _, sub in EPS.IterSubsystems() do
        local id = sub.id
        local demand = savedDemand[id]
        if demand == nil then
            demand = EPS.GetDemand(locKey, id) or 0
        end
        demand = tonumber(demand) or 0
        local alloc = EPS.GetAllocation(locKey, id) or demand
        alloc = tonumber(alloc) or 0
        sumDemand = sumDemand + demand
        sumAlloc = sumAlloc + alloc
        perSubsystem[#perSubsystem + 1] = { sub = sub, demand = demand, alloc = alloc }
    end

    local budget = EPS.GetBudget(locKey) or 0
    local reserve = math.max(budget - sumAlloc, 0)

    return {
        sumDemand = sumDemand,
        sumAlloc = sumAlloc,
        budget = budget,
        reserve = reserve,
        perSubsystem = perSubsystem,
        purgeFlux = jitter(sumDemand * 0.085, 0.25),
        fieldError = math.max(0, jitter(2.0 - sumDemand * 0.003, 0.08)),
        wallTemp = jitter(285 + sumDemand * 0.12, 3.5),
        phaseOffset = jitter(0.015 + sumDemand * 0.00002, 0.0007),
        gradient = jitter(0.7 + sumDemand * 0.0015, 0.05),
        coherence = math.max(80, jitter(99.3 - sumDemand * 0.004, 0.6)),
        harmonic = jitter(42.0 + (sumAlloc % 17) * 0.37 + (sumDemand % 13) * 0.22, 0.8),
        phaseNoise = math.max(0.02, jitter(0.18 - reserve * 0.0004, 0.01)),
    }
end

function Telemetry.BuildMaintenanceReport(info, locKey, savedDemand, telemetry)
    local label = Telemetry.DescribeLocation(info, locKey)
    telemetry = telemetry or Telemetry.Generate(locKey, savedDemand)
    local lines = {
        "[Tricorder] EPS Diagnostic Scan",
        "",
        string.format("  Node: %s", label),
        "",
        string.format("  Plasma Flow (pre-flush): %.2f kl/s", telemetry.purgeFlux),
        string.format("  Field Regulator Error: %.2f%%", telemetry.fieldError),
        string.format("  Conduit Wall Temperature: %.1f K", telemetry.wallTemp),
        string.format("  Subspace Phase Offset: %.4f millicochranes", telemetry.phaseOffset),
        string.format("  Induction Gradient: %.3f tesla", telemetry.gradient),
        string.format("  Coherence Envelope: %.2f%%", telemetry.coherence),
        "",
        "  Conduit Purge Status: COMPLETE",
        "",
        "Summary: EPS maintenance flush successful; conduit ready for re-energizing.",
    }
    return lines, telemetry
end

function Telemetry.BuildPanelPowerReport(info, locKey, summary, header, telemetry)
    local label = Telemetry.DescribeLocation(info, locKey)
    telemetry = telemetry or Telemetry.Generate(locKey)
    local lines = {
        header or "[Tricorder] EPS Power Diagnostics",
        "",
        string.format("  Node: %s", label),
        "",
    }

    for _, entry in ipairs(telemetry.perSubsystem or {}) do
        local sub = entry.sub
        local labelText = (sub and sub.label) or string.upper((sub and sub.id) or "Unknown")
        lines[#lines + 1] = string.format("  %-22s demand %4d / alloc %4d", labelText, entry.demand or 0, entry.alloc or 0)
    end

    lines[#lines + 1] = string.format("  Net Power Demand: %d", telemetry.sumDemand)
    lines[#lines + 1] = string.format("  Net Allocation Load: %d", telemetry.sumAlloc)
    lines[#lines + 1] = ""
    local efficiency = 0
    if telemetry.sumDemand > 0 then
        efficiency = math.min(100, (telemetry.sumAlloc / telemetry.sumDemand) * 100)
    end
    lines[#lines + 1] = string.format("  Lattice Budget Capacity: %d", telemetry.budget)
    lines[#lines + 1] = string.format("  Reserve Power Margin: %d", telemetry.reserve)
    lines[#lines + 1] = string.format("  Harmonic Field Frequency: %.2f kHz", telemetry.harmonic)
    lines[#lines + 1] = string.format("  Subspace Phase Noise: %.3f%%", telemetry.phaseNoise * 100)
    lines[#lines + 1] = string.format("  Transfer Efficiency: %.1f%%", efficiency)
    lines[#lines + 1] = summary or "Summary: EPS diagnostics nominal."
    return lines
end

function Telemetry.BuildReenergizeReport(info, locKey)
    return Telemetry.BuildPanelPowerReport(info, locKey, "Summary: EPS conduit nominal; manual controls restored.", "[Tricorder] EPS Power Reinitialization")
end

function Telemetry.StorePanelTelemetry(panel, lines)
    if not IsValid(panel) or not istable(lines) then return end
    local normalized = normalizeLines(lines)
    EPS._panelTelemetry = EPS._panelTelemetry or setmetatable({}, { __mode = "k" })
    local cached = EPS._panelTelemetry[panel]
    local stamp = CurTime()
    if cached and cached.lines and linesEqual(cached.lines, normalized) then
        cached.timestamp = stamp
        panel:SetNWFloat("eps_scan_stamp", stamp)
        local ok, payload = pcall(util.TableToJSON, { lines = cached.lines or {}, stamp = stamp })
        if ok and payload then
            panel:SetNWString("eps_scan_packet", payload)
        else
            panel:SetNWString("eps_scan_packet", "")
        end
        return
    end

    EPS._panelTelemetry[panel] = {
        lines = normalized,
        timestamp = stamp,
    }
    panel:SetNWFloat("eps_scan_stamp", stamp)
    local ok, payload = pcall(util.TableToJSON, { lines = normalized or {}, stamp = stamp })
    if ok and payload then
        panel:SetNWString("eps_scan_packet", payload)
    else
        panel:SetNWString("eps_scan_packet", "")
    end
end

function Telemetry.SendTricorderReport(ply, panel, lines)
    if not istable(lines) then return end
    local normalized = normalizeLines(lines)
    local duplicate = false
    if EPS._panelTelemetry and EPS._panelTelemetry[panel] and EPS._panelTelemetry[panel].lines then
        duplicate = linesEqual(EPS._panelTelemetry[panel].lines, normalized)
    end

    EPS._lastTricorderDigest = EPS._lastTricorderDigest or setmetatable({}, { __mode = "k" })
    local digest = table.concat(normalized, "\n")
    local last = EPS._lastTricorderDigest[panel]
    if last and last.payload == digest and CurTime() - (last.time or 0) < 0.75 then
        return
    end
    EPS._lastTricorderDigest[panel] = { payload = digest, time = CurTime() }

    Telemetry.StorePanelTelemetry(panel, normalized)
    if duplicate then return end

    if not IsValid(ply) then return end
    local summary = normalized and normalized[#normalized]
    if summary and summary ~= "" then
        ply:PrintMessage(HUD_PRINTCENTER, summary)
    end
end

function Telemetry.GetPanelTelemetry(panel)
    local entry = EPS._panelTelemetry and EPS._panelTelemetry[panel]
    if not entry then return nil, 0 end
    return table.Copy(entry.lines or {}), entry.timestamp or 0
end

EPS.GetPanelTelemetry = Telemetry.GetPanelTelemetry

return Telemetry
