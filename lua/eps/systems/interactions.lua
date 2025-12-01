if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Util = EPS.Util or {}

local Interactions = {}

local deps = {
    handleSonicOverride = nil,
    tryStartMaintenance = nil,
    tryStartOverride = nil,
    processReenergize = nil,
    getPanelInfo = nil,
    sendTricorderReport = nil,
    buildPanelPowerReport = nil,
}

local normalizeLocKey = Util.NormalizeLocKey or function(locKey)
    if not locKey or locKey == "" then return "global" end
    return string.lower(locKey)
end

local installed = false
local tricorderDigests = setmetatable({}, { __mode = "k" })
local recentPanelLogs = setmetatable({}, { __mode = "k" })

local function reportToTricorder(ply, ent, lines)
    if not lines then return end
    if deps.sendTricorderReport then
        deps.sendTricorderReport(ply, ent, lines)
    end
end

local function buildPowerReport(info, normalized, summary, header)
    if deps.buildPanelPowerReport then
        return deps.buildPanelPowerReport(info, normalized, summary, header)
    end
    return nil
end

local function onSonicDriver(ply, swep, ent, hitPos)
    if not IsValid(ent) or ent:GetClass() ~= "ent_eps_panel" then return end
    local handled = false
    local continue = false
    if deps.handleSonicOverride then
        local ok, wantContinue = deps.handleSonicOverride(ply, ent)
        if ok then
            handled = true
            continue = continue or wantContinue == true
        end
    end
    if ent.HandleSonicRepair then
        local ok, wantContinue = ent:HandleSonicRepair(ply, swep, hitPos)
        if ok then
            handled = true
            continue = continue or wantContinue == true
        end
    end
    if handled then
        return true, continue
    end
end

local function isHoldingODNScanner(ply)
    local weapon = ply:GetActiveWeapon()
    return IsValid(weapon) and weapon:GetClass() == "odn_scanner"
end

local function onKeyPress(ply, key)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if key == IN_ATTACK then
        if not isHoldingODNScanner(ply) then return end
        if deps.tryStartMaintenance then
            deps.tryStartMaintenance(ply)
        end
    elseif key == IN_ATTACK2 then
        if not isHoldingODNScanner(ply) then return end
        if deps.tryStartOverride then
            deps.tryStartOverride(ply)
        end
    end
end

local function onHyperspanner(ply, swep, ent, hitPos)
    if not IsValid(ent) or ent:GetClass() ~= "ent_eps_panel" then return end
    if not deps.getPanelInfo then return end
    local info = deps.getPanelInfo(ent)
    if not info then return end

    local locKey = info.locationKey or info.locationKeyLower or "global"
    local normalized = normalizeLocKey(locKey)

    local ok, report, status
    if deps.processReenergize then
        ok, report, status = deps.processReenergize(ply, ent, info, normalized)
    end

    local handled = false
    local continue = false

    if ok then
        reportToTricorder(ply, ent, report)
        handled = true
        continue = false
    elseif report then
        reportToTricorder(ply, ent, report)
        handled = true
        continue = status == "progress"
    elseif status == "progress" then
        handled = true
        continue = true
    else
        local fallback = buildPowerReport(info, normalized, "Summary: EPS manifold already reading within nominal tolerances.", "[Tricorder] EPS Power Diagnostics")
        reportToTricorder(ply, ent, fallback)
        handled = true
        continue = false
    end

    return true, continue
end

local function onScanEntity(ent, scanData)
    if not IsValid(ent) or ent:GetClass() ~= "ent_eps_panel" then return end
    if ent.UpdateScannerData then
        ent:UpdateScannerData()
    end
    local readout = ent.GetScannerReadout and ent:GetScannerReadout()
    if not readout then return end
    scanData.EPSPanel = readout
    scanData.Entity = scanData.Entity or ent
end

