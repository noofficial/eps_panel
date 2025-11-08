EPS = EPS or {}

include("eps/core/init.lua")

local Util = EPS.Util or {}
local Layout = include("eps/systems/layout.lua")
local Maintenance = include("eps/systems/maintenance.lua")

local Panels = {}

local normalizeLocKey = Util.NormalizeLocKey or function(locKey)
    if not locKey or locKey == "" then return "global" end
    return string.lower(locKey)
end

function Panels.RememberPanelForLocation(panel, locKey)
    if not IsValid(panel) then return end
    EPS._recentPanelByLocation = EPS._recentPanelByLocation or setmetatable({}, { __mode = "v" })
    local key = normalizeLocKey(locKey)
    EPS._recentPanelByLocation[key] = panel
end

function Panels.RegisterPanelLayout(panel, layout)
    if not IsValid(panel) or not panel.SetSubsystemMask then return end
    panel:SetSubsystemMask(layout or {})
end

function Panels.UpdatePanelSection(panel)
    if not IsValid(panel) then return end
    EPS._panelRefs = EPS._panelRefs or setmetatable({}, { __mode = "k" })

    local info = EPS._panelRefs[panel]
    if not info or type(info) ~= "table" then
        info = { entity = panel }
        EPS._panelRefs[panel] = info
    end

    local deck, sectionId, sectionName = Layout.DetermineSectionForPos(panel:GetPos())

    info.deck = deck
    info.sectionId = sectionId
    info.sectionName = sectionName
    info.entity = panel
    info.panelId = panel:EntIndex()

    local layout = select(1, Layout.BuildLayoutFor(deck, sectionName))
    info.layout = layout

    local rawKey = EPS.NormalizeLocationKey and EPS.NormalizeLocationKey(deck, sectionName, sectionId, info.panelId) or nil
    local _, locKey = EPS.GetLocationState(rawKey)
    info.locationKey = locKey
    info.locationKeyLower = locKey and string.lower(locKey) or nil
    info.rawLocationKey = rawKey
    panel._epsLocationKey = locKey
    Panels.RememberPanelForLocation(panel, locKey)

    if locKey and EPS.SetLocationMeta then
        EPS.SetLocationMeta(locKey, {
            deck = deck,
            section = sectionName,
            sectionId = sectionId,
            panelId = info.panelId,
        })
    end

    Panels.RegisterPanelLayout(panel, layout)

    return info
end

function Panels.GetPanelInfo(panel)
    if not IsValid(panel) then return nil end
    Panels.UpdatePanelSection(panel)
    local info = EPS._panelRefs and EPS._panelRefs[panel]
    if not info then return nil end
    return info
end

function Panels.SyncPanelNetworkState(panel)
    if not IsValid(panel) then return end

    local info = EPS._panelRefs and EPS._panelRefs[panel]
    local locKey = info and info.locationKey or nil
    local maxBudget = EPS.GetBudget and EPS.GetBudget(locKey) or 0
    local totalAllocation = EPS.GetTotalAllocation and EPS.GetTotalAllocation(locKey) or 0
    panel:SetNWInt("eps_max_budget", maxBudget)
    panel:SetNWInt("eps_total_allocation", totalAllocation)
    panel:SetNWInt("eps_available_power", math.max(maxBudget - totalAllocation, 0))
    panel:SetNWString("eps_location", locKey or "global")
    panel:SetNWString("eps_location_section", info and (info.sectionName or "") or "")
    local deckLabel = info and info.deck and tostring(info.deck) or ""
    panel:SetNWString("eps_location_deck", deckLabel)
    panel:SetNWBool("eps_maintenance_lock", Maintenance.IsLocationLocked(locKey, panel))
end

function Panels.SyncPanels(targetLocKey)
    if not EPS._panelRefs then return end

    local normalizedTarget = targetLocKey and string.lower(targetLocKey) or nil

    for panel in pairs(EPS._panelRefs) do
        if IsValid(panel) then
            Panels.UpdatePanelSection(panel)
            local info = EPS._panelRefs[panel]
            local panelKey = info and (info.locationKeyLower or (info.locationKey and string.lower(info.locationKey))) or nil
            if not normalizedTarget or panelKey == normalizedTarget then
                Panels.SyncPanelNetworkState(panel)
            end
        else
            EPS._panelRefs[panel] = nil
        end
    end
end

function Panels.RegisterPanel(panel)
    if not IsValid(panel) then return end

    EPS._panelRefs = EPS._panelRefs or setmetatable({}, { __mode = "k" })
    local info = EPS._panelRefs[panel]
    if not info then
        info = { entity = panel }
        EPS._panelRefs[panel] = info
    else
        info.entity = panel
    end

    Panels.UpdatePanelSection(panel)
    Panels.SyncPanelNetworkState(panel)

    panel:CallOnRemove("EPS_UnregisterPanel", function(ent)
        Panels.UnregisterPanel(ent)
    end)
end

function Panels.UnregisterPanel(panel)
    if not EPS._panelRefs then return end
    EPS._panelRefs[panel] = nil

    if not EPS._damageStates then return end
    for key, state in pairs(EPS._damageStates) do
        if state and state.panel == panel then
            if EPS._CompleteDamageRepair then
                EPS._CompleteDamageRepair(state, nil, { silent = true })
            end
        end
    end
end

function Panels.RecordPanelUse(panel, ply)
    if not IsValid(panel) then return end
    Panels.UpdatePanelSection(panel)
    local info = EPS._panelRefs and EPS._panelRefs[panel]
    if not info then return end
    info.lastUser = IsValid(ply) and ply or info.lastUser
    local locKey = info.locationKey
    info.locationKeyLower = locKey and string.lower(locKey) or nil
    Panels.RememberPanelForLocation(panel, locKey)
    Panels.SyncPanelNetworkState(panel)

    if IsValid(ply) then
        EPS._lastPanelPerPlayer = EPS._lastPanelPerPlayer or setmetatable({}, { __mode = "kv" })
        EPS._lastPanelPerPlayer[ply] = panel
        if EPS._playerLayouts then
            EPS._playerLayouts[ply] = nil
        end
    end
end

local function buildPanelLayout(panelInfo)
    if not panelInfo then return {} end
    local layout = panelInfo.layout
    if not layout then
        layout = select(1, Layout.BuildLayoutFor(panelInfo.deck, panelInfo.sectionName))
        panelInfo.layout = layout
        if IsValid(panelInfo.entity) then
            Panels.RegisterPanelLayout(panelInfo.entity, layout)
        end
    end
    return layout or {}
end

function Panels.PanelSupportsSubsystem(panelInfo, subsystemId)
    if not panelInfo then return false end
    if subsystemId == nil then return false end
    local layout = buildPanelLayout(panelInfo)
    for _, id in ipairs(layout) do
        if id == subsystemId then return true end
    end
    return false
end

function Panels.CollectPanelInfos(targetLocKey)
    local list = {}
    if not EPS._panelRefs then return list end

    local normalizedTarget = targetLocKey and string.lower(targetLocKey) or nil

    for panel, info in pairs(EPS._panelRefs) do
        if IsValid(panel) and info then
            Panels.UpdatePanelSection(panel)
            info = EPS._panelRefs[panel]
            if info then
                info.entity = panel
                local panelKey = info.locationKeyLower or (info.locationKey and string.lower(info.locationKey)) or nil
                if not normalizedTarget or panelKey == normalizedTarget then
                    list[#list + 1] = info
                end
            end
        else
            EPS._panelRefs[panel] = nil
        end
    end

    return list
end

function Panels.PickRandomPanelInfo(targetLocKey)
    local infos = Panels.CollectPanelInfos(targetLocKey)
    if #infos == 0 then return end
    return infos[math.random(#infos)]
end

function Panels.PickPanelForSubsystem(subsystemId, targetLocKey)
    local infos = Panels.CollectPanelInfos(targetLocKey)
    if #infos == 0 then return end

    local matches = {}
    for _, info in ipairs(infos) do
        if Panels.PanelSupportsSubsystem(info, subsystemId) then
            matches[#matches + 1] = info
        end
    end

    if #matches > 0 then
        return matches[math.random(#matches)]
    end

    return infos[math.random(#infos)]
end

Panels.NormalizeLocKey = normalizeLocKey
Panels.BuildPanelLayout = buildPanelLayout

EPS.Panels = Panels
EPS._UpdatePanelSection = Panels.UpdatePanelSection
EPS._SyncPanels = Panels.SyncPanels
EPS.RegisterPanel = Panels.RegisterPanel
EPS.UnregisterPanel = Panels.UnregisterPanel
EPS.RecordPanelUse = Panels.RecordPanelUse

return Panels