local function onAnalyseScan(tricorder, owner, scanData)
    if not scanData then return end
    local ent = scanData.Entity
    if not IsValid(ent) or ent:GetClass() ~= "ent_eps_panel" then return end
    local readout = scanData.EPSPanel or (ent.GetScannerReadout and ent:GetScannerReadout())
    if not readout then return end
    if scanData._epsPanelLogged then return end
    scanData.EPSPanel = readout
    if not Star_Trek or not Star_Trek.Logs or not Star_Trek.Logs.AddEntry then return end

    -- Avoid duplicating the same panel telemetry if it was recently stored and matches
    local lines = readout.lines or {}
    if EPS.GetPanelTelemetry then
        local cached, _ = EPS.GetPanelTelemetry(ent)
        if istable(cached) and #cached > 0 then
            -- compare as a single string; if identical, skip adding entries (prevents double-logging)
            local a = table.concat(cached, "\n")
            local b = table.concat(lines, "\n")
            if a == b then
                scanData._epsPanelLogged = true
                return
            end
        end
    end

    if istable(lines) and #lines > 0 then
        local header = lines[1]
        if header and header ~= "" then
            for idx = 2, #lines do
                if lines[idx] == header then
                    local trimmed = {}
                    for j = 1, idx - 1 do
                        trimmed[#trimmed + 1] = lines[j]
                    end
                    lines = trimmed
                    break
                end
            end
        end
    end

    local digest = table.concat(lines, "\n")
    if IsValid(tricorder) then
        local last = tricorderDigests[tricorder]
        if last and last.payload == digest and CurTime() - (last.time or 0) < 2 then
            scanData._epsPanelLogged = true
            return
        end
        tricorderDigests[tricorder] = { payload = digest, time = CurTime() }
    end

    local panelLog = recentPanelLogs[ent]
    if not panelLog then
        panelLog = setmetatable({}, { __mode = "k" })
        recentPanelLogs[ent] = panelLog
    end

    local ownerKey = IsValid(owner) and owner or false
    local ownerLog = ownerKey and panelLog[ownerKey] or panelLog._
    if ownerLog and ownerLog.payload == digest and CurTime() - (ownerLog.time or 0) < 2 then
        scanData._epsPanelLogged = true
        return
    end
    if ownerKey then
        panelLog[ownerKey] = { payload = digest, time = CurTime() }
    else
        panelLog._ = { payload = digest, time = CurTime() }
    end

    scanData._epsPanelLogged = true

    local lcars = Star_Trek.LCARS or {}
    local baseColor = lcars.White or color_white or Color(255, 255, 255)
    local highlightGood = lcars.ColorGreen or baseColor
    local highlightWarn = lcars.ColorOrange or lcars.ColorRed or baseColor
    for idx, line in ipairs(lines) do
        local color = baseColor
        if idx == #lines then
            color = readout.needsMaintenance and highlightWarn or highlightGood
        end
        Star_Trek.Logs:AddEntry(tricorder, owner, line, color, TEXT_ALIGN_LEFT)
    end
end

function Interactions.Setup(options)
    if installed then return end
    installed = true

    options = options or {}
    deps.handleSonicOverride = options.handleSonicOverride or deps.handleSonicOverride
    deps.tryStartMaintenance = options.tryStartMaintenance or deps.tryStartMaintenance
    deps.tryStartOverride = options.tryStartOverride or deps.tryStartOverride
    deps.processReenergize = options.processReenergize or deps.processReenergize
    deps.getPanelInfo = options.getPanelInfo or deps.getPanelInfo
    deps.sendTricorderReport = options.sendTricorderReport or deps.sendTricorderReport
    deps.buildPanelPowerReport = options.buildPanelPowerReport or deps.buildPanelPowerReport

    hook.Add("Star_Trek.tools.sonic_driver.trace_hit", "EPS_SonicRepair", onSonicDriver)
    hook.Add("KeyPress", "EPS_ODNScannerKeyPress", onKeyPress)
    hook.Add("Star_Trek.tools.hyperspanner.trace_hit", "EPS_HyperspannerReenergize", onHyperspanner)
    hook.Add("Star_Trek.Sensors.ScanEntity", "EPS_Panel_ScanData", onScanEntity)
    hook.Add("Star_Trek.Tricorder.AnalyseScanData", "EPS_Panel_TricorderEntries", onAnalyseScan)
end

return Interactions
